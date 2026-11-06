import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    @Published var customPresets: [ContextPreset] { didSet { saveEncoded(customPresets, forKey: "customPresets") } }
    @Published var appPresetRules: [AppPresetRule] { didSet { saveEncoded(appPresetRules, forKey: "appPresetRules") } }
    var contextPresets: [ContextPreset] { ContextPreset.builtIn + customPresets }

    func removePreset(_ id: String) {
        customPresets.removeAll { $0.id == id }
        for index in appPresetRules.indices where appPresetRules[index].presetID == id {
            appPresetRules[index].presetID = nil
        }
    }

    func addPresetApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "追加"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let bundle = Bundle(url: url),
                  let id = bundle.bundleIdentifier else { return }
            Task { @MainActor in
                guard let self, !self.appPresetRules.contains(where: { $0.id == id }) else { return }
                let name = FileManager.default.displayName(atPath: url.path)
                self.appPresetRules.append(AppPresetRule(id: id, name: name))
            }
        }
    }

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
        customPresets = defaults.data(forKey: "customPresets").flatMap { try? JSONDecoder().decode([ContextPreset].self, from: $0) } ?? []
        appPresetRules = defaults.data(forKey: "appPresetRules").flatMap { try? JSONDecoder().decode([AppPresetRule].self, from: $0) } ?? []
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
    @State private var selection: SettingsSection? = .general

    private enum SettingsSection: String, CaseIterable, Identifiable {
        case general, presets, typography, glossary
        var id: Self { self }
        var title: String {
            switch self {
            case .general: "一般"
            case .presets: "プリセット"
            case .typography: "文字"
            case .glossary: "辞書"
            }
        }
        var symbol: String {
            switch self {
            case .general: "cpu"
            case .presets: "text.bubble"
            case .typography: "textformat"
            case .glossary: "character.book.closed"
            }
        }
        var description: String {
            switch self {
            case .general: "モデルと実行環境を管理します。"
            case .presets: "よく使う場面や背景を、翻訳に適用できます。"
            case .typography: "原文と訳文、それぞれの読みやすさを調整します。"
            case .glossary: "すべての翻訳で使う、原語と訳語の対応を登録します。"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                SettingsNavigationLabel(title: section.title, symbol: section.symbol).tag(section)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .textBackgroundColor))
            .navigationTitle("設定")
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
            .safeAreaInset(edge: .bottom) {
                Text("変更は自動的に保存されます")
                    .font(.caption).foregroundStyle(.secondary).padding(20)
            }
        } detail: {
            VStack(spacing: 0) {
                let section = selection ?? .general
                DetailHeading(title: section.title, description: section.description)
                switch section {
                case .general:
                    generalSettings
                case .presets:
                    PresetSettingsView(preferences: preferences)
                case .typography:
                    SettingsPage {
                        fontSection("原文", family: $preferences.sourceFontFamily, size: $preferences.sourceFontSize,
                                    face: $preferences.sourceFontFace, color: $preferences.sourceTextColor, font: preferences.sourceFont)
                        fontSection("訳文", family: $preferences.outputFontFamily, size: $preferences.outputFontSize,
                                    face: $preferences.outputFontFace, color: $preferences.outputTextColor, font: preferences.outputFont)
                    }
                case .glossary:
                    glossarySettings
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(minWidth: 900, idealWidth: 1000, minHeight: 640, idealHeight: 760)
        .background(CompactWindowToolbar())
        .preferredColorScheme(.light)
    }

    private var generalSettings: some View {
        SettingsPage {
            SettingsCard(title: "モデル") {
                HStack(spacing: 14) {
                    SettingsIcon(symbol: "cpu", size: 36)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("PLaMo 3 Translate").font(.headline)
                        Text("ダウンロード済みのMLXモデルを登録します。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("モデルを追加…", systemImage: "plus", action: preferences.addModel)
                        .buttonStyle(.borderedProminent)
                }
                if !preferences.models.isEmpty {
                    Divider()
                    SettingsRow("デフォルト") {
                        Picker("デフォルト", selection: $preferences.defaultModelID) {
                            Text("先頭のモデル").tag(nil as UUID?)
                            ForEach(preferences.models) { Text($0.tag).tag(Optional($0.id)) }
                        }.pickerStyle(.menu).frame(maxWidth: 260)
                    }
                }
                Text("翻訳を開始するまでモデルは読み込みません。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach($preferences.models) { $model in
                SettingsCard(title: "") {
                    SettingsRow("タグ") {
                        TextField("タグ", text: $model.tag).frame(maxWidth: 300)
                            .help("翻訳画面に表示する名前。APIで指定する場合は一意のタグを使います。")
                        Button(role: .destructive) {
                            if preferences.defaultModelID == model.id { preferences.defaultModelID = nil }
                            preferences.models.removeAll { $0.id == model.id }
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("モデル「\(model.tag)」を一覧から削除")
                        .help("登録だけを削除します。モデルのファイルは削除しません。")
                    }
                    Divider()
                    SettingsRow("フォルダ") {
                        TextField("フォルダ", text: $model.path)
                            .font(.system(.callout, design: .monospaced)).help(model.path)
                    }
                    if model.tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Label("タグを入力してください", systemImage: "exclamationmark.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    } else if preferences.models.filter({ $0.tag == model.tag }).count > 1 {
                        Label("APIでタグを指定するには、一意のタグを付けてください。", systemImage: "exclamationmark.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            SettingsCard(title: "メモリ管理") {
                SettingsRow("モデルの自動解放", description: "翻訳画面とローカルAPIに共通です。") {
                    Picker("自動解放", selection: $preferences.unloadSeconds) {
                        Text("翻訳完了後すぐ").tag(0)
                        Text("1分後").tag(60); Text("5分後").tag(300)
                        Text("15分後").tag(900); Text("30分後").tag(1800)
                        Text("アプリ終了時").tag(-1)
                    }.pickerStyle(.menu).frame(width: 160)
                }
                Text("解放後は、次の翻訳時に読み込み直します。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            SettingsCard(title: "実行環境") {
                SettingsRow("Python") {
                    TextField("Python", text: $preferences.python)
                        .font(.system(.callout, design: .monospaced)).help(preferences.python)
                }
                Text("推論に使う実行ファイルの絶対パスです。通常は変更する必要はありません。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var glossarySettings: some View {
        SettingsPage {
            HStack {
                Text("\(preferences.glossary.count)語").foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button("用語を追加", systemImage: "plus") { preferences.glossary.append(GlossaryTerm()) }
                    .buttonStyle(.borderedProminent)
            }
            if preferences.glossary.isEmpty {
                ContentUnavailableView("用語が登録されていません", systemImage: "character.book.closed",
                                       description: Text("「用語を追加」から、原語と訳語を登録できます。"))
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
            } else {
                SettingsCard(title: "用語") {
                    ForEach($preferences.glossary) { $term in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("原語").font(.callout).foregroundStyle(.secondary)
                                TextField("原語", text: $term.source)
                            }
                            Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 8) {
                                Text("訳語").font(.callout).foregroundStyle(.secondary)
                                TextField("訳語", text: $term.target)
                            }
                            Button(role: .destructive) { preferences.glossary.removeAll { $0.id == term.id } } label: {
                                Image(systemName: "trash")
                            }.buttonStyle(.borderless)
                                .help("用語を削除").accessibilityLabel("用語「\(term.source)」を削除")
                        }
                        if term.id != preferences.glossary.last?.id { Divider() }
                    }
                }
            }
            if preferences.glossary.contains(where: { $0.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                Label("原語と訳語を両方入力してください。不要な行は削除できます。", systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func fontSection(_ title: String, family: Binding<String>, size: Binding<Double>,
                             face: Binding<String>, color: Binding<EditorColor?>, font: NSFont) -> some View {
        SettingsCard(title: title) {
            SettingsRow("フォント") {
                Picker("フォント", selection: family) {
                    Text("システム").tag("")
                    ForEach(Self.fontFamilies, id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.menu).frame(maxWidth: 280)
            }
            Divider()
            SettingsRow("書体") {
                Picker("書体", selection: Binding(
                    get: { FontCatalog.selectedFace(family: family.wrappedValue, name: face.wrappedValue)?.id ?? "" },
                    set: { face.wrappedValue = $0 }
                )) {
                    ForEach(FontCatalog.faces(for: family.wrappedValue)) { Text($0.label).tag($0.id) }
                }
                .pickerStyle(.menu).frame(maxWidth: 280)
                .disabled(FontCatalog.faces(for: family.wrappedValue).count < 2)
            }
            Divider()
            SettingsRow("サイズ") {
                Stepper(value: size, in: 10...40, step: 1) {
                    Text("\(Int(size.wrappedValue)) pt").monospacedDigit().frame(width: 54)
                }.labelsHidden().accessibilityLabel("\(title)の文字サイズ")
                Text("\(Int(size.wrappedValue)) pt").monospacedDigit().frame(width: 54)
            }
            Divider()
            SettingsRow("文字色") {
                ColorPicker("文字色", selection: Binding(
                    get: { Color(nsColor: color.wrappedValue?.native ?? .textColor) },
                    set: { color.wrappedValue = EditorColor($0) }
                ), supportsOpacity: false)
                Button("リセット") { color.wrappedValue = nil }.disabled(color.wrappedValue == nil)
            }
            Text("あいうえお 漢字 ABC abc 123").font(Font(font))
                .foregroundStyle(Color(nsColor: color.wrappedValue?.native ?? .textColor))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(18)
                .modifier(ReadingSurface(cornerRadius: 12))
                .accessibilityLabel("\(title)のフォントプレビュー")
        }
    }
}
