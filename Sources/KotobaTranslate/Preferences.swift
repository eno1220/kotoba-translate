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

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, presets, typography, glossary, server, request
    var id: Self { self }
    var title: String {
        switch self {
        case .general: "一般"
        case .presets: "プリセット"
        case .typography: "文字"
        case .glossary: "辞書"
        case .server: "ローカルAPI"
        case .request: "API接続設定"
        }
    }
    var symbol: String {
        switch self {
        case .general: "cpu"
        case .presets: "text.bubble"
        case .typography: "textformat"
        case .glossary: "character.book.closed"
        case .server: "network"
        case .request: "curlybraces"
        }
    }
    var description: String {
        switch self {
        case .general: "モデルと実行環境を管理します。"
        case .presets: "指示設定のプリセットを管理します。"
        case .typography: "表示するフォントと文字色を管理します。"
        case .glossary: "翻訳時に使用する辞書を管理します。"
        case .server: "翻訳用のローカルAPIサーバを管理します。"
        case .request: "ローカルAPIサーバへの接続を試します。"
        }
    }
}

struct PreferencesView: View {
    @ObservedObject var preferences: Preferences
    private static let fontFamilies = NSFontManager.shared.availableFontFamilies.sorted()
    @State private var fontLanguage = "ja"
    @ObservedObject var server: LocalAPIServer
    @ObservedObject var translator: Translator
    @Binding var selection: SettingsSection?

