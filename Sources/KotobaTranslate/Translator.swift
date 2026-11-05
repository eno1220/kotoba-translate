import AppKit
import Combine
import Darwin
import Foundation

struct WorkerEvent: Decodable {
    var event: String
    var text: String?
    var message: String?
    var current: Int?
    var total: Int?
    var tokens: Int?
    var tps: Double?
    var elapsed: Double?
    var prompt_tokens: Int?
    var prompt_tps: Double?
    var load_seconds: Double?
    var finish_reason: String?
}

@MainActor
final class Translator: ObservableObject {
    @Published var input = "" { didSet { updateInputStatistics() } }
    @Published private(set) var inputStatistics = InputStatistics()
    @Published var sourcePreview = false
    @Published var outputPreview = false
    @Published var output = ""
    @Published var modelID: UUID?
    @Published var source = ""
    @Published var target = "ja"
    @Published var form = ""
    @Published var context = ""
    @Published var useGlossary = true
    @Published var optionsExpanded = false
    @Published var maxTokens = 2048
    @Published var temperature = 0.0
    @Published private(set) var busy = false
    @Published private(set) var loaded = false
    @Published private(set) var status = ""
    @Published private(set) var progress: Double?
    @Published private(set) var metrics: WorkerEvent?
    @Published var error: String?

    private var process: Process?
    private var stdin: FileHandle?
    private var identity = UUID()
    private var loadedPath: String?
    private var pythonPath: String?
    private var idleTask: Task<Void, Never>?
    private var statisticsTask: Task<Void, Never>?
    private var statisticsRevision = UUID()
    private var settingsSubscription: AnyCancellable?
    private var quitSubscription: AnyCancellable?
    private let preferences: Preferences

