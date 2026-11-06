import AppKit
import SwiftUI

struct ContextPreset: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var emoji = "✨"
    var name = "マイプリセット"
    var contextDescription = ""
    var label: String { "\(emoji.isEmpty ? "✨" : emoji) \(name)" }

    // Keep the stored key so existing custom presets retain their content.
    private enum CodingKeys: String, CodingKey {
        case id, emoji, name
        case contextDescription = "instruction"
    }

    static let builtIn: [ContextPreset] = [
        .init(id: "casual", emoji: "💬", name: "日常・カジュアル", contextDescription: "友人や家族など、親しい相手との日常会話やチャットです。身近な出来事や気持ちについて、気兼ねなく話している場面です。"),
        .init(id: "formal", emoji: "🎩", name: "日常・フォーマル", contextDescription: "初対面の人や、まだ親しくない相手との日常的なやり取りです。案内・問い合わせ・お願いなど、相手と適度な距離を保って話す場面です。"),
        .init(id: "academic", emoji: "🎓", name: "論文", contextDescription: "研究者や学生が読む学術論文・研究資料の文章です。研究の背景・方法・結果・考察などを、専門分野の知識を共有する読者に説明する場面です。"),
        .init(id: "technical", emoji: "🛠️", name: "技術文書", contextDescription: "ソフトウェアや機器の仕様書・開発ドキュメント・操作マニュアルの文章です。開発者や利用者に、仕組み・設定・操作手順・制約などを説明する場面です。"),
        .init(id: "work", emoji: "💼", name: "仕事", contextDescription: "職場でのメールや業務チャットのやり取りです。同僚・上司・取引先に、仕事の状況を共有したり、確認・依頼・日程調整をしたりする場面です。"),
        .init(id: "social", emoji: "📱", name: "SNS", contextDescription: "SNSの投稿やコメント、返信として書かれた文章です。フォロワーや同じ話題に関心のある人に、出来事・感想・意見を共有する場面です。")
    ]
}

struct AppPresetRule: Identifiable, Codable {
    var id: String // Bundle identifier
    var name: String
    var presetID: String?
}

struct PresetSettingsView: View {
    @ObservedObject var preferences: Preferences
    var title = "プリセット"
    var description = "よく使う場面や背景を、翻訳に適用できます。"

    var body: some View {
        SettingsPage(title: title, description: description) {
            SettingsCard(title: "自分のプリセット", symbol: "face.smiling") {
                if preferences.customPresets.isEmpty {
                    Label("独自の場面や背景を登録できます", systemImage: "face.smiling")
                        .foregroundStyle(.secondary)
                }
                ForEach(preferences.customPresets) { preset in
                    let binding = presetBinding(preset)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("絵文字").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                                // Avoid rewriting marked text while an input method is composing.
                                TextField("絵文字", text: binding.emoji).labelsHidden()
                                    .help("絵文字（⌃⌘スペース）。空欄の場合は✨を表示します。")
                            }.frame(width: 80)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("名前").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                                TextField("名前", text: binding.name).labelsHidden()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Button(role: .destructive) { preferences.removePreset(preset.id) } label: {
                                Image(systemName: "minus.circle")
                            }.buttonStyle(.borderless).help("プリセットを削除")
                                .padding(.top, 18)
                                .accessibilityLabel("プリセット「\(preset.name)」を削除")
                        }
                        Text("場面・背景").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        TextEditor(text: binding.contextDescription).font(.body)
                            .scrollContentBackground(.hidden).padding(8).frame(height: 100)
                            .modifier(ReadingSurface(cornerRadius: 10, fill: KotobaTheme.well))
                            .accessibilityLabel("プリセット「\(preset.name)」の場面・背景")
                    }
                    Divider()
                }
                Button("プリセットを追加", systemImage: "plus") { preferences.customPresets.append(ContextPreset()) }
                SettingsFootnote(text: "原文の前後の文章や場面・背景を記入します。絵文字・名前・説明を保存します。翻訳画面で入力したコンテキストは保存しません。", symbol: "info.circle")
            }
            SettingsCard(title: "アプリ別の自動適用", symbol: "app.badge") {
                if preferences.appPresetRules.isEmpty {
                    Label("自動適用するアプリが登録されていません", systemImage: "app.badge")
                        .foregroundStyle(.secondary)
                }
                ForEach(preferences.appPresetRules) { rule in
                    let binding = ruleBinding(rule)
                    HStack {
                        Text(rule.name).help(rule.id).frame(maxWidth: .infinity, alignment: .leading)
                        SelectField(title: "\(rule.name)のプリセット", selection: binding.presetID,
                                    options: [SelectOption<String?>(value: nil, label: "自動適用しない")]
                                        + preferences.contextPresets.map { SelectOption(value: Optional($0.id), label: $0.label) },
                                    width: 210)
                            .accessibilityLabel("\(rule.name)のプリセット")
                        Button(role: .destructive) { preferences.appPresetRules.removeAll { $0.id == rule.id } } label: {
                            Image(systemName: "minus.circle")
                        }.buttonStyle(.borderless).help("アプリの設定を削除")
                            .accessibilityLabel("\(rule.name)の自動適用設定を削除")
                    }
                    Divider()
                }
                Button("アプリを追加…", systemImage: "plus", action: preferences.addPresetApp)
                SettingsFootnote(text: "サービス（キーボードショートカットを含む）から受け取る際に、取得できた呼び出し元アプリに適用します。未登録・取得できない場合や「自動適用しない」は、現在の選択を維持します。", symbol: "info.circle")
            }
        }
    }

    // SwiftUI can still read or commit an editor's binding while its row is being
    // removed. Resolve by ID each time, and ignore commits for deleted rows.
    private func presetBinding(_ preset: ContextPreset) -> Binding<ContextPreset> {
        Binding(
            get: { preferences.customPresets.first { $0.id == preset.id } ?? preset },
            set: { value in
                guard let index = preferences.customPresets.firstIndex(where: { $0.id == preset.id }) else { return }
                preferences.customPresets[index] = value
            }
        )
    }

    private func ruleBinding(_ rule: AppPresetRule) -> Binding<AppPresetRule> {
        Binding(
            get: { preferences.appPresetRules.first { $0.id == rule.id } ?? rule },
            set: { value in
                guard let index = preferences.appPresetRules.firstIndex(where: { $0.id == rule.id }) else { return }
                preferences.appPresetRules[index] = value
            }
        )
    }
}