    var body: some View {
        HSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                SettingsNavigationLabel(title: section.title, symbol: section.symbol).tag(section)
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal").font(.system(size: 10))
                        .accessibilityHidden(true)
                    Text("変更は自動的に保存されます").font(.system(size: 11))
                }
                .foregroundStyle(.secondary).padding(18)
            }
            .frame(minWidth: 200, idealWidth: 220, maxWidth: 260, maxHeight: .infinity)
            ZStack {
                // Keep the request draft in memory while navigating settings.
                RequestBuilderView(server: server, active: selection == .request)
                    .opacity(selection == .request ? 1 : 0)
                    .allowsHitTesting(selection == .request)
                    .accessibilityHidden(selection != .request)
                    .disabled(selection != .request)
                let section = selection ?? .general
                switch section {
                case .general:
                    generalSettings
                case .presets:
                    PresetSettingsView(preferences: preferences,
                                       title: section.title,
                                       description: section.description)
                case .typography:
                    typographySettings
                case .glossary:
                    glossarySettings
                case .server:
                    ServerSettingsView(server: server, preferences: preferences, translator: translator)
                case .request:
                    Color.clear.allowsHitTesting(false)
                }
            }
            .background { ScreenBackground() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 940, idealWidth: 1040, minHeight: 700, idealHeight: 820)
        .background(MinimalWindowTitlebar())
        .preferredColorScheme(.light)
    }

    private func page<Content: View>(_ section: SettingsSection,
                                     @ViewBuilder content: () -> Content) -> some View {
        SettingsPage(title: section.title, description: section.description, content: content)
    }

    private var generalSettings: some View {
        page(.general) {
            SettingsCard(title: "モデル", symbol: "square.stack.3d.up") {
                HStack(spacing: 14) {
                    SettingsIcon(symbol: "cpu", size: 40)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("PLaMo 3 Translate").font(.system(size: 15, weight: .semibold))
                        Text("ダウンロード済みのMLXモデルを登録します。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("モデルを追加…", systemImage: "plus", action: preferences.addModel)
                        .buttonStyle(.borderedProminent)
                }
                if !preferences.models.isEmpty {
                    Divider()
                    SettingsRow("デフォルト") {
                        SelectField(title: "デフォルト", selection: $preferences.defaultModelID,
                                    options: [SelectOption<UUID?>(value: nil, label: "先頭のモデル")]
                                        + preferences.models.map { SelectOption(value: Optional($0.id), label: $0.tag) },
                                    width: 260)
                    }
                }
                SettingsFootnote(text: "翻訳を開始するまでモデルは読み込まれません。", symbol: "info.circle")
            }
            if !preferences.models.isEmpty {
                SettingsCard(title: "登録済みのモデル（\(preferences.models.count)）", symbol: "shippingbox") {
                    ForEach($preferences.models) { $model in
                        VStack(alignment: .leading, spacing: 10) {
                            SettingsRow("タグ") {
                                TextField("タグ", text: $model.tag)
                                    .help("翻訳画面に表示する名前。APIで指定する場合は一意のタグを使用します。")
                                Button(role: .destructive) {
                                    if preferences.defaultModelID == model.id { preferences.defaultModelID = nil }
                                    preferences.models.removeAll { $0.id == model.id }
                                } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("モデル「\(model.tag)」を一覧から削除")
                                .help("登録のみ削除し、モデルのファイルは削除しません。")
                            }
                            Divider()
                            SettingsRow("フォルダ") {
                                TextField("フォルダ", text: $model.path)
                                    .font(.system(.callout, design: .monospaced)).help(model.path)
                            }
                            if model.tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                SettingsFootnote(text: "タグを入力してください。", symbol: "exclamationmark.circle")
                            } else if preferences.models.filter({ $0.tag == model.tag }).count > 1 {
                                SettingsFootnote(text: "APIでタグを指定するには、一意のタグを設定してください。", symbol: "exclamationmark.circle")
                            }
                        }
                        if model.id != preferences.models.last?.id {
                            Divider().padding(.vertical, 2)
                        }
                    }
                }
            }
            SettingsCard(title: "翻訳", symbol: "text.bubble") {
                SettingsRow("長文を自動分割", description: "生成するコンテキスト長の上限に収まるよう、段落や文を分割します。") {
                    Toggle("長文を自動分割", isOn: $preferences.autoSplit).labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            SettingsCard(title: "メモリ管理", symbol: "memorychip") {
                SettingsRow("モデルの自動解放",  hideControlLabels: false) {
                    ModelUnloadControl(preferences: preferences)
                }
                SettingsFootnote(text: "翻訳完了からの時間を分単位で指定します。0分を指定すると翻訳完了後即座に解放します。モデルは次回翻訳を開始する際に再度読み込まれます。", symbol: "clock.arrow.circlepath")
            }
            SettingsCard(title: "実行環境", symbol: "terminal") {
                SettingsRow("Python") {
                    TextField("Python", text: $preferences.python)
                        .font(.system(.callout, design: .monospaced)).help(preferences.python)
                }
            }
        }
    }

    private var glossarySettings: some View {
        page(.glossary) {
            HStack {
                Text("\(preferences.glossary.count)語")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button("用語を追加", systemImage: "plus") { preferences.glossary.append(GlossaryTerm()) }
                    .buttonStyle(.borderedProminent)
            }
            if preferences.glossary.isEmpty {
                SettingsCard(title: "") {
                    ContentUnavailableView {
                        Label("用語が登録されていません", systemImage: "character.book.closed")
                    } description: {
                        Text("「用語を追加」から、原語と訳語を登録できます。")
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 30)
                }
            } else {
                SettingsCard(title: "用語", symbol: "character.book.closed") {
                    ForEach($preferences.glossary) { $term in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("原語").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                                TextField("原語", text: $term.source)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "arrow.right").font(.system(size: 11))
                                .foregroundStyle(.tertiary).accessibilityHidden(true)
                                .padding(.top, 22)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("訳語").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                                TextField("訳語", text: $term.target)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Button(role: .destructive) { preferences.glossary.removeAll { $0.id == term.id } } label: {
                                Image(systemName: "trash")
                            }.buttonStyle(.borderless)
                                .padding(.top, 18)
                                .help("用語を削除").accessibilityLabel("用語「\(term.source)」を削除")
                        }
                        if term.id != preferences.glossary.last?.id { Divider() }
                    }
                }
            }
            if preferences.glossary.contains(where: { $0.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                SettingsFootnote(text: "原語と訳語を両方入力してください。不要な行は削除できます。", symbol: "exclamationmark.circle")
            }
        }
    }

    private var typographySettings: some View {
        page(.typography) {
            SettingsCard(title: "文字色", symbol: "paintpalette") {
                SettingsRow("すべての言語に共通") {
                    ColorPicker("文字色", selection: Binding(
                        get: { Color(nsColor: preferences.editorColor) },
                        set: { preferences.textColor = EditorColor($0) }
                    ), supportsOpacity: false)
                    Button("リセット") { preferences.textColor = nil }.disabled(preferences.textColor == nil)
                }
            }
            fontSection("既定のフォント", symbol: "textformat", font: $preferences.defaultFont)
            SettingsCard(title: "言語別のフォント", symbol: "globe") {
                SettingsRow("言語") {
                    SelectField(title: "言語", selection: $fontLanguage,
                                options: Language.all.map { SelectOption(value: $0.id, label: $0.name) },
                                width: 280)
                }
                Toggle("この言語のフォントを指定", isOn: Binding(
                    get: { preferences.languageFonts[fontLanguage] != nil },
                    set: { preferences.languageFonts[fontLanguage] = $0 ? preferences.defaultFont : nil }
                ))
                SettingsFootnote(text: "指定のない言語や、原文の言語を判定できない場合は既定のフォントを使用します", symbol: "info.circle")
            }
            if preferences.languageFonts[fontLanguage] != nil {
                fontSection(Language.all.first { $0.id == fontLanguage }?.name ?? fontLanguage, symbol: "character", font: Binding(
                    get: { preferences.languageFonts[fontLanguage] ?? preferences.defaultFont },
                    set: { preferences.languageFonts[fontLanguage] = $0 }
                ))
            }
            fontSection("コード用フォント", symbol: "chevron.left.forwardslash.chevron.right", font: $preferences.codeFont)
            SettingsFootnote(text: "Markdownプレビューのコードブロックとインラインコードに適用します。", symbol: "doc.richtext")
        }
    }

    private func fontSection(_ title: String, symbol: String? = nil, font: Binding<EditorFont>) -> some View {
        let family = Binding(get: { font.wrappedValue.family }, set: {
            font.wrappedValue = EditorFont(family: $0, size: font.wrappedValue.size)
        })
        return SettingsCard(title: title, symbol: symbol) {
            SettingsRow("フォント") {
                SelectField(title: "フォント", selection: family,
                            options: [SelectOption(value: "", label: "システム")]
                                + Self.fontFamilies.map { SelectOption(value: $0, label: $0) },
                            width: 280)
            }
            Divider()
            SettingsRow("書体") {
                SelectField(title: "書体", selection: Binding(
                    get: { FontCatalog.selectedFace(family: family.wrappedValue, name: font.wrappedValue.face)?.id ?? "" },
                    set: { font.wrappedValue.face = $0 }
                ), options: FontCatalog.faces(for: family.wrappedValue)
                    .map { SelectOption(value: $0.id, label: $0.label) },
                   width: 280)
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
                .modifier(ReadingSurface(cornerRadius: 12, fill: KotobaTheme.well))
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
                Text("分後").font(.system(size: 13))
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
