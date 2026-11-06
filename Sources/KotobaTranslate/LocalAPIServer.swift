import AppKit
import Combine
import Foundation
import Network

@MainActor
final class LocalAPIServer: ObservableObject {
    @Published var port: Int { didSet { UserDefaults.standard.set(port, forKey: "serverPort") } }
    @Published var apiKey: String { didSet { UserDefaults.standard.set(apiKey, forKey: "serverKey") } }
    @Published var modelID: UUID?
    @Published var source = ""
    @Published var target = "ja"
    @Published var form = ""
    @Published private(set) var running = false
    @Published private(set) var starting = false
    @Published private(set) var error: String?
    @Published private(set) var lastTimings: [String: Double] = [:]
    @Published private(set) var requestActivity = false
    @Published private(set) var lastRequestAt: Date?
    private var activeRequests = 0
    private var activityTask: Task<Void, Never>?
    private var listener: NWListener?
    private var peers: [UUID: HTTPPeer] = [:]
    private var quitSubscription: AnyCancellable?
    let inference: ServerInferencePool
    private let preferences: Preferences
    private var activeKey = ""
    var baseURL: String { "http://127.0.0.1:\(port)/v1" }

    init(preferences: Preferences, translator: Translator) {
        self.preferences = preferences
        inference = ServerInferencePool(preferences: preferences, translator: translator)
        port = UserDefaults.standard.object(forKey: "serverPort") as? Int ?? 8765
        apiKey = UserDefaults.standard.string(forKey: "serverKey") ?? UUID().uuidString + UUID().uuidString
        UserDefaults.standard.set(apiKey, forKey: "serverKey")
        modelID = preferences.preferredModelID
        quitSubscription = NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.stop() }
    }

    func start() {
        guard listener == nil else { return }
        guard (1024...65535).contains(port), let port = NWEndpoint.Port(rawValue: UInt16(port)),
              apiKey.count >= 16, !apiKey.contains(where: { $0.isWhitespace }), apiKey.utf8.allSatisfy({ (33...126).contains($0) }) else {
            error = "ポートは1024〜65535、APIキーは空白を含まない半角16文字以上で指定してください。"
            return
        }
        do {
            let parameters = NWParameters.tcp
            // Bind explicitly to IPv4 loopback; never advertise or listen on the LAN.
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            activeKey = apiKey
            error = nil
            starting = true
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        self.starting = false; self.running = true
                        self.inference.start()
                    case .failed(let error):
                        self.stop()
                        self.error = error.localizedDescription
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                Task { @MainActor in
                    guard let self, let listener, self.listener === listener, self.peers.count < 64 else { connection.cancel(); return }
                    let id = UUID()
                    let peer = HTTPPeer(connection: connection)
                    self.peers[id] = peer
                    peer.onClose = { [weak self] in self?.peers[id] = nil }
                    peer.onRequest = { [weak self, weak peer] request in
                        guard let self, let peer else { return }
                        peer.task = Task { await self.handle(request, peer: peer) }
                    }
                    peer.start()
                }
            }
            listener.start(queue: .main)
        } catch { self.error = error.localizedDescription; stop() }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        running = false
        starting = false
        activityTask?.cancel()
        activityTask = nil
        requestActivity = false
        lastRequestAt = nil
        let connections = Array(peers.values)
        peers.removeAll()
        connections.forEach { $0.close() }
        inference.stop()
    }

    private func recordRequest() {
        activeRequests += 1
        lastRequestAt = Date()
        requestActivity = true
        activityTask?.cancel()
        activityTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self else { return }
            self.activityTask = nil
            if self.activeRequests == 0 { self.requestActivity = false }
        }
    }

    private func handle(_ request: HTTPRequest, peer: HTTPPeer) async {
        let started = ContinuousClock.now
        // Preflight carries no credentials. All actual endpoints require the bearer key.
        if request.method == "OPTIONS" { peer.respond(status: 204, body: Data()); return }
        guard request.headers["authorization"] == "Bearer " + activeKey else {
            peer.fail(APIError(status: 401, message: "APIキーを確認してください。")); return
        }
        let supported = (request.method == "GET" && request.path == "/v1/models") ||
            (request.method == "POST" && request.path == "/v1/chat/completions")
        if supported { recordRequest() }
        defer {
            if supported {
                activeRequests -= 1
                if activeRequests == 0 && activityTask == nil { requestActivity = false }
            }
        }
        if request.method == "GET", request.path == "/v1/models" {
            peer.json(["object": "list", "data": preferences.models.map {
                ["id": $0.id.uuidString, "object": "model", "created": 0, "owned_by": "local", "name": $0.tag] as [String: Any]
            }])
            return
        }
        guard request.method == "POST", request.path == "/v1/chat/completions" else {
            peer.fail(APIError(status: 404, message: "GET /v1/models または POST /v1/chat/completions を使用してください。")); return
        }
        guard request.headers["content-type"]?.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces) == "application/json" else {
            peer.fail(APIError(status: 415, message: "Content-Type: application/json を指定してください。")); return
        }
        var streaming = false
        do {
            let chat: ChatRequest
            do { chat = try JSONDecoder().decode(ChatRequest.self, from: request.body) }
            catch { throw APIError(status: 400, message: "JSONの形式を確認してください。messagesのcontentは文字列で指定してください。") }
            let model: ModelLocation?
            if let name = chat.model, !name.isEmpty, name != "plamo-translate" {
                let matches = preferences.models.filter { $0.id.uuidString == name || $0.tag == name }
                guard matches.count == 1 else { throw APIError(status: 404, message: "登録済みのモデルIDまたは一意のタグを指定してください。") }
                model = matches.first
            } else { model = preferences.models.first { $0.id == modelID } ?? preferences.models.first { $0.id == preferences.preferredModelID } }
            guard let model else { throw APIError(status: 404, message: "設定でモデルを登録してください。") }
            let terms = preferences.glossary.filter { !$0.source.isEmpty || !$0.target.isEmpty }
                .map { ["source": $0.source, "target": $0.target] }
            let translation = try chat.translation(modelPath: model.path, source: source, target: target, form: form,
                                                  terms: terms, autoSplit: preferences.autoSplit)
            try Task.checkCancellation()
            let id = "chatcmpl-" + UUID().uuidString
            let created = Int(Date().timeIntervalSince1970)
            let modelName = model.id.uuidString
            func chunk(_ delta: [String: Any], finish: Any = NSNull()) -> [String: Any] {
                ["id": id, "object": "chat.completion.chunk", "created": created, "model": modelName,
                 "choices": [["index": 0, "delta": delta, "finish_reason": finish]]]
            }
            streaming = chat.stream == true
            if streaming {
                peer.beginStream()
                peer.event(chunk(["role": "assistant", "content": ""]))
            }
            peer.startInferenceTimeout()
            var firstContentSeconds: Double?
            let (text, metrics) = try await inference.translate(translation) { [weak peer] text in
                if !text.isEmpty && firstContentSeconds == nil {
                    firstContentSeconds = started.duration(to: .now).seconds
                }
                if streaming { peer?.event(chunk(["content": text])) }
            }
            try Task.checkCancellation()
            let finish = metrics.finish_reason == "length" ? "length" : "stop"
            let usage = ["prompt_tokens": metrics.prompt_tokens ?? 0, "completion_tokens": metrics.tokens ?? 0,
                         "total_tokens": (metrics.prompt_tokens ?? 0) + (metrics.tokens ?? 0)]
            // Numeric diagnostics only; never retain source, context, or translated text.
            var timings: [String: Double] = ["total_seconds": started.duration(to: .now).seconds]
            timings["queue_seconds"] = metrics.queue_seconds
            timings["worker_seconds"] = metrics.elapsed
            timings["load_seconds"] = metrics.load_seconds
            timings["first_content_seconds"] = firstContentSeconds
            timings["generation_tps"] = metrics.tps
            timings["prompt_tps"] = metrics.prompt_tps
            if let tokens = metrics.prompt_tokens, let tps = metrics.prompt_tps, tps > 0 {
                timings["prompt_seconds"] = Double(tokens) / tps
            }
            if let tokens = metrics.tokens, let tps = metrics.tps, tps > 0 {
                timings["generation_seconds"] = Double(tokens) / tps
            }
            lastTimings = timings
            if streaming {
                var final = chunk([:], finish: finish)
                final["timings"] = timings
                peer.event(final)
                if chat.stream_options?.include_usage == true {
                    peer.event(["id": id, "object": "chat.completion.chunk", "created": created,
                                "model": modelName, "choices": [], "usage": usage])
                }
                peer.endStream()
            } else {
                peer.json(["id": id, "object": "chat.completion", "created": created, "model": modelName,
                           "choices": [["index": 0, "message": ["role": "assistant", "content": text], "finish_reason": finish]],
                           "usage": usage, "timings": timings])
            }
        } catch {
            let failure = error as? APIError ?? APIError(status: error is CancellationError ? 503 : 500,
                message: error is CancellationError ? "翻訳が中止されました。" : error.localizedDescription)
            if streaming { peer.event(["error": ["message": failure.message, "type": "server_error", "code": failure.status]]); peer.endStream() }
            else { peer.fail(failure) }
        }
    }
}

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

