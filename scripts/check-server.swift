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
        var draft = RequestDraft()
        try require(draft.maxTokens == "8192", "request builder defaults to 8192 tokens")
        let defaultChat = try JSONDecoder().decode(ChatRequest.self, from: Data(#"{"messages":[{"role":"user","content":"hello"}]}"#.utf8))
        let defaultTranslation = try defaultChat.translation(modelPath: "/mock", source: "", target: "ja", form: "", terms: [])
        try require(defaultTranslation.max_tokens == 8192 && defaultTranslation.auto_split, "API defaults to 8192 tokens and auto splitting")
        try require(try !defaultChat.translation(modelPath: "/mock", source: "", target: "ja", form: "", terms: [], autoSplit: false).auto_split, "API inherits disabled preference")
        let overrideChat = try JSONDecoder().decode(ChatRequest.self, from: Data(#"{"messages":[{"role":"user","content":"hello"}],"max_tokens":64,"auto_split":true}"#.utf8))
        let overridden = try overrideChat.translation(modelPath: "/mock", source: "", target: "ja", form: "", terms: [], autoSplit: false)
        try require(overridden.max_tokens == 64 && overridden.auto_split, "API can override token count and splitting preference")
        try require(draft.issue != nil, "request form rejects empty input")
        draft.text = "hello"
        try require(draft.issue == nil, "request form accepts defaults")
        draft.maxTokens = "invalid"
        try require(draft.issue != nil, "request form rejects nonnumeric token limit instead of reusing a stale value")
        for limit in ["0", "32768"] {
            draft.maxTokens = limit
            try require(draft.issue != nil, "request form token limit boundary: \(limit)")
        }
        for limit in ["1", "32767"] {
            draft.maxTokens = limit
            try require(draft.issue == nil, "request form valid token limit: \(limit)")
        }
        for temperature in ["invalid", "nan", "inf", "-0.1", "2.1"] {
            draft.temperature = temperature
            try require(draft.issue != nil, "request form rejects invalid temperature: \(temperature)")
        }
        for temperature in ["0", "0.5", "2"] {
            draft.temperature = temperature
            try require(draft.issue == nil, "request form accepts temperature: \(temperature)")
        }
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
            print(json.dumps(dict(event='loading')), flush=True)
            time.sleep(0.1)
            print(json.dumps(dict(event='prefill', current=0, total=5)), flush=True)
            time.sleep(10 if r['text'] == 'slow' else 0.1)
            if r['text'] == 'draft':
                print(json.dumps(dict(event='delta', text='first:')), flush=True)
            print(json.dumps(dict(event='draft', text='discarded attempt')), flush=True)
            print(json.dumps(dict(event='draft', text='')), flush=True)
            print(json.dumps(dict(event='draft', text='provisional translation')), flush=True)
            print(json.dumps(dict(event='delta', text=str(os.getpid()) + ':訳:' + r['text'], tokens=3, tps=30)), flush=True)
            print(json.dumps(dict(event='done', tokens=3, prompt_tokens=5, tps=30, prompt_tps=100, load_seconds=0.01, elapsed=0.1, finish_reason='stop')), flush=True)
        """.write(to: worker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: worker.path)
        let preferences = Preferences()
        preferences.models = [ModelLocation(tag: "mock", path: "/mock")]
        preferences.python = worker.path
        preferences.glossary = []
        preferences.unloadSeconds = 60
        preferences.autoSplit = false
        try require(!Preferences().autoSplit, "automatic splitting preference persists")
        preferences.autoSplit = true
        let draftEngine = Translator(preferences: preferences)
        try require(draftEngine.maxTokens == 8192, "editor defaults to 8192 tokens")
        draftEngine.input = "draft"
        draftEngine.translate()
        for _ in 0..<200 {
            if !draftEngine.busy { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(!draftEngine.busy && draftEngine.error == nil && draftEngine.output.hasPrefix("first:") && draftEngine.output.hasSuffix(":訳:draft"), "committed prefix survives draft replacement")
        try require(!draftEngine.output.contains("discarded") && !draftEngine.output.contains("provisional"), "retried drafts do not duplicate editor output")
        draftEngine.unload()
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
        try require(!server.requestActivity && server.lastRequestAt == nil && !server.inference.hasLoadedModel, "initial menu status")
        let (_, unauthenticated) = try await request("/models", method: "GET", auth: false)
        try require(unauthenticated.statusCode == 401, "authentication")
        let (_, preflight) = try await request(method: "OPTIONS", auth: false)
        try require(preflight.statusCode == 204 && preflight.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == "*", "CORS preflight")
        try require(!server.requestActivity && server.lastRequestAt == nil, "unauthenticated traffic and preflight do not signal accepted API traffic")
        let (models, modelReply) = try await request("/models", method: "GET")
        try require(modelReply.statusCode == 200 && String(decoding: models, as: UTF8.self).contains("mock"), "models")
        try require(!engine.loaded, "listing models must not load the worker")
        try require(server.requestActivity && server.lastRequestAt != nil, "short authenticated request signals API activity")
        try await Task.sleep(for: .milliseconds(2200))
        try require(!server.requestActivity && server.lastRequestAt != nil, "activity pulse ends while last receipt remains")
        let (first, firstReply) = try await request(body: body("hello"))
        try require(firstReply.statusCode == 200, "completion: \(String(decoding: first, as: UTF8.self))")
        let firstText = try content(first)
        try require(firstText.hasSuffix(":訳:hello") && engine.loaded, "completion and model load")
        try require(server.inference.hasLoadedModel, "menu model status follows actual worker load")
        func timings(_ data: Data) throws -> [String: Double] {
            let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            guard let values = object["timings"] as? [String: Double] else { throw checkFailure("missing API timings") }
            return values
        }
        let measured = try timings(first)
        try require(measured["generation_tps"] == 30 && measured["prompt_seconds"] == 0.05 && measured["generation_seconds"] == 0.1, "separate prompt and generation timings")
        try require(measured["total_seconds"]! >= measured["first_content_seconds"]! && measured["first_content_seconds"]! >= measured["queue_seconds"]!, "server timing boundaries")
        try require(server.lastTimings == measured, "API metrics available independently of editor metrics")
        let (second, _) = try await request(body: body("again"))
        try require(try content(second).split(separator: ":").first == firstText.split(separator: ":").first, "worker reuse")
        let (sse, sseReply) = try await request(body: body("stream", stream: true))
        let events = String(decoding: sse, as: UTF8.self)
        try require(sseReply.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true && events.contains("chat.completion.chunk") && events.contains("[DONE]"), "streaming")
        try require(events.contains("\"timings\"") && !events.contains("\"usage\""), "stream timings without unrequested usage event")
        try require(!events.contains("discarded") && !events.contains("provisional"), "API streams only committed translation text")
        var usageRequest = body("stream usage", stream: true)
        usageRequest["stream_options"] = ["include_usage": true]
        let (usageStream, _) = try await request(body: usageRequest)
        let usageEvents = try String(decoding: usageStream, as: UTF8.self).components(separatedBy: "\n")
            .filter { $0.hasPrefix("data: {") }.map { try JSONSerialization.jsonObject(with: Data($0.dropFirst(6).utf8)) as! [String: Any] }
        try require(usageEvents.count >= 4 && usageEvents.last?["usage"] != nil && (usageEvents.last?["choices"] as? [Any])?.isEmpty == true, "opt-in SSE usage event before DONE")
        try require(engine.input == "keep input" && engine.output == "keep output" && engine.context == "keep context", "API must preserve editor text")
        let (_, invalid) = try await request(body: ["messages": [["role": "user", "content": "x"]], "target_lang": "invalid"])
        try require(invalid.statusCode == 400, "language validation")
        let (_, conversation) = try await request(body: ["messages": [["role": "assistant", "content": "x"], ["role": "user", "content": "y"]]])
        try require(conversation.statusCode == 400, "unsupported history")
        let (_, unknown) = try await request(body: ["model": "missing", "messages": [["role": "user", "content": "x"]]])
        try require(unknown.statusCode == 404, "unknown model")
        let (_, oversized) = try await request(body: body(String(repeating: "a", count: 1024 * 1024)))
        try require(oversized.statusCode == 413, "body size limit")
        server.inference.maxConcurrency = 1
        let pending = Task { try await request(body: body("slow")) }
        for _ in 0..<100 {
            if engine.busy { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let queued = Task { try await request(body: body("queued")) }
        for _ in 0..<100 {
            if server.inference.waitingCount == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(server.inference.waitingCount == 1, "burst request waits instead of 429")
        try await Task.sleep(for: .milliseconds(80))
        engine.cancel()
        let (_, cancelled) = try await pending.value
        try require(cancelled.statusCode == 503, "explicit cancellation")
        let (queuedData, queuedReply) = try await queued.value
        try require(queuedReply.statusCode == 200 && (try content(queuedData)).hasSuffix(":訳:queued"), "queue drains after cancellation")
        try require(try timings(queuedData)["queue_seconds"]! >= 0.08, "queue timing includes actual waiting")
        let disconnected = Task { try await request(body: body("slow")) }
        for _ in 0..<100 {
            if engine.busy { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(2200))
        try require(server.requestActivity, "long API request remains visible beyond activity pulse")
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
        try require(!engine.loaded && !server.inference.hasLoadedModel, "idle unload updates menu model status")
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
        try require(!engine.busy && !engine.loaded && !server.requestActivity && server.lastRequestAt == nil, "server stop clears activity")
        try await checkPool(preferences, engine: engine)
        print("PASS: auth, CORS, models, JSON/SSE, validation, limits, worker reuse, queue, cancellation/disconnect/stop, failure/crash, idle unload/reload, editor isolation (mock inference)")
    }


    @MainActor
    static func checkPool(_ preferences: Preferences, engine: Translator) async throws {
        preferences.unloadSeconds = 60
        var resources = ServerResources(availableBytes: 128 * 1024 * 1024 * 1024, onACPower: true, lowPower: false, hot: false)
        let pool = ServerInferencePool(preferences: preferences, translator: engine, resources: { resources },
                                       budget: { _ in .init(weights: 1024 * 1024 * 1024, cache: 1024 * 1024 * 1024) })
        pool.maxConcurrency = 2
        pool.reserveGB = 4
        pool.allowBattery = false
        pool.start()
        defer { pool.stop() }
        func translate(_ text: String) async throws -> String {
            let r = TranslationRequest(model: "/mock", text: text, source: "", target: "ja", form: "", context: "", glossary: [], max_tokens: 32, temperature: 0)
            return try await pool.translate(r) { _ in }.0
        }
        func waitFor(_ condition: () -> Bool) async throws {
            for _ in 0..<300 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw checkFailure("pool condition timed out")
        }
        let first = Task { try await translate("slow") }
        try await waitFor { pool.isLoadingModel && !pool.hasLoadedModel }
        try require(!engine.loaded, "assigned cold worker is loading, not loaded")
        try await waitFor { engine.loaded && engine.busy && pool.hasLoadedModel }
        let second = Task { try await translate("slow") }
        try await waitFor { pool.activeCount == 2 && pool.loadedCount == 2 }
        second.cancel()
        _ = try? await second.value
        try await waitFor { pool.activeCount == 1 }
        try require(engine.busy && engine.loaded, "cancelling surplus worker preserves first request")
        let parallel = try await translate("parallel")
        try require(parallel.hasSuffix(":訳:parallel") && engine.busy, "independent worker completes while primary is busy")
        // Queue cancellation must not cancel an unrelated running request.
        resources.lowPower = true
        let queued = Task { try await translate("cancelled queue") }
        try await waitFor { pool.waitingCount == 1 }
        queued.cancel()
        _ = try? await queued.value
        try await waitFor { pool.waitingCount == 0 }
        try require(engine.busy, "queued cancellation preserves active inference")
        first.cancel()
        _ = try? await first.value
        try await waitFor { pool.activeCount == 0 }
        for mode in 0..<5 {
            resources.lowPower = mode == 0
            resources.hot = mode == 1
            resources.onACPower = mode != 2
            resources.memoryPressure = mode == 3
            resources.availableBytes = mode == 4 ? 1 : 128 * 1024 * 1024 * 1024
            let active = Task { try await translate("slow") }
            try await waitFor { engine.busy && engine.loaded }
            let waiting = Task { try await translate("guarded") }
            try await waitFor { pool.waitingCount == 1 }
            try require(pool.activeCount == 1, "resource guard \(mode) prevents expansion")
            active.cancel()
            _ = try? await active.value
            try require(try await waiting.value.hasSuffix(":訳:guarded"), "resource guard still drains queue")
        }
        resources = ServerResources(availableBytes: 128 * 1024 * 1024 * 1024, onACPower: true, lowPower: false, hot: false)
        pool.maxConcurrency = 1
        engine.input = "slow"
        engine.modelID = preferences.models.first?.id
        engine.translate()
        try await waitFor { engine.busy && engine.loaded }
        let behindEditor = Task { try await translate("behind editor") }
        try await waitFor { pool.waitingCount == 1 }
        pool.stop()
        _ = try? await behindEditor.value
        try require(engine.busy && engine.loaded, "server stop preserves editor-owned worker")
        engine.cancel()
        try await waitFor { !pool.hasLoadedModel && !pool.isLoadingModel }
        engine.translate()
        try await waitFor { pool.hasLoadedModel }
        try require(engine.loaded, "model status updates for editor translation while server is stopped")
        engine.cancel()
        try await waitFor { !pool.hasLoadedModel }
        pool.start()
        let active = Task { try await translate("slow") }
        try await waitFor { engine.busy }
        let waiting = (0..<ServerInferencePool.queueLimit).map { i in Task { try await translate("queued \(i)") } }
        try await waitFor { pool.waitingCount == ServerInferencePool.queueLimit }
        do { _ = try await translate("overflow"); throw checkFailure("queue overflow accepted") }
        catch let error as APIError { try require(error.status == 429, "bounded queue returns 429") }
        pool.stop()
        _ = try? await active.value
        for task in waiting { _ = try? await task.value }
        try require(pool.waitingCount == 0 && !engine.busy && !engine.loaded, "stop drains all queued continuations and terminates active worker")
        print("PASS: adaptive independent workers, isolated cancellation, queued cancellation, power/thermal/pressure/memory guards, bounded queue, stop")
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
