import AppKit
import Combine
import Darwin
import Foundation
import UniformTypeIdentifiers

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
    var queue_seconds: Double?
    var chunk: Int?
    var chunks: Int?
    var reason: String?
    var retries: Int?
}

@MainActor
final class Translator: ObservableObject {
    @Published var input = "" { didSet {
        if fetchingArticle { cancelArticleFetch() }
        if importingFile { cancelFileImport() }
        updateInputStatistics()
    } }
    @Published private(set) var importingFile = false
    @Published private(set) var fileProgress = ""
    @Published var fileError: String?
    @Published var exportError: String?
    @Published var pendingPDF: URL?
    private var fileTask: Task<Void, Never>?
    private var fileRevision = UUID()
    @Published var articleURL = ""
    @Published private(set) var fetchingArticle = false
    @Published var articleError: String?
    private var articleTask: Task<Void, Never>?
    private var articleRevision = UUID()
    @Published private(set) var inputStatistics = InputStatistics()
    @Published private(set) var detectedInputLanguage: String?
    @Published var sourcePreview = false
    @Published private(set) var inputFocusRequest: UUID? = UUID()
    @Published var outputPreview = false
    @Published var output = ""
    @Published var modelID: UUID?
    @Published var source = ""
    @Published var target = "ja" { didSet { initialTargetChosen = true } }
    @Published var form = ""
    @Published var context = ""
    @Published var presetID: String?
    var selectedPreset: ContextPreset? { preferences.contextPresets.first { $0.id == presetID } }
    var translationContext: String {
        [selectedPreset?.contextDescription ?? "", context].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n")
    }

    func applyAppPreset(bundleID: String?) {
        guard let bundleID,
              let id = preferences.appPresetRules.first(where: { $0.id == bundleID })?.presetID,
              preferences.contextPresets.contains(where: { $0.id == id }) else { return }
        presetID = id
    }
    @Published var useGlossary = true
    @Published var optionsExpanded = false
    @Published var maxTokens = 4096
    @Published var temperature = 0.0
    @Published private(set) var busy = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var loaded = false
    @Published private(set) var status = ""
    @Published private(set) var recoveryStatus = ""
    @Published private(set) var translationCompleted = false
    @Published private(set) var progress: Double?
    @Published private(set) var metrics: WorkerEvent?
    @Published var error: String?

    private var apiCompletion: CheckedContinuation<(String, WorkerEvent), Error>?
    private var apiDelta: ((String) -> Void)?
    private var apiOutput = ""
    private var apiRequestID: UUID?
    private var committedOutput = ""
    private var showingDraft = false
    private var chunkLabel = ""
    var servingAPI: Bool { apiRequestID != nil }

    private var process: Process?
    private var stdin: FileHandle?
    private var identity = UUID()
    private var loadedPath: String?
    private var pythonPath: String?
    private var idleTask: Task<Void, Never>?
    private var statisticsTask: Task<Void, Never>?
    private var statisticsRevision = UUID()
    private var initialTargetChosen = false
    private var settingsSubscription: AnyCancellable?
    private var quitSubscription: AnyCancellable?
    private let preferences: Preferences
    private let idleSecondsOverride: Int?
    var loadedModelPath: String? { loaded ? loadedPath : nil }

