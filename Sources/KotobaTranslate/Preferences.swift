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

enum EditorWeight: String, Codable, CaseIterable, Identifiable {
    case light, regular, medium, semibold, bold
    var id: String { rawValue }
    var label: String {
        switch self {
        case .light: "Light"
        case .regular: "Regular"
        case .medium: "Medium"
        case .semibold: "Semibold"
        case .bold: "Bold"
        }
    }
    var native: NSFont.Weight {
        switch self {
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }
    var swiftUI: Font.Weight {
        switch self {
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }
    var familyWeight: Int {
        switch self {
        case .light: 3
        case .regular: 5
        case .medium: 6
        case .semibold: 8
        case .bold: 9
        }
    }
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
    @Published var models: [ModelLocation] { didSet { save() } }
    @Published var defaultModelID: UUID? { didSet { save() } }
    @Published var glossary: [GlossaryTerm] { didSet { save() } }
    @Published var python: String { didSet { save() } }
    @Published var unloadSeconds: Int { didSet { save() } }
    @Published var sourceFontFamily: String { didSet { save() } }
    @Published var sourceFontSize: Double { didSet { save() } }
    @Published var outputFontFamily: String { didSet { save() } }
    @Published var outputFontSize: Double { didSet { save() } }
    @Published var sourceFontWeight: EditorWeight { didSet { save() } }
    @Published var outputFontWeight: EditorWeight { didSet { save() } }
    @Published var sourceTextColor: EditorColor? { didSet { save() } }
    @Published var outputTextColor: EditorColor? { didSet { save() } }

    var preferredModelID: UUID? {
        models.first(where: { $0.id == defaultModelID })?.id ?? models.first?.id
    }
    var sourceFont: NSFont { editorFont(family: sourceFontFamily, size: sourceFontSize, weight: sourceFontWeight) }
    var outputFont: NSFont { editorFont(family: outputFontFamily, size: outputFontSize, weight: outputFontWeight) }
    var sourceColor: NSColor { sourceTextColor?.native ?? .textColor }
    var outputColor: NSColor { outputTextColor?.native ?? .textColor }

    private func editorFont(family: String, size: Double, weight: EditorWeight) -> NSFont {
        let size = min(40, max(10, size))
        return NSFontManager.shared.font(withFamily: family, traits: weight == .bold ? [.boldFontMask] : [],
                                         weight: weight.familyWeight, size: size)
            ?? .systemFont(ofSize: size, weight: weight.native)
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
        sourceFontWeight = defaults.string(forKey: "sourceFontWeight").flatMap(EditorWeight.init(rawValue:)) ?? .regular
        outputFontWeight = defaults.string(forKey: "outputFontWeight").flatMap(EditorWeight.init(rawValue:)) ?? .regular
        sourceTextColor = defaults.data(forKey: "sourceTextColor").flatMap { try? JSONDecoder().decode(EditorColor.self, from: $0) }
        outputTextColor = defaults.data(forKey: "outputTextColor").flatMap { try? JSONDecoder().decode(EditorColor.self, from: $0) }
        if !models.contains(where: { $0.id == defaultModelID }) { defaultModelID = nil }
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(try? JSONEncoder().encode(models), forKey: "models")
        defaults.set(defaultModelID?.uuidString, forKey: "defaultModelID")
        defaults.set(try? JSONEncoder().encode(glossary), forKey: "glossary")
        defaults.set(python, forKey: "python")
        defaults.set(unloadSeconds, forKey: "unloadSeconds")
        defaults.set(sourceFontFamily, forKey: "sourceFontFamily")
        defaults.set(sourceFontSize, forKey: "sourceFontSize")
        defaults.set(outputFontFamily, forKey: "outputFontFamily")
        defaults.set(outputFontSize, forKey: "outputFontSize")
        defaults.set(sourceFontWeight.rawValue, forKey: "sourceFontWeight")
        defaults.set(outputFontWeight.rawValue, forKey: "outputFontWeight")
        defaults.set(sourceTextColor.flatMap { try? JSONEncoder().encode($0) }, forKey: "sourceTextColor")
        defaults.set(outputTextColor.flatMap { try? JSONEncoder().encode($0) }, forKey: "outputTextColor")
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
                            weight: $preferences.sourceFontWeight, color: $preferences.sourceTextColor, font: preferences.sourceFont)
                fontSection("訳文", family: $preferences.outputFontFamily, size: $preferences.outputFontSize,
                            weight: $preferences.outputFontWeight, color: $preferences.outputTextColor, font: preferences.outputFont)
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
                             weight: Binding<EditorWeight>, color: Binding<EditorColor?>, font: NSFont) -> some View {
        Section(title) {
            Picker("フォント", selection: family) {
                Text("システム").tag("")
                ForEach(Self.fontFamilies, id: \.self) { Text($0).tag($0) }
            }
            Stepper(value: size, in: 10...40, step: 1) {
                Text("サイズ  \(Int(size.wrappedValue)) pt")
            }
            Picker("ウェイト", selection: weight) {
                ForEach(EditorWeight.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.menu)
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
