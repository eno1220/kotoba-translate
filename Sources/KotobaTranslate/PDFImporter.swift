import Foundation

/// Docling runs independently from the translation worker and never retains a document.
enum PDFImporter {
    struct Result {
        let markdown: String
        let pages: Int
    }

    enum ImportError: LocalizedError {
        case unreadable, locked, tooLarge, empty, setup, conversion
        var errorDescription: String? {
            switch self {
            case .unreadable: return "PDFを開けませんでした。ファイルを確認してください。"
            case .locked: return "パスワードで保護されたPDFです。保護を解除したPDFを選んでください。"
            case .tooLarge: return "PDFが大きすぎます。200MB・1,000ページ・抽出後200万文字以内に分割してください。"
            case .empty: return "PDFから文字を抽出できませんでした。"
            case .setup: return "Doclingの準備が必要です。uv syncとREADMEの解析モデル配置手順を実行し、設定のPythonパスを確認してください。"
            case .conversion: return "DoclingでPDFを変換できませんでした。ファイルと解析モデルの配置を確認してください。"
            }
        }
    }

    // Serializes launch/cancel so a cancellation before launch cannot leave an orphan.
    private final class ConversionProcess: @unchecked Sendable {
        let process = Process()
        private let lock = NSLock()
        private var cancelled = false

        func start() throws {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else { throw CancellationError() }
            try process.run()
        }

        func stop() {
            lock.lock()
            defer { lock.unlock() }
            cancelled = true
            if process.isRunning { process.terminate() }
        }
    }

    static func convert(_ url: URL, python: String, script: URL,
                        progress: @escaping (Int, Int) async -> Void) async throws -> Result {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 200 * 1024 * 1024 else { throw ImportError.tooLarge }
        let python = (python as NSString).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: python),
              FileManager.default.fileExists(atPath: script.path) else { throw ImportError.setup }
        let conversion = ConversionProcess()
        let process = conversion.process
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-u", script.path, url.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = environment
        await progress(0, 0)
        return try await withTaskCancellationHandler {
            defer { try? output.fileHandleForReading.close() }
            do { try conversion.start() }
            catch is CancellationError { throw CancellationError() }
            catch { throw ImportError.setup }
            defer {
                conversion.stop()
                process.waitUntilExit()
            }
            var pending = Data()
            var result: Result?
            var failure: ImportError?
            while true {
                try Task.checkCancellation()
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                // A JSON line may contain up to two million escaped Unicode characters.
                guard pending.count <= 32 * 1024 * 1024 else { throw ImportError.tooLarge }
                while let newline = pending.firstIndex(of: 10) {
                    let line = Data(pending[..<newline])
                    pending.removeSubrange(...newline)
                    guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let kind = event["event"] as? String else { throw ImportError.conversion }
                    switch kind {
                    case "progress":
                        if let current = event["current"] as? Int, let total = event["total"] as? Int {
                            await progress(current, total)
                        }
                    case "result":
                        guard let markdown = event["markdown"] as? String, let pages = event["pages"] as? Int,
                              pages > 0, pages <= 1000 else { throw ImportError.conversion }
                        guard markdown.count <= 2_000_000 else { throw ImportError.tooLarge }
                        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ImportError.empty }
                        result = Result(markdown: markdown, pages: pages)
                    case "error":
                        switch event["code"] as? String {
                        case "locked": failure = .locked
                        case "too_large": failure = .tooLarge
                        case "empty": failure = .empty
                        case "unreadable": failure = .unreadable
                        case "setup": failure = .setup
                        default: failure = .conversion
                        }
                    default: throw ImportError.conversion
                    }
                }
            }
            process.waitUntilExit()
            try Task.checkCancellation()
            if let failure { throw failure }
            guard process.terminationStatus == 0, pending.isEmpty, let result else { throw ImportError.conversion }
            return result
        } onCancel: {
            conversion.stop()
        }
    }
}
