import AppKit
import SwiftUI

struct ModelLocation: Identifiable, Codable, Equatable {
    var id = UUID()
    var tag: String
    var path: String
}

struct GlossaryTerm: Identifiable, Codable {
    var id = UUID()
    var source = ""
    var target = ""
}

struct EditorColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var native: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
    init?(_ color: Color) {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        red = rgb.redComponent
        green = rgb.greenComponent
        blue = rgb.blueComponent
    }
}

@MainActor
final class Preferences: ObservableObject {
    @Published var models: [ModelLocation] { didSet { saveEncoded(models, forKey: "models") } }
    @Published var defaultModelID: UUID? { didSet { UserDefaults.standard.set(defaultModelID?.uuidString, forKey: "defaultModelID") } }
    @Published var glossary: [GlossaryTerm] { didSet { saveEncoded(glossary, forKey: "glossary") } }
    @Published var python: String { didSet { UserDefaults.standard.set(python, forKey: "python") } }
    @Published var unloadSeconds: Int { didSet { UserDefaults.standard.set(unloadSeconds, forKey: "unloadSeconds") } }
    @Published var sourceFontFamily: String { didSet {
        sourceFontFace = ""
        UserDefaults.standard.set(sourceFontFamily, forKey: "sourceFontFamily")
    } }
    @Published var sourceFontSize: Double { didSet { UserDefaults.standard.set(sourceFontSize, forKey: "sourceFontSize") } }
    @Published var outputFontFamily: String { didSet {
        outputFontFace = ""
        UserDefaults.standard.set(outputFontFamily, forKey: "outputFontFamily")
    } }
    @Published var outputFontSize: Double { didSet { UserDefaults.standard.set(outputFontSize, forKey: "outputFontSize") } }
    @Published var sourceFontFace: String { didSet { UserDefaults.standard.set(sourceFontFace, forKey: "sourceFontFace") } }
    @Published var outputFontFace: String { didSet { UserDefaults.standard.set(outputFontFace, forKey: "outputFontFace") } }
    @Published var sourceTextColor: EditorColor? { didSet { saveEncoded(sourceTextColor, forKey: "sourceTextColor") } }
    @Published var outputTextColor: EditorColor? { didSet { saveEncoded(outputTextColor, forKey: "outputTextColor") } }

    var preferredModelID: UUID? {
        models.first(where: { $0.id == defaultModelID })?.id ?? models.first?.id
    }
    var sourceFont: NSFont { editorFont(family: sourceFontFamily, size: sourceFontSize, face: sourceFontFace) }
    var outputFont: NSFont { editorFont(family: outputFontFamily, size: outputFontSize, face: outputFontFace) }
    var sourceColor: NSColor { sourceTextColor?.native ?? .textColor }
    var outputColor: NSColor { outputTextColor?.native ?? .textColor }

    private func editorFont(family: String, size: Double, face: String) -> NSFont {
        let size = min(40, max(10, size))
        let name = FontCatalog.selectedFace(family: family, name: face)?.id
        return name.flatMap { NSFont(name: $0, size: size) } ?? .systemFont(ofSize: size)
    }

    init() {
        let defaults = UserDefaults.standard
        models = defaults.data(forKey: "models").flatMap { try? JSONDecoder().decode([ModelLocation].self, from: $0) } ?? []
        defaultModelID = defaults.string(forKey: "defaultModelID").flatMap(UUID.init(uuidString:))
        glossary = defaults.data(forKey: "glossary").flatMap { try? JSONDecoder().decode([GlossaryTerm].self, from: $0) } ?? []
        let resource = Bundle.main.url(forResource: "python-path", withExtension: "txt")
        let bundledPath = resource.flatMap { try? String(contentsOf: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
        python = defaults.string(forKey: "python") ?? bundledPath ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".venv/bin/python").path
        unloadSeconds = defaults.object(forKey: "unloadSeconds") as? Int ?? 300
        sourceFontFamily = defaults.string(forKey: "sourceFontFamily") ?? ""
        sourceFontSize = defaults.object(forKey: "sourceFontSize") as? Double ?? 16
        outputFontFamily = defaults.string(forKey: "outputFontFamily") ?? ""
        outputFontSize = defaults.object(forKey: "outputFontSize") as? Double ?? 16
        sourceFontFace = defaults.string(forKey: "sourceFontFace") ?? ""
        outputFontFace = defaults.string(forKey: "outputFontFace") ?? ""
        sourceTextColor = defaults.data(forKey: "sourceTextColor").flatMap { try? JSONDecoder().decode(EditorColor.self, from: $0) }
        outputTextColor = defaults.data(forKey: "outputTextColor").flatMap { try? JSONDecoder().decode(EditorColor.self, from: $0) }
        if !models.contains(where: { $0.id == defaultModelID }) { defaultModelID = nil }
    }

    private func saveEncoded<T: Encodable>(_ value: T?, forKey key: String) {
        UserDefaults.standard.set(value.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
    }

    func addModel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "追加"
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self, !self.models.contains(where: { $0.path == url.path }) else { return }
                self.models.append(ModelLocation(tag: url.lastPathComponent, path: url.path))
            }
        }
    }
}

