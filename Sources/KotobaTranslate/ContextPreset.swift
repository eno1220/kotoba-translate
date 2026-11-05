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

    var body: some View {
        Form {
            Section("自分のプリセット") {
                ForEach($preferences.customPresets) { $preset in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("絵文字", text: $preset.emoji)
                                .frame(width: 56).help("絵文字（⌃⌘スペース）")
                                .onChange(of: preset.emoji) { _, value in
                                    let emoji = value.filter { character in
                                        character.unicodeScalars.contains { ($0.properties.isEmoji && $0.value > 0x7F) || $0.value == 0xFE0F || $0.value == 0x20E3 }
                                    }
                                    if value != String(emoji.prefix(1)) { preset.emoji = String(emoji.prefix(1)) }
                                }
                            TextField("名前", text: $preset.name)
                            Button(role: .destructive) { preferences.removePreset(preset.id) } label: {
                                Image(systemName: "minus.circle")
                            }.help("プリセットを削除")
                        }
                        TextEditor(text: $preset.contextDescription).font(.body).frame(minHeight: 80)
                            .accessibilityLabel("プリセットの場面・背景")
                    }
                }
                Button("プリセットを追加", systemImage: "plus") { preferences.customPresets.append(ContextPreset()) }
                Text("原文の前後の文章や場面・背景を記入します。絵文字・名前・説明を保存します。翻訳画面で入力したコンテキストは保存しません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("アプリ別の自動適用") {
                ForEach($preferences.appPresetRules) { $rule in
                    HStack {
                        Text(rule.name).help(rule.id).frame(maxWidth: .infinity, alignment: .leading)
                        Picker("プリセット", selection: $rule.presetID) {
                            Text("自動適用しない").tag(nil as String?)
                            ForEach(preferences.contextPresets) { Text($0.label).tag(Optional($0.id)) }
                        }.labelsHidden().frame(width: 210)
                        Button { preferences.appPresetRules.removeAll { $0.id == rule.id } } label: {
                            Image(systemName: "minus.circle")
                        }.help("アプリの設定を削除")
                    }
                }
                Button("アプリを追加…", systemImage: "plus", action: preferences.addPresetApp)
                Text("サービス（キーボードショートカットを含む）から受け取る際に、取得できた呼び出し元アプリに適用します。未登録・取得できない場合や「自動適用しない」は、現在の選択を維持します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