/// One bounded HTTP/1.1 request per connection. Network.framework owns socket I/O.
@MainActor
private final class HTTPPeer {
    private let connection: NWConnection
    private var buffer = Data()
    private var received = false
    private var closed = false
    private var responding = false
    private var pendingBytes = 0
    private var timeout: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    var task: Task<Void, Never>?
    var onClose: (() -> Void)?
    var onRequest: ((HTTPRequest) -> Void)?
    private static let maxBody = 1024 * 1024
    private static let maxHeader = 16384
    private static let cors = "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Authorization, Content-Type\r\nAccess-Control-Allow-Private-Network: true\r\nCache-Control: no-store\r\nConnection: close\r\n"

    init(connection: NWConnection) { self.connection = connection }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state { case .failed, .cancelled: self?.close(); default: break }
            }
        }
        connection.start(queue: .main)
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            self?.fail(APIError(status: 408, message: "リクエストの受信がタイムアウトしました。"))
        }
        receive()
    }

    func startInferenceTimeout() {
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(600)) } catch { return }
            self?.close() // Cancels inference and terminates its worker.
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, ended, error in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                if let data, !data.isEmpty {
                    if !self.responding {
                        if self.received { self.close(); return } // No pipelining.
                        self.buffer.append(data)
                        self.parse()
                    } // Drain rejected bodies without retaining them, so errors arrive before FIN.
                }
                if ended || error != nil {
                    self.close()
                } else if !self.closed { self.receive() }
            }
        }
    }

    private func parse() {
        guard !received, !responding else { return }
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > Self.maxHeader { fail(APIError(status: 431, message: "HTTPヘッダーが大きすぎます。")) }
            return
        }
        guard separator.lowerBound <= Self.maxHeader,
              let header = String(data: buffer[..<separator.lowerBound], encoding: .utf8) else {
            fail(APIError(status: 400, message: "HTTPヘッダーが不正です。")); return
        }
        let lines = header.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3, first[2] == "HTTP/1.1" else {
            fail(APIError(status: 400, message: "HTTP/1.1を使用してください。")); return
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { fail(APIError(status: 400, message: "HTTPヘッダーが不正です。")); return }
            let name = line[..<colon].lowercased()
            guard headers[name] == nil else { fail(APIError(status: 400, message: "重複したHTTPヘッダーです。")); return }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil,
              let length = Int(headers["content-length"] ?? "0"), length >= 0 else {
            fail(APIError(status: 400, message: "Content-Lengthを指定してください。chunkedリクエストには対応しません。")); return
        }
        guard length <= Self.maxBody else { fail(APIError(status: 413, message: "リクエストの上限は1MBです。")); return }
        let bodyStart = separator.upperBound
        guard buffer.count - bodyStart <= length else { fail(APIError(status: 400, message: "リクエストの長さが不正です。")); return }
        guard buffer.count - bodyStart == length else { return }
        received = true
        timeout?.cancel()
        let request = HTTPRequest(method: String(first[0]), path: String(first[1]), headers: headers, body: Data(buffer[bodyStart...]))
        buffer = Data()
        onRequest?(request)
    }

    func fail(_ error: APIError) {
        json(["error": ["message": error.message, "type": error.status < 500 ? "invalid_request_error" : "server_error", "code": error.status]], status: error.status)
    }

    func json(_ value: [String: Any], status: Int = 200) {
        respond(status: status, body: (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data())
    }

    func respond(status: Int, body: Data) {
        guard !responding, !closed else { return }
        responding = true
        timeout?.cancel()
        let retry = status == 429 ? "Retry-After: 1\r\n" : ""
        let header = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))\r\n" + Self.cors + retry +
            "Content-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\n\r\n"
        send(Data(header.utf8) + body, final: true)
    }

    func beginStream() {
        guard !closed else { return }
        responding = true
        send(Data(("HTTP/1.1 200 OK\r\n" + Self.cors + "Content-Type: text/event-stream; charset=utf-8\r\n\r\n").utf8))
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                self?.send(Data(": keep-alive\n\n".utf8))
            }
        }
    }

    func event(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value), let json = String(data: data, encoding: .utf8) else { return }
        send(Data("data: \(json)\n\n".utf8))
    }

    func endStream() {
        heartbeat?.cancel()
        timeout?.cancel()
        send(Data("data: [DONE]\n\n".utf8), final: true)
    }

    private func send(_ data: Data, final: Bool = false) {
        guard !closed else { return }
        pendingBytes += data.count
        guard pendingBytes <= 4 * 1024 * 1024 else { close(); return }
        connection.send(content: data, contentContext: final ? .finalMessage : .defaultMessage,
                        isComplete: true, completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.pendingBytes -= data.count
                if error != nil { self.close() }
                else if final {
                    // Gracefully half-close before cancelling, including early 413 responses.
                    self.timeout?.cancel()
                    self.timeout = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(5)) } catch { return }
                        self?.close()
                    }
                }
            }
        })
    }

    func close() {
        guard !closed else { return }
        closed = true
        heartbeat?.cancel()
        timeout?.cancel()
        task?.cancel()
        task = nil
        buffer = Data()
        connection.cancel()
        onClose?()
        onClose = nil
        onRequest = nil
    }
}
