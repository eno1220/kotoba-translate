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

@MainActor
final class Preferences: ObservableObject {
    @Published var models: [ModelLocation] { didSet { save() } }
    @Published var glossary: [GlossaryTerm] { didSet { save() } }
    @Published var python: String { didSet { save() } }
    @Published var unloadSeconds: Int { didSet { save() } }
    @Published var sourceFontFamily: String { didSet { save() } }
    @Published var sourceFontSize: Double { didSet { save() } }
    @Published var outputFontFamily: String { didSet { save() } }
    @Published var outputFontSize: Double { didSet { save() } }

    var sourceFont: NSFont { editorFont(family: sourceFontFamily, size: sourceFontSize) }
    var outputFont: NSFont { editorFont(family: outputFontFamily, size: outputFontSize) }

    private func editorFont(family: String, size: Double) -> NSFont {
        let size = min(40, max(10, size))
        return NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
            ?? .systemFont(ofSize: size)
    }

    init() {
        let defaults = UserDefaults.standard
        models = defaults.data(forKey: "models").flatMap { try? JSONDecoder().decode([ModelLocation].self, from: $0) } ?? []
        glossary = defaults.data(forKey: "glossary").flatMap { try? JSONDecoder().decode([GlossaryTerm].self, from: $0) } ?? []
        let resource = Bundle.main.url(forResource: "python-path", withExtension: "txt")
        let bundledPath = resource.flatMap { try? String(contentsOf: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
        python = defaults.string(forKey: "python") ?? bundledPath ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".venv/bin/python").path
        unloadSeconds = defaults.object(forKey: "unloadSeconds") as? Int ?? 300
        sourceFontFamily = defaults.string(forKey: "sourceFontFamily") ?? ""
        sourceFontSize = defaults.object(forKey: "sourceFontSize") as? Double ?? 16
        outputFontFamily = defaults.string(forKey: "outputFontFamily") ?? ""
        outputFontSize = defaults.object(forKey: "outputFontSize") as? Double ?? 16
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(try? JSONEncoder().encode(models), forKey: "models")
        defaults.set(try? JSONEncoder().encode(glossary), forKey: "glossary")
        defaults.set(python, forKey: "python")
        defaults.set(unloadSeconds, forKey: "unloadSeconds")
        defaults.set(sourceFontFamily, forKey: "sourceFontFamily")
        defaults.set(sourceFontSize, forKey: "sourceFontSize")
        defaults.set(outputFontFamily, forKey: "outputFontFamily")
        defaults.set(outputFontSize, forKey: "outputFontSize")
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
                    ForEach($preferences.models) { $model in
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                TextField("タグ", text: $model.tag)
                                TextField("ディレクトリ", text: $model.path).font(.caption)
                            }
                            Button(role: .destructive) { preferences.models.removeAll { $0.id == model.id } } label: {
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
                            font: preferences.sourceFont)
                fontSection("訳文", family: $preferences.outputFontFamily, size: $preferences.outputFontSize,
                            font: preferences.outputFont)
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

    private func fontSection(_ title: String, family: Binding<String>, size: Binding<Double>, font: NSFont) -> some View {
        Section(title) {
            Picker("フォント", selection: family) {
                Text("システム").tag("")
                ForEach(Self.fontFamilies, id: \.self) { Text($0).tag($0) }
            }
            Stepper(value: size, in: 10...40, step: 1) {
                Text("サイズ  \(Int(size.wrappedValue)) pt")
            }
            Text("あいうえお 漢字 ABC abc 123").font(Font(font))
        }
    }
}
