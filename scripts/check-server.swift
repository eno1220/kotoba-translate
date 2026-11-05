import AppKit
import Foundation

// Supply the package resource bundle when compiling this focused executable directly.
extension Bundle {
    static let module = Bundle(path: ProcessInfo.processInfo.environment["KOTOBA_CHECK_RESOURCE_BUNDLE"]!)!
}

@main
struct ServerCheck {
    @MainActor
    static func main() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let directory = root.appendingPathComponent(".build/server-check")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let worker = directory.appendingPathComponent("mock-worker")
        let python = root.appendingPathComponent(".venv/bin/python").path
        try """
        #!\(python)
        import json, os, sys, time
        for line in sys.stdin:
            r = json.loads(line)
            if r['text'] == 'crash': os._exit(1)
            if r['text'] == 'fail':
                print(json.dumps(dict(event='error', message='mock failure')), flush=True)
                continue
            print(json.dumps(dict(event='prefill', current=0, total=5)), flush=True)
            time.sleep(10 if r['text'] == 'slow' else 0.1)
            print(json.dumps(dict(event='delta', text=str(os.getpid()) + ':訳:' + r['text'], tokens=3, tps=30)), flush=True)
            print(json.dumps(dict(event='done', tokens=3, prompt_tokens=5, tps=30, elapsed=0.1, finish_reason='stop')), flush=True)
        """.write(to: worker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: worker.path)
        let preferences = Preferences()
        preferences.models = [ModelLocation(tag: "mock", path: "/mock")]
        preferences.python = worker.path
        preferences.glossary = []
        preferences.unloadSeconds = 60
        let engine = Translator(preferences: preferences)
        try await checkPresetsAndFiles(preferences, engine: engine, directory: directory)
        engine.input = "keep input"
        engine.output = "keep output"
        engine.context = "keep context"
        let server = LocalAPIServer(preferences: preferences, translator: engine)
        server.port = Int.random(in: 20000...60000)
        server.apiKey = "local-test-key-123456789"
        defer { server.stop(); engine.cancel() }
        server.start()
        for _ in 0..<100 {
            if server.running || server.error != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try require(server.running, "listener start: \(server.error ?? "timeout")")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        func request(_ path: String = "/chat/completions", method: String = "POST", body: [String: Any]? = nil, auth: Bool = true) async throws -> (Data, HTTPURLResponse) {
            var r = URLRequest(url: URL(string: server.baseURL + path)!)
            r.httpMethod = method
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if auth { r.setValue("Bearer " + server.apiKey, forHTTPHeaderField: "Authorization") }
            if let body { r.httpBody = try JSONSerialization.data(withJSONObject: body) }
            let (data, reply) = try await session.data(for: r)
            return (data, reply as! HTTPURLResponse)
        }
        func body(_ text: String, stream: Bool = false) -> [String: Any] {
            ["model": "plamo-translate", "messages": [["role": "user", "content": text]], "stream": stream]
        }
        func content(_ data: Data) throws -> String {
            let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let choices = object["choices"] as! [[String: Any]]
            return (choices[0]["message"] as! [String: Any])["content"] as! String
        }
        let (_, unauthenticated) = try await request("/models", method: "GET", auth: false)
        try require(unauthenticated.statusCode == 401, "authentication")
        let (_, preflight) = try await request(method: "OPTIONS", auth: false)
        try require(preflight.statusCode == 204 && preflight.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == "*", "CORS preflight")
        let (models, modelReply) = try await request("/models", method: "GET")
        try require(modelReply.statusCode == 200 && String(decoding: models, as: UTF8.self).contains("mock"), "models")
        try require(!engine.loaded, "listing models must not load the worker")
        let (first, firstReply) = try await request(body: body("hello"))
        try require(firstReply.statusCode == 200, "completion: \(String(decoding: first, as: UTF8.self))")
        let firstText = try content(first)
        try require(firstText.hasSuffix(":訳:hello") && engine.loaded, "completion and model load")
        let (second, _) = try await request(body: body("again"))
        try require(try content(second).split(separator: ":").first == firstText.split(separator: ":").first, "worker reuse")
        let (sse, sseReply) = try await request(body: body("stream", stream: true))
        let events = String(decoding: sse, as: UTF8.self)
        try require(sseReply.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true && events.contains("chat.completion.chunk") && events.contains("[DONE]"), "streaming")
        try require(engine.input == "keep input" && engine.output == "keep output" && engine.context == "keep context", "API must preserve editor text")
        let (_, invalid) = try await request(body: ["messages": [["role": "user", "content": "x"]], "target_lang": "invalid"])
        try require(invalid.statusCode == 400, "language validation")
        let (_, conversation) = try await request(body: ["messages": [["role": "assistant", "content": "x"], ["role": "user", "content": "y"]]])
        try require(conversation.statusCode == 400, "unsupported history")
        let (_, unknown) = try await request(body: ["model": "missing", "messages": [["role": "user", "content": "x"]]])
        try require(unknown.statusCode == 404, "unknown model")
        let (_, oversized) = try await request(body: body(String(repeating: "a", count: 1024 * 1024)))
        try require(oversized.statusCode == 413, "body size limit")
        let pending = Task { try await request(body: body("slow")) }
        for _ in 0..<100 {
            if engine.busy { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let (_, busy) = try await request(body: body("busy"))
        try require(busy.statusCode == 429, "concurrency rejection")
        engine.cancel()
        let (_, cancelled) = try await pending.value
        try require(cancelled.statusCode == 503 && !engine.loaded && !engine.busy, "explicit cancellation")
        let disconnected = Task { try await request(body: body("slow")) }
        for _ in 0..<100 {
            if engine.busy { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        disconnected.cancel()
        _ = try? await disconnected.value
        for _ in 0..<100 {
            if !engine.busy { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(!engine.busy && !engine.loaded, "disconnect cancellation")
        let (_, failed) = try await request(body: body("fail"))
        try require(failed.statusCode == 500 && !engine.busy && !engine.loaded, "worker error")
        let (_, crashed) = try await request(body: body("crash"))
        try require(crashed.statusCode == 500 && !engine.busy && !engine.loaded, "worker exit")
        preferences.unloadSeconds = 0
        let (beforeUnload, _) = try await request(body: body("idle"))
        try await Task.sleep(for: .milliseconds(100))
        try require(!engine.loaded, "idle unload")
        let (afterUnload, _) = try await request(body: body("reload"))
        try require(try content(beforeUnload).split(separator: ":").first != content(afterUnload).split(separator: ":").first, "reload after idle")
        let stopping = Task { try await request(body: body("slow")) }
        for _ in 0..<100 {
            if engine.busy { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        server.stop()
        _ = try? await stopping.value
        try await Task.sleep(for: .milliseconds(100))
        try require(!engine.busy && !engine.loaded, "server stop cancellation")
        print("PASS: auth, CORS, models, JSON/SSE, validation, limits, worker reuse, busy, cancellation/disconnect/stop, failure/crash, idle unload/reload, editor isolation (mock inference)")
    }


    @MainActor
    static func checkPresetsAndFiles(_ preferences: Preferences, engine: Translator, directory: URL) async throws {
        let custom = ContextPreset(emoji: "🧪", name: "検証", contextDescription: "This is a technical reference for software developers.")
        preferences.customPresets = [custom]
        preferences.appPresetRules = [
            AppPresetRule(id: "test.editor", name: "Editor", presetID: custom.id),
            AppPresetRule(id: "test.off", name: "Off", presetID: nil),
            AppPresetRule(id: "test.missing", name: "Missing", presetID: "deleted")
        ]
        engine.context = "Temporary context"
        engine.applyAppPreset(bundleID: "test.editor")
        try require(engine.presetID == custom.id && engine.translationContext == custom.contextDescription + "\n\nTemporary context", "app preset and additional context")
        for id in [nil, "unknown", "test.off", "test.missing"] as [String?] {
            engine.applyAppPreset(bundleID: id)
            try require(engine.presetID == custom.id, "no automatic application preserves manual selection")
        }
        let reloaded = Preferences()
        try require(reloaded.customPresets == [custom] && reloaded.appPresetRules.first?.presetID == custom.id, "preset and app-rule persistence")
        try require(ContextPreset.builtIn.count == 6 && Set(ContextPreset.builtIn.map(\.id)).count == 6, "built-in preset identifiers")
        preferences.removePreset(custom.id)
        try require(preferences.appPresetRules.first?.presetID == nil && engine.selectedPreset == nil && engine.translationContext == "Temporary context", "deleted preset removes automatic rule and context")
        engine.presetID = nil
        let sample = "# 見出し\nHello, world.\n日本語の文章です。\n"
        let url = directory.appendingPathComponent("sample.md")
        for encoding in [String.Encoding.utf8, .utf16, .utf32, .shiftJIS] {
            try sample.data(using: encoding)!.write(to: url)
            try require(try TextFileImporter.read(url) == sample, "text encoding \(encoding)")
        }
        let invalid = directory.appendingPathComponent("invalid.txt")
        try Data([0, 1, 2, 3]).write(to: invalid)
        do { _ = try TextFileImporter.read(invalid); throw checkFailure("binary accepted") }
        catch TextFileImporter.ImportError.unsupported { }
        try Data().write(to: invalid)
        do { _ = try TextFileImporter.read(invalid); throw checkFailure("empty accepted") }
        catch TextFileImporter.ImportError.empty { }
        try Data(repeating: 65, count: TextFileImporter.byteLimit + 1).write(to: invalid)
        do { _ = try TextFileImporter.read(invalid); throw checkFailure("oversized accepted") }
        catch TextFileImporter.ImportError.tooLarge { }
        try Data(repeating: 65, count: 2_000_001).write(to: invalid)
        do { _ = try TextFileImporter.read(invalid); throw checkFailure("character limit ignored") }
        catch TextFileImporter.ImportError.tooLarge { }
        engine.input = "old"
        engine.output = "old translation"
        engine.importFile(url)
        for _ in 0..<200 {
            if !engine.importingFile { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(engine.input == sample && engine.output.isEmpty && !engine.loaded, "file import without inference")
        engine.importFile(url)
        engine.input = "edited during import"
        try await Task.sleep(for: .milliseconds(100))
        try require(engine.input == "edited during import" && !engine.importingFile, "cancel stale file result on edit")
        engine.output = "preserve translation"
        engine.importFile(invalid)
        for _ in 0..<200 {
            if !engine.importingFile { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(engine.fileError != nil && engine.input == "edited during import" && engine.output == "preserve translation", "failed import preserves editors")
        engine.fileError = nil
        print("PASS: preset/application rules, persistence/deletion, extra context, UTF-8/16/32/Shift JIS, binary/empty/size limits, file import/cancellation/editor preservation")
    }

    static func checkFailure(_ message: String) -> NSError {
        NSError(domain: "PresetFileCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func require(_ condition: Bool, _ label: String) throws {
        if !condition { throw NSError(domain: "ServerCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
    }
}