struct Language: Identifiable {
    let id: String
    let name: String
    static let all: [Language] = {
        let codes = "ja en zh-hans zh-hant ko ar az be bg bn ca ceb de es et eu fa fr gu he hi hr hu hy id it jv ka kk km lt lv ml mr ms my ne nl pa pl ru si sk sl sr sw ta te th tl ur uz vi".split(separator: " ").map(String.init)
        let locale = Locale(identifier: "ja")
        return codes.map { code in
            Language(id: code, name: code == "zh-hans" ? "中国語（簡体字）" : code == "zh-hant" ? "中国語（繁体字）" : locale.localizedString(forLanguageCode: code) ?? code)
        }
    }()
}

struct PreferencesView: View {
    @ObservedObject var preferences: Preferences
    private static let fontFamilies = NSFontManager.shared.availableFontFamilies.sorted()
    var body: some View {
        TabView {
            Form {
                Section("モデル") {
                    Picker("デフォルト", selection: $preferences.defaultModelID) {
                        Text("先頭のモデル").tag(nil as UUID?)
                        ForEach(preferences.models) { Text($0.tag).tag(Optional($0.id)) }
                    }.pickerStyle(.menu)
                    ForEach($preferences.models) { $model in
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                TextField("タグ", text: $model.tag)
                                TextField("ディレクトリ", text: $model.path).font(.caption)
                            }
                            Button(role: .destructive) {
                                if preferences.defaultModelID == model.id { preferences.defaultModelID = nil }
                                preferences.models.removeAll { $0.id == model.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }.buttonStyle(.borderless).help("モデルを一覧から削除")
                        }
                    }
                    Button("モデルを追加…", action: preferences.addModel)
                }
                Section("実行環境") {
                    TextField("Python", text: $preferences.python)
                    Picker("自動解放", selection: $preferences.unloadSeconds) {
                        Text("翻訳完了後すぐ").tag(0)
                        Text("1分後").tag(60)
                        Text("5分後").tag(300)
                        Text("15分後").tag(900)
                        Text("30分後").tag(1800)
                        Text("アプリ終了時").tag(-1)
                    }
                }
            }.formStyle(.grouped).tabItem { Label("一般", systemImage: "gearshape") }
            Form {
                fontSection("原文", family: $preferences.sourceFontFamily, size: $preferences.sourceFontSize,
                            face: $preferences.sourceFontFace, color: $preferences.sourceTextColor, font: preferences.sourceFont)
                fontSection("訳文", family: $preferences.outputFontFamily, size: $preferences.outputFontSize,
                            face: $preferences.outputFontFace, color: $preferences.outputTextColor, font: preferences.outputFont)
            }.formStyle(.grouped).tabItem { Label("文字", systemImage: "textformat") }
            VStack(spacing: 12) {
                HStack {
                    Text("原語").frame(maxWidth: .infinity, alignment: .leading)
                    Text("訳語").frame(maxWidth: .infinity, alignment: .leading)
                    Spacer().frame(width: 24)
                }.foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack {
                        ForEach($preferences.glossary) { $term in
                            HStack {
                                TextField("原語", text: $term.source)
                                TextField("訳語", text: $term.target)
                                Button { preferences.glossary.removeAll { $0.id == term.id } } label: {
                                    Image(systemName: "minus.circle")
                                }.buttonStyle(.borderless).help("用語を削除")
                            }
                        }
                    }
                }
                HStack {
                    Button("用語を追加", systemImage: "plus") { preferences.glossary.append(GlossaryTerm()) }
                    Spacer()
                }
            }.padding(20).textFieldStyle(.roundedBorder)
                .tabItem { Label("辞書", systemImage: "character.book.closed") }
        }
        .frame(width: 620, height: 440)
        .preferredColorScheme(.light)
    }

    private func fontSection(_ title: String, family: Binding<String>, size: Binding<Double>,
                             face: Binding<String>, color: Binding<EditorColor?>, font: NSFont) -> some View {
        Section(title) {
            Picker("フォント", selection: family) {
                Text("システム").tag("")
                ForEach(Self.fontFamilies, id: \.self) { Text($0).tag($0) }
            }
            Stepper(value: size, in: 10...40, step: 1) {
                Text("サイズ  \(Int(size.wrappedValue)) pt")
            }
            Picker("書体", selection: Binding(
                get: { FontCatalog.selectedFace(family: family.wrappedValue, name: face.wrappedValue)?.id ?? "" },
                set: { face.wrappedValue = $0 }
            )) {
                ForEach(FontCatalog.faces(for: family.wrappedValue)) { Text($0.label).tag($0.id) }
            }
            .pickerStyle(.menu)
            .disabled(FontCatalog.faces(for: family.wrappedValue).count < 2)
            HStack {
                ColorPicker("文字色", selection: Binding(
                    get: { Color(nsColor: color.wrappedValue?.native ?? .textColor) },
                    set: { color.wrappedValue = EditorColor($0) }
                ), supportsOpacity: false)
                Button("リセット") { color.wrappedValue = nil }
                    .disabled(color.wrappedValue == nil)
            }
            Text("あいうえお 漢字 ABC abc 123").font(Font(font))
                .foregroundStyle(Color(nsColor: color.wrappedValue?.native ?? .textColor))
        }
    }
}
