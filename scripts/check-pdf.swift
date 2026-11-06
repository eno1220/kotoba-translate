import AppKit
import CoreText
import Darwin

@main
struct CheckPDF {
    static func main() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let python = root.appendingPathComponent(".venv/bin/python").path
        let worker = root.appendingPathComponent("Sources/KotobaTranslate/Resources/pdf_importer.py")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let nativeURL = directory.appendingPathComponent("native.pdf")
        var rect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(nativeURL as CFURL, mediaBox: &rect, nil)!
        context.beginPDFPage(nil)
        draw("Document title", size: 24, at: CGPoint(x: 50, y: 720), in: context)
        draw("Local PDF extraction works without a translation model.", size: 12, at: CGPoint(x: 50, y: 680), in: context)
        for (row, values) in [["Language", "Words"], ["English", "120"], ["Japanese", "100"]].enumerated() {
            for (column, value) in values.enumerated() {
                draw(value, size: 12, at: CGPoint(x: 60 + column * 180, y: 600 - row * 35), in: context)
            }
        }
        context.setStrokeColor(NSColor.black.cgColor)
        for y in stride(from: 520, through: 625, by: 35) {
            context.move(to: CGPoint(x: 50, y: y))
            context.addLine(to: CGPoint(x: 410, y: y))
        }
        for x in [50, 230, 410] {
            context.move(to: CGPoint(x: x, y: 520))
            context.addLine(to: CGPoint(x: x, y: 625))
        }
        context.strokePath()
        context.endPDFPage()
        context.closePDF()

        let fake = directory.appendingPathComponent("fixture.py")
        try """
        import json
        print(json.dumps(dict(event="progress", current=1, total=1)), flush=True)
        print(json.dumps(dict(event="result", markdown="# 日本語\\n\\n| A | B |", pages=1)), flush=True)
        """.write(to: fake, atomically: true, encoding: .utf8)
        let result = try await PDFImporter.convert(nativeURL, python: python, script: fake) { _, _ in }
        precondition(result.pages == 1 && result.markdown.contains("日本語"))

        let pidFile = directory.appendingPathComponent("pid")
        try """
        import os, pathlib, time
        pathlib.Path(__file__).with_name("pid").write_text(str(os.getpid()))
        time.sleep(60)
        """.write(to: fake, atomically: true, encoding: .utf8)
        let task = Task.detached {
            try await PDFImporter.convert(nativeURL, python: python, script: fake) { _, _ in }
        }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: pidFile.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8))!
        task.cancel()
        do { _ = try await task.value; preconditionFailure("Cancellation should fail") }
        catch is CancellationError { }
        precondition(kill(pid, 0) == -1 && errno == ESRCH, "Cancelled child must exit")
        print("JSON Lines transport and running-child cancellation: passed")

        let invalid = directory.appendingPathComponent("invalid.pdf")
        try Data("invalid".utf8).write(to: invalid)
        do {
            _ = try await PDFImporter.convert(invalid, python: python, script: worker) { _, _ in }
            preconditionFailure("Invalid PDF should fail")
        } catch PDFImporter.ImportError.unreadable { }
        let large = directory.appendingPathComponent("large.pdf")
        FileManager.default.createFile(atPath: large.path, contents: nil)
        let file = try FileHandle(forWritingTo: large)
        try file.truncate(atOffset: 200 * 1024 * 1024 + 1)
        try file.close()
        do {
            _ = try await PDFImporter.convert(large, python: python, script: worker) { _, _ in }
            preconditionFailure("Large PDF should fail")
        } catch PDFImporter.ImportError.tooLarge { }
        print("Real worker invalid PDF and size limit: passed")

        guard CommandLine.arguments.contains("--real") else {
            print("Docling layout/OCR conversion: skipped (use --real after manually preparing models)")
            return
        }
        let native = try await PDFImporter.convert(nativeURL, python: python, script: worker) { _, _ in }
        precondition(native.pages == 1 && native.markdown.contains("Local PDF extraction"))
        precondition(native.markdown.contains("| Language") && native.markdown.contains("Japanese"))
        // Rasterize with CoreGraphics; neither application nor fixtures use PDFKit.
        let imageContext = CGContext(data: nil, width: 1224, height: 1584, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        imageContext.setFillColor(NSColor.white.cgColor)
        imageContext.fill(CGRect(x: 0, y: 0, width: 1224, height: 1584))
        imageContext.scaleBy(x: 2, y: 2)
        imageContext.drawPDFPage(CGPDFDocument(nativeURL as CFURL)!.page(at: 1)!)
        let scanURL = directory.appendingPathComponent("scan.pdf")
        let scanContext = CGContext(scanURL as CFURL, mediaBox: &rect, nil)!
        scanContext.beginPDFPage(nil)
        scanContext.draw(imageContext.makeImage()!, in: rect)
        scanContext.endPDFPage()
        scanContext.closePDF()
        let scan = try await PDFImporter.convert(scanURL, python: python, script: worker) { _, _ in }
        precondition(scan.pages == 1 && scan.markdown.contains("Local PDF extraction"))
        precondition(scan.markdown.contains("| Language") && scan.markdown.contains("Japanese"))
        let blankURL = directory.appendingPathComponent("blank.pdf")
        let blank = CGContext(blankURL as CFURL, mediaBox: &rect, nil)!
        blank.beginPDFPage(nil)
        blank.endPDFPage()
        blank.closePDF()
        do {
            _ = try await PDFImporter.convert(blankURL, python: python, script: worker) { _, _ in }
            preconditionFailure("Blank PDF should fail")
        } catch PDFImporter.ImportError.empty { }
        print("Real Docling native text, scanned OCR, Markdown tables and blank PDF: passed")
    }

    static func draw(_ text: String, size: CGFloat, at point: CGPoint, in context: CGContext) {
        context.textPosition = point
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text,
            attributes: [.font: NSFont(name: "Helvetica", size: size)!])), context)
    }
}
