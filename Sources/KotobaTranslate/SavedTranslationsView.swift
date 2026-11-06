import AppKit
import SwiftUI

struct SavedTranslationsView: View {
    @ObservedObject var store: SavedTranslationStore
    @ObservedObject var preferences: Preferences
    @State private var selection: UUID?
    @State private var search = ""
    @State private var renamedTitle = ""
    @State private var renaming: SavedTranslation?
    @State private var deleting: SavedTranslation?

    private var filtered: [SavedTranslation] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? store.entries : store.entries.filter {
            $0.title.localizedStandardContains(query) || $0.sourceText.localizedStandardContains(query)
                || $0.translatedText.localizedStandardContains(query)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(filtered) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.title).font(.headline).lineLimit(2)
                        Text(direction(entry)).font(.caption).foregroundStyle(.secondary)
                        Text(entry.savedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 5)
                    .tag(entry.id)
                    .contextMenu {
                        Button("タイトルを変更…") { beginRename(entry) }
                        Button("削除…", role: .destructive) { deleting = entry }
                    }
                }
            }
            .navigationTitle("保存した翻訳")
            .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
            .overlay {
                if store.working && !store.ready {
                    ProgressView()
                } else if !store.ready {
                    ContentUnavailableView {
                        Label("読み込めませんでした", systemImage: "exclamationmark.triangle")
                    } actions: { Button("再読み込み", action: store.reload) }
                } else if store.entries.isEmpty {
                    ContentUnavailableView("保存した翻訳はありません", systemImage: "bookmark",
                                           description: Text("翻訳後に「翻訳を保存」を押すと、原文と訳文を保存できます。"))
                } else if filtered.isEmpty {
                    ContentUnavailableView("一致する翻訳はありません", systemImage: "magnifyingglass",
                                           description: Text("別のキーワードで検索してください。"))
                }
            }
        } detail: {
            if let entry = store.entries.first(where: { $0.id == selection }) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(entry.title).font(.title2).textSelection(.enabled)
                    Text("\(direction(entry)) · 保存日時 \(entry.savedAt.formatted(date: .complete, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                    HSplitView {
                        textPane("原文", text: entry.sourceText, language: entry.sourceLanguage)
                        textPane("訳文", text: entry.translatedText, language: entry.targetLanguage)
                    }
                    HStack {
                        Spacer()
                        Button("タイトルを変更…") { beginRename(entry) }
                        Button("削除…", role: .destructive) { deleting = entry }
                    }.disabled(store.working)
                }.padding(20)
            } else {
                ContentUnavailableView("保存した翻訳を選択", systemImage: "bookmark",
                                       description: Text("一覧から選ぶと原文と訳文を表示します。"))
            }
        }
        .searchable(text: $search, prompt: "タイトル・原文・訳文を検索")
        .frame(minWidth: 820, minHeight: 520)
        .alert("タイトルを変更", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("タイトル", text: $renamedTitle)
            Button("キャンセル", role: .cancel) { renaming = nil }
            Button("変更") {
                if let entry = renaming { store.rename(entry.id, title: renamedTitle) }
                renaming = nil
            }.disabled(renamedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.working)
        }
        .alert("保存した翻訳を削除しますか？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("キャンセル", role: .cancel) { deleting = nil }
            Button("削除", role: .destructive) {
                if let entry = deleting { store.delete(entry.id) }
                deleting = nil
            }.disabled(store.working)
        } message: { Text("「\(deleting?.title ?? "")」の原文と訳文を削除します。この操作は取り消せません。") }
        .alert("保存した翻訳のエラー", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }

    private func direction(_ entry: SavedTranslation) -> String {
        let source = Language.all.first { $0.id == entry.sourceLanguage }?.name ?? "自動検出"
        let target = Language.all.first { $0.id == entry.targetLanguage }?.name ?? entry.targetLanguage
        return "\(source) → \(target)"
    }

    private func beginRename(_ entry: SavedTranslation) {
        renamedTitle = entry.title
        renaming = entry
    }

    private func textPane(_ title: String, text: String, language: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: { Label("\(title)をコピー", systemImage: "doc.on.doc") }
                .labelStyle(.iconOnly).help("\(title)をコピー")
            }
            InputEditor(text: .constant(text), editable: false, font: preferences.font(for: language),
                        textColor: preferences.editorColor, accessibilityName: "保存した\(title)")
        }
        .padding(12).frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity)
        .modifier(PanelSurface(cornerRadius: 12))
    }
}
