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

struct EditorFont: Codable, Equatable {
    var family = ""
    var size: Double = 16
    var face = ""

    @MainActor var native: NSFont {
        let size = min(40, max(10, size))
        let name = FontCatalog.selectedFace(family: family, name: face)?.id
        return name.flatMap { NSFont(name: $0, size: size) } ?? .systemFont(ofSize: size)
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
    @Published var autoSplit: Bool { didSet { UserDefaults.standard.set(autoSplit, forKey: "autoSplit") } }
    @Published var defaultFont: EditorFont { didSet { saveEncoded(defaultFont, forKey: "defaultFont") } }
    @Published var languageFonts: [String: EditorFont] { didSet { saveEncoded(languageFonts, forKey: "languageFonts") } }
    @Published var codeFont: EditorFont { didSet { saveEncoded(codeFont, forKey: "codeFont") } }
    @Published var textColor: EditorColor? { didSet { saveEncoded(textColor, forKey: "textColor") } }

    var preferredModelID: UUID? {
        models.first(where: { $0.id == defaultModelID })?.id ?? models.first?.id
    }
    func font(for language: String) -> NSFont {
        (languageFonts[language] ?? defaultFont).native
    }
    var editorColor: NSColor { textColor?.native ?? .textColor }

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
        autoSplit = defaults.object(forKey: "autoSplit") as? Bool ?? true
        // Keep the former source appearance as the shared default on upgrade.
        defaultFont = defaults.data(forKey: "defaultFont").flatMap { try? JSONDecoder().decode(EditorFont.self, from: $0) }
            ?? EditorFont(family: defaults.string(forKey: "sourceFontFamily") ?? "",
                          size: defaults.object(forKey: "sourceFontSize") as? Double ?? 16,
                          face: defaults.string(forKey: "sourceFontFace") ?? "")
        languageFonts = defaults.data(forKey: "languageFonts").flatMap { try? JSONDecoder().decode([String: EditorFont].self, from: $0) } ?? [:]
        codeFont = defaults.data(forKey: "codeFont").flatMap { try? JSONDecoder().decode(EditorFont.self, from: $0) }
            ?? EditorFont(family: NSFont.monospacedSystemFont(ofSize: 16, weight: .regular).familyName ?? "", size: 16)
        textColor = defaults.data(forKey: defaults.object(forKey: "textColor") == nil ? "sourceTextColor" : "textColor")
            .flatMap { try? JSONDecoder().decode(EditorColor.self, from: $0) }
        saveEncoded(defaultFont, forKey: "defaultFont")
        saveEncoded(textColor, forKey: "textColor")
        defaults.removeObject(forKey: "sourceTextColor")
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
        let codes = "ja en ja(easy) zh-hans zh-hant ko ar az be bg bn ca ceb de es et eu fa fr gu he hi hr hu hy id it jv ka kk km lt lv ml mr ms my ne nl pa pl ru si sk sl sr sw ta te th tl ur uz vi".split(separator: " ").map(String.init)
        let locale = Locale(identifier: "ja")
        return codes.map { code in
            Language(id: code, name: code == "zh-hans" ? "中国語（簡体字）" : code == "zh-hant" ? "中国語（繁体字）" : code == "ja(easy)" ? "やさしい日本語" : locale.localizedString(forLanguageCode: code) ?? code)
        }
    }()
}