    init(preferences: Preferences) {
        self.preferences = preferences
        modelID = preferences.preferredModelID
        optionsExpanded = preferences.models.isEmpty
        settingsSubscription = preferences.$unloadSeconds.dropFirst().sink { [weak self] seconds in
            Task { @MainActor in self?.scheduleUnload(seconds: seconds) }
        }
        quitSubscription = NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.stopProcess() }
    }

    var canTranslate: Bool {
        !busy && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        preferences.models.contains { $0.id == modelID } && maxTokens > 0 && maxTokens < 32768 &&
        temperature.isFinite && (0...2).contains(temperature)
    }

    private func updateInputStatistics() {
        statisticsTask?.cancel()
        let text = input
        let revision = UUID()
        statisticsRevision = revision
        statisticsTask = Task.detached(priority: .utility) { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
                let statistics = try InputStatistics.measure(text)
                try Task.checkCancellation()
                await self?.applyInputStatistics(statistics, revision: revision)
            } catch { /* Replaced by more recent input. */ }
        }
    }

    private func applyInputStatistics(_ statistics: InputStatistics, revision: UUID) {
        guard revision == statisticsRevision else { return }
        inputStatistics = statistics
    }

    func translate() {
        guard canTranslate, let location = preferences.models.first(where: { $0.id == modelID }) else { return }
        let terms = useGlossary ? preferences.glossary.filter { !$0.source.isEmpty || !$0.target.isEmpty } : []
        if terms.contains(where: { $0.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            error = "辞書の原語と訳語を入力してください。"
            return
        }
        idleTask?.cancel()
        busy = true
        output = ""
        error = nil
        metrics = nil
        progress = nil
        status = "モデルを読み込み中"
        do {
            if loadedPath != location.path || pythonPath != preferences.python || process?.isRunning != true {
                stopProcess()
                try startProcess(model: location.path)
            }
            let request: [String: Any] = [
                "model": location.path, "text": input, "source": source, "target": target,
                "form": target == "ja" ? form : "", "context": context,
                "glossary": terms.map { ["source": $0.source, "target": $0.target] },
                "max_tokens": maxTokens, "temperature": temperature
            ]
            var data = try JSONSerialization.data(withJSONObject: request)
            data.append(0x0A)
            // Even a large source/glossary must not block the main thread on a full pipe.
            let handle = stdin
            let ticket = identity
            Task.detached { [weak self] in
                do { try handle?.write(contentsOf: data) }
                catch { await self?.writeFailed(error.localizedDescription, ticket: ticket) }
            }
        } catch {
            self.error = error.localizedDescription
            busy = false
            status = ""
            stopProcess()
        }
    }

    private func writeFailed(_ message: String, ticket: UUID) {
        guard ticket == identity else { return }
        error = message
        cancel()
    }

    private func startProcess(model: String) throws {
        let python = (preferences.python as NSString).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: python) else {
            throw NSError(domain: "Kotoba", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pythonが見つかりません。uv syncを実行し、設定のPythonパスを確認してください。"])
        }
        guard let worker = Bundle.module.url(forResource: "worker", withExtension: "py", subdirectory: "Resources") else {
            throw NSError(domain: "Kotoba", code: 2, userInfo: [NSLocalizedDescriptionKey: "worker.pyが見つかりません。"])
        }
        let task = Process()
        let inputPipe = Pipe(), outputPipe = Pipe(), errorPipe = Pipe()
        task.executableURL = URL(fileURLWithPath: python)
        task.arguments = ["-u", worker.path]
        task.standardInput = inputPipe
        task.standardOutput = outputPipe
        task.standardError = errorPipe
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        task.environment = environment
        try task.run()
        process = task
        stdin = inputPipe.fileHandleForWriting
        loadedPath = model
        pythonPath = preferences.python
        let ticket = identity
        // Both pipes are always drained; library diagnostics cannot deadlock generation.
        let diagnostics = Task.detached { () -> String in
            var tail = Data()
            while true {
                let data = errorPipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                tail.append(data)
                if tail.count > 8192 { tail = Data(tail.suffix(8192)) }
            }
            return String(decoding: tail, as: UTF8.self)
        }
        Task.detached { [weak self] in
            var pending = Data()
            while true {
                let data = outputPipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                pending.append(data)
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = Data(pending[..<newline])
                    pending.removeSubrange(...newline)
                    if let event = try? JSONDecoder().decode(WorkerEvent.self, from: line) {
                        await self?.receive(event, ticket: ticket)
                    }
                }
            }
            task.waitUntilExit()
            let details = await diagnostics.value
            await self?.exited(ticket: ticket, details: details)
        }
    }

    private func receive(_ event: WorkerEvent, ticket: UUID) {
        guard ticket == identity else { return }
        switch event.event {
        case "loading": status = "モデルを読み込み中"
        case "prefill":
            loaded = true
            status = "入力を処理中"
            progress = Double(event.current ?? 0) / Double(max(1, event.total ?? 1))
        case "delta":
            loaded = true
            status = "翻訳中"
            progress = nil
            output += event.text ?? ""
            if event.tokens != nil { metrics = event }
        case "done":
            metrics = event
            busy = false
            progress = nil
            status = event.finish_reason == "length" ? "生成上限に到達" : "完了"
            scheduleUnload(seconds: preferences.unloadSeconds)
        case "error":
            error = event.message
            busy = false
            status = ""
            progress = nil
            // Also releases any partially loaded tensors after a load failure.
            stopProcess()
        default: break
        }
    }

    private func exited(ticket: UUID, details: String) {
        guard ticket == identity else { return }
        if busy {
            error = details.isEmpty ? "Pythonプロセスが終了しました。" : details
            status = ""
        }
        busy = false
        progress = nil
        stopProcess()
    }

    func cancel() {
        stopProcess()
        busy = false
        progress = nil
        status = "中止"
    }

    func unload() {
        guard !busy else { return }
        stopProcess()
    }

    private func scheduleUnload(seconds: Int) {
        idleTask?.cancel()
        guard !busy, process != nil, seconds >= 0 else { return }
        idleTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            self?.unload()
        }
    }

    private func stopProcess() {
        idleTask?.cancel()
        identity = UUID() // Reject queued events from the previous process.
        if let old = process, old.isRunning {
            old.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if old.isRunning { kill(old.processIdentifier, SIGKILL) }
            }
        }
        try? stdin?.close()
        stdin = nil
        process = nil
        loadedPath = nil
        pythonPath = nil
        loaded = false
    }
}