    init(preferences: Preferences, idleSecondsOverride: Int? = nil) {
        self.preferences = preferences
        self.idleSecondsOverride = idleSecondsOverride
        modelID = preferences.preferredModelID
        optionsExpanded = preferences.models.isEmpty
        settingsSubscription = preferences.$unloadSeconds.dropFirst().sink { [weak self] seconds in
            Task { @MainActor in self?.scheduleUnload(seconds: self?.idleSecondsOverride ?? seconds) }
        }
        quitSubscription = NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                self?.cancelArticleFetch()
                self?.cancelFileImport()
                self?.cancel()
            }
    }

    var canTranslate: Bool {
        !busy && !fetchingArticle && !importingFile && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        preferences.models.contains { $0.id == modelID } && maxTokens > 0 && maxTokens < 32768 &&
        temperature.isFinite && (0...2).contains(temperature)
    }

    func importSelection(_ text: String) {
        if busy { cancel() }
        cancelArticleFetch()
        cancelFileImport()
        fileError = nil
        error = nil
        articleError = nil
        sourcePreview = false
        input = text
        output = ""
        metrics = nil
        progress = nil
        status = ""
        recoveryStatus = ""
        translationCompleted = false
        inputFocusRequest = UUID()
    }

    func focusInput() {
        sourcePreview = false
        inputFocusRequest = UUID()
    }

    func fetchArticle() {
        guard !fetchingArticle, !importingFile, !busy else { return }
        let url: URL
        do { url = try ArticleFetcher.url(from: articleURL) }
        catch { articleError = error.localizedDescription; return }
        articleError = nil
        fetchingArticle = true
        let revision = UUID()
        articleRevision = revision
        articleTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let markdown = try await ArticleFetcher.fetch(url)
                try Task.checkCancellation()
                await self?.finishArticleFetch(markdown: markdown, error: nil, revision: revision)
            } catch {
                guard !Task.isCancelled else { return }
                await self?.finishArticleFetch(markdown: nil, error: error.localizedDescription, revision: revision)
            }
        }
    }

    func cancelArticleFetch() {
        articleRevision = UUID()
        articleTask?.cancel()
        articleTask = nil
        fetchingArticle = false
    }

    private func finishArticleFetch(markdown: String?, error: String?, revision: UUID) {
        guard revision == articleRevision else { return }
        articleTask = nil
        fetchingArticle = false
        articleError = error
        if let markdown {
            sourcePreview = false
            input = markdown
            focusInput()
        }
    }

    func chooseFile() {
        guard !busy, !fetchingArticle, !importingFile else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .plainText] + TextFileImporter.extensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "取り込む"
        panel.message = "PDFまたはテキストファイルを読み込み、原文を置き換えます。処理は端末内で完結します。"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                if url.pathExtension.lowercased() == "pdf" {
                    self?.pendingPDF = url
                } else {
                    self?.importFile(url)
                }
            }
        }
    }

    func saveOutput() {
        guard !output.isEmpty, !busy else { return }
        let text = output
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "翻訳結果.md"
        let formatPicker = OutputFormatPicker(panel: panel)
        panel.accessoryView = formatPicker
        panel.canCreateDirectories = true
        panel.title = "訳文を保存"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try await Task.detached(priority: .userInitiated) {
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        try text.write(to: url, atomically: true, encoding: .utf8)
                    }.value
                } catch {
                    self?.exportError = error.localizedDescription
                }
            }
        }
    }

    func importFile(_ url: URL, pageRange: ClosedRange<Int>? = nil) {
        guard !busy, !fetchingArticle, !importingFile else { return }
        fileError = nil
        importingFile = true
        fileProgress = "ファイルを読み込み中"
        let revision = UUID()
        fileRevision = revision
        let importPython = preferences.python
        fileTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let text: String
                let status: String
                if url.pathExtension.lowercased() == "pdf" {
                    guard let script = Bundle.module.url(forResource: "pdf_importer", withExtension: "py", subdirectory: "Resources") else {
                        throw PDFImporter.ImportError.setup
                    }
                    let result = try await PDFImporter.convert(url, python: importPython, script: script, pageRange: pageRange) { current, total in
                        await self?.updateFileProgress(current, total: total, revision: revision)
                    }
                    text = result.markdown
                    status = "PDF \(result.pages)ページ取り込み済み（Docling）"
                } else {
                    text = try TextFileImporter.read(url)
                    status = "テキスト取り込み済み"
                }
                try Task.checkCancellation()
                await self?.finishFileImport(text, status: status, error: nil, revision: revision)
            } catch {
                guard !Task.isCancelled else { return }
                await self?.finishFileImport(nil, status: "", error: error.localizedDescription, revision: revision)
            }
        }
    }

    func cancelFileImport() {
        fileRevision = UUID()
        fileTask?.cancel()
        fileTask = nil
        importingFile = false
        fileProgress = ""
    }

    private func updateFileProgress(_ current: Int, total: Int, revision: UUID) {
        guard revision == fileRevision else { return }
        fileProgress = total == 0 ? "Doclingを準備中" : "DoclingでPDFを変換中 \(current)/\(total)ページ"
    }

    private func finishFileImport(_ text: String?, status: String, error: String?, revision: UUID) {
        guard revision == fileRevision else { return }
        fileTask = nil
        importingFile = false
        fileProgress = ""
        fileError = error
        if let text {
            importSelection(text)
            self.status = status
        }
    }

    private func updateInputStatistics() {
        statisticsTask?.cancel()
        let text = input
        let detectInitialTarget = !initialTargetChosen
        let revision = UUID()
        statisticsRevision = revision
        statisticsTask = Task.detached(priority: .utility) { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
                let statistics = try InputStatistics.measure(text)
                let language = InputLanguage.detectedLanguage(for: text)
                let initialTarget = detectInitialTarget ? language.map { $0 == "ja" ? "en" : "ja" } : nil
                try Task.checkCancellation()
                await self?.applyInputStatistics(statistics, language: language, initialTarget: initialTarget, revision: revision)
            } catch { /* Replaced by more recent input. */ }
        }
    }

    private func applyInputStatistics(_ statistics: InputStatistics, language: String?, initialTarget: String?, revision: UUID) {
        guard revision == statisticsRevision else { return }
        detectedInputLanguage = language
        inputStatistics = statistics
        chooseInitialTarget(initialTarget)
    }

    private func chooseInitialTarget(_ detectedTarget: String?) {
        guard !initialTargetChosen, !busy, let detectedTarget else { return }
        target = detectedTarget
    }

    func translate() {
        guard canTranslate, let location = preferences.models.first(where: { $0.id == modelID }) else { return }
        // Enter may arrive before the debounced analysis finishes. Resolve the first
        // target from the same bounded sample before constructing the worker request.
        if !initialTargetChosen { chooseInitialTarget(InputLanguage.initialTarget(for: input)) }
        let terms = useGlossary ? preferences.glossary.filter { !$0.source.isEmpty || !$0.target.isEmpty } : []
        if terms.contains(where: { $0.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            error = "辞書の原語と訳語を入力してください。"
            return
        }
        let request = TranslationRequest(
            model: location.path, text: input, source: source, target: target,
            form: target == "ja" ? form : "", context: translationContext,
            glossary: terms.map { ["source": $0.source, "target": $0.target] },
            max_tokens: maxTokens, temperature: temperature, auto_split: preferences.autoSplit)
        output = ""
        begin(request)
    }

    func translateAPI(_ request: TranslationRequest, delta: @escaping (String) -> Void) async throws -> (String, WorkerEvent) {
        guard !busy else { throw APIError(status: 429, message: "別の翻訳を実行中です。完了後に再試行してください。") }
        try Task.checkCancellation()
        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                apiRequestID = requestID
                apiCompletion = continuation
                apiDelta = delta
                apiOutput = ""
                begin(request)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                if self?.apiRequestID == requestID { self?.cancel() }
            }
        }
    }

    private func finishAPI(_ result: Result<(String, WorkerEvent), Error>) {
        let completion = apiCompletion
        apiCompletion = nil
        apiDelta = nil
        apiOutput = ""
        apiRequestID = nil
        completion?.resume(with: result)
    }

    private func begin(_ request: TranslationRequest) {
        idleTask?.cancel()
        busy = true
        startedAt = Date()
        if !servingAPI { error = nil }
        metrics = nil
        progress = nil
        committedOutput = ""
        showingDraft = false
        chunkLabel = ""
        recoveryStatus = ""
        translationCompleted = false
        status = "モデルを読み込み中"
        do {
            if loadedPath != request.model || pythonPath != preferences.python || process?.isRunning != true {
                stopProcess()
                try startProcess(model: request.model)
            }
            var data = try JSONEncoder().encode(request)
            data.append(0x0A)
            // Even a large source/glossary must not block the main thread on a full pipe.
            let handle = stdin
            let ticket = identity
            Task.detached { [weak self] in
                do { try handle?.write(contentsOf: data) }
                catch { await self?.writeFailed(error.localizedDescription, ticket: ticket) }
            }
        } catch {
            fail(error)
        }
    }

    private func fail(_ failure: Error) {
        if servingAPI { finishAPI(.failure(failure)) }
        else { error = failure.localizedDescription }
        busy = false
        translationCompleted = false
        progress = nil
        status = "翻訳失敗"
        if !recoveryStatus.isEmpty { recoveryStatus += "（失敗により停止）" }
        stopProcess()
    }

    private func writeFailed(_ message: String, ticket: UUID) {
        guard ticket == identity else { return }
        fail(APIError(status: 500, message: message))
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
        case "planning":
            loaded = true
            status = "原文を分割中"
            progress = nil
        case "chunk":
            chunkLabel = (event.chunks ?? 1) > 1 ? "（\(event.chunk ?? 1)/\(event.chunks ?? 1)）" : ""
            status = "入力を処理中" + chunkLabel
            progress = nil
        case "retry":
            let reason = event.reason == "repetition" ? "繰り返しを検出" : "生成上限に到達"
            recoveryStatus = "\(reason) → 該当部分を小さく分割して再翻訳（再試行\(event.retries ?? 1)回目）"
            status = "再分割して再試行中"
            progress = nil
        case "prefill":
            loaded = true
            status = "入力を処理中" + chunkLabel
            progress = Double(event.current ?? 0) / Double(max(1, event.total ?? 1))
        case "draft":
            loaded = true
            status = "翻訳中" + chunkLabel
            progress = nil
            if !servingAPI {
                if !showingDraft { committedOutput = output }
                showingDraft = true
                output = committedOutput + (event.text ?? "")
            }
            if event.tokens != nil { metrics = event }
        case "delta":
            loaded = true
            status = "翻訳中" + chunkLabel
            progress = nil
            if servingAPI {
                let text = event.text ?? ""
                apiOutput += text
                apiDelta?(text)
            } else if showingDraft {
                output = committedOutput + (event.text ?? "")
                showingDraft = false
                committedOutput = ""
            } else { output += event.text ?? "" }
            if event.tokens != nil { metrics = event }
        case "done":
            metrics = event
            busy = false
            progress = nil
            translationCompleted = event.finish_reason != "length"
            status = translationCompleted ?
                ((event.chunks ?? 1) > 1 ? "翻訳完了（\(event.chunks ?? 1)分割）" : "翻訳完了") :
                "生成上限に到達（訳文は途中まで）"
            if let retries = event.retries, retries > 0 {
                recoveryStatus = "再分割・再試行\(retries)回で完了"
            }
            if servingAPI { finishAPI(.success((apiOutput, event))) }
            scheduleUnload(seconds: idleSecondsOverride ?? preferences.unloadSeconds)
        case "error":
            fail(APIError(status: 500, message: event.message ?? "翻訳に失敗しました。"))
        default: break
        }
    }

    private func exited(ticket: UUID, details: String) {
        guard ticket == identity else { return }
        if busy {
            fail(APIError(status: 500, message: details.isEmpty ? "Pythonプロセスが終了しました。" : servingAPI ? "Pythonプロセスが終了しました。実行環境とモデルを確認してください。" : details))
        } else {
            stopProcess()
        }
    }

    func cancel() {
        if servingAPI { finishAPI(.failure(CancellationError())) }
        stopProcess()
        busy = false
        translationCompleted = false
        progress = nil
        status = "中止"
        if !recoveryStatus.isEmpty { recoveryStatus += "（中止）" }
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
        committedOutput = ""
        showingDraft = false
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

private final class OutputFormatPicker: NSPopUpButton {
    private weak var panel: NSSavePanel?

    init(panel: NSSavePanel) {
        self.panel = panel
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 28), pullsDown: false)
        addItems(withTitles: ["Markdown (.md)", "テキスト (.txt)"])
        setAccessibilityLabel("保存形式")
        target = self
        action = #selector(changeFormat)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func changeFormat() {
        guard let panel else { return }
        let ext = indexOfSelectedItem == 0 ? "md" : "txt"
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .plainText]
        panel.nameFieldStringValue = (panel.nameFieldStringValue as NSString).deletingPathExtension + "." + ext
    }
}