struct PreferencesView: View {
    @ObservedObject var preferences: Preferences
    private static let fontFamilies = NSFontManager.shared.availableFontFamilies.sorted()
    @State private var fontLanguage = "ja"
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
            case .typography: "言語ごとのフォントと、共通の文字色を調整します。"
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
                    typographySettings
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
            SettingsCard(title: "翻訳") {
                SettingsRow("長文を自動分割", description: "生成上限に収まるよう段落や文で分割します。翻訳画面とローカルAPIに共通です。") {
                    Toggle("長文を自動分割", isOn: $preferences.autoSplit).labelsHidden()
                }
                Text("最大トークン数は分割した各部分に適用します。上限に達した部分は、さらに細かくして再翻訳します。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            SettingsCard(title: "メモリ管理") {
                SettingsRow("モデルの自動解放", description: "翻訳画面とローカルAPIに共通です。", hideControlLabels: false) {
                    ModelUnloadControl(preferences: preferences)
                }
                Text("翻訳完了からの時間を分単位で指定します。既定は5分、0分は完了後すぐに解放します。解放後は次の翻訳時に読み込み直します。")
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

    private var typographySettings: some View {
        SettingsPage {
            SettingsCard(title: "文字色") {
                SettingsRow("すべての言語に共通") {
                    ColorPicker("文字色", selection: Binding(
                        get: { Color(nsColor: preferences.editorColor) },
                        set: { preferences.textColor = EditorColor($0) }
                    ), supportsOpacity: false)
                    Button("リセット") { preferences.textColor = nil }.disabled(preferences.textColor == nil)
                }
            }
            fontSection("既定のフォント", font: $preferences.defaultFont)
            SettingsCard(title: "言語別のフォント") {
                SettingsRow("言語") {
                    Picker("言語", selection: $fontLanguage) {
                        ForEach(Language.all) { Text($0.name).tag($0.id) }
                    }.pickerStyle(.menu).frame(maxWidth: 280)
                }
                Toggle("この言語のフォントを指定", isOn: Binding(
                    get: { preferences.languageFonts[fontLanguage] != nil },
                    set: { preferences.languageFonts[fontLanguage] = $0 ? preferences.defaultFont : nil }
                ))
                Text("指定のない言語や、原文の言語を判定できない場合は既定のフォントを使います。原文・訳文に共通です。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if preferences.languageFonts[fontLanguage] != nil {
                fontSection(Language.all.first { $0.id == fontLanguage }?.name ?? fontLanguage, font: Binding(
                    get: { preferences.languageFonts[fontLanguage] ?? preferences.defaultFont },
                    set: { preferences.languageFonts[fontLanguage] = $0 }
                ))
            }
            fontSection("コード用フォント", font: $preferences.codeFont)
            Text("コード用フォントはMarkdownプレビューのコードブロックとインラインコードに適用します。")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func fontSection(_ title: String, font: Binding<EditorFont>) -> some View {
        let family = Binding(get: { font.wrappedValue.family }, set: {
            font.wrappedValue = EditorFont(family: $0, size: font.wrappedValue.size)
        })
        return SettingsCard(title: title) {
            SettingsRow("フォント") {
                Picker("フォント", selection: family) {
                    Text("システム").tag("")
                    ForEach(Self.fontFamilies, id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.menu).frame(maxWidth: 280)
            }
            Divider()
            SettingsRow("書体") {
                Picker("書体", selection: Binding(
                    get: { FontCatalog.selectedFace(family: family.wrappedValue, name: font.wrappedValue.face)?.id ?? "" },
                    set: { font.wrappedValue.face = $0 }
                )) {
                    ForEach(FontCatalog.faces(for: family.wrappedValue)) { Text($0.label).tag($0.id) }
                }
                .pickerStyle(.menu).frame(maxWidth: 280)
                .disabled(FontCatalog.faces(for: family.wrappedValue).count < 2)
            }
            Divider()
            SettingsRow("サイズ") {
                Stepper(value: font.size, in: 10...40, step: 1) {
                    Text("\(Int(font.wrappedValue.size)) pt").monospacedDigit().frame(width: 54)
                }.labelsHidden().accessibilityLabel("\(title)の文字サイズ")
                Text("\(Int(font.wrappedValue.size)) pt").monospacedDigit().frame(width: 54)
            }
            Text("あいうえお 漢字 ABC abc 123").font(Font(font.wrappedValue.native))
                .foregroundStyle(Color(nsColor: preferences.editorColor))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(18)
                .modifier(ReadingSurface(cornerRadius: 12))
                .accessibilityLabel("\(title)のフォントプレビュー")
        }
    }
}

/// Share the numeric idle timeout between app preferences and the API settings.
struct ModelUnloadControl: View {
    @ObservedObject var preferences: Preferences
    @State private var lastEnabledSeconds = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TextField("自動解放までの分数", value: Binding(
                    get: { (preferences.unloadSeconds >= 0 ? preferences.unloadSeconds : lastEnabledSeconds) / 60 },
                    set: { minutes in
                        guard minutes >= 0, minutes <= Int.max / 60 else { return }
                        preferences.unloadSeconds = minutes * 60
                    }
                ), format: .number.grouping(.never))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 72)
                .disabled(preferences.unloadSeconds < 0)
                .accessibilityLabel("翻訳完了から自動解放までの時間（分）")
                Text("分後")
            }
            Toggle("アプリ終了まで保持", isOn: Binding(
                get: { preferences.unloadSeconds < 0 },
                set: { preferences.unloadSeconds = $0 ? -1 : lastEnabledSeconds }
            ))
            .toggleStyle(.checkbox)
            .fixedSize()
        }
        .onChange(of: preferences.unloadSeconds, initial: true) { _, seconds in
            if seconds >= 0 { lastEnabledSeconds = seconds }
        }
    }
}
