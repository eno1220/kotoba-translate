import AppKit
import SwiftUI
import MarkdownUI

struct ContentView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var translator: Translator

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Picker("モデル", selection: $translator.modelID) {
                    Text("モデルを選択").tag(nil as UUID?)
                    ForEach(preferences.models) { model in
                        Text(model.tag).tag(Optional(model.id))
                    }
                }.frame(maxWidth: 340)
                Spacer()
                if translator.busy || translator.loaded {
                    HStack(spacing: 6) {
                        Circle().fill(.green).frame(width: 8, height: 8)
                        Text(translator.loaded ? "読み込み済み" : "読み込み中")
                    }.font(.caption)
                }
                if translator.loaded {
                    Button("解放", action: translator.unload).disabled(translator.busy)
                }
                SettingsLink { Image(systemName: "gearshape") }.help("設定")
            }.padding(16)
            Divider()
            HStack(spacing: 12) {
                languagePicker("原文", selection: $translator.source, automatic: true)
                Button {
                    guard !translator.source.isEmpty else { return }
                    let previousSource = translator.source
                    translator.source = translator.target
                    translator.target = previousSource
                } label: { Image(systemName: "arrow.left.arrow.right") }
                    .buttonStyle(.borderless).help("言語を入れ替え")
                    .disabled(translator.source.isEmpty)
                languagePicker("訳文", selection: $translator.target, automatic: false)
                Spacer()
                if translator.target == "ja" {
                    Picker("文体", selection: $translator.form) {
                        Text("指定なし").tag("")
                        Text("常体").tag("plain")
                        Text("敬体").tag("polite")
                    }.frame(width: 170)
                }
            }.padding(16)
            HSplitView {
                VStack(spacing: 0) {
                    HStack {
                        Text("原文").foregroundStyle(.secondary)
                        Spacer()
                        previewButton(isOn: $translator.sourcePreview)
                        Button { translator.input = "" } label: { Image(systemName: "xmark") }
                            .help("原文を消去").disabled(translator.input.isEmpty)
                    }.buttonStyle(.borderless).padding(.horizontal, 16).padding(.vertical, 10)
                    if translator.sourcePreview {
                        markdownPreview(translator.input, font: preferences.sourceFont)
                    } else {
                        InputEditor(text: $translator.input, font: preferences.sourceFont, submit: translator.translate)
                            .accessibilityLabel("翻訳するテキスト")
                    }
                    HStack {
                        Text("\(translator.inputStatistics.characters)文字 · 約\(translator.inputStatistics.estimatedTokens) tokens")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .help("原文のみの概算。モデルを使わず文字種と長さから推定します。Context・辞書・指示トークンは含みません。実際のトークン数とは異なります。")
                        Spacer()
                    }.padding(.horizontal, 16).padding(.vertical, 8)
                }.frame(minWidth: 280)
                VStack(spacing: 0) {
                    HStack {
                        Text("訳文").foregroundStyle(.secondary)
                        Spacer()
                        previewButton(isOn: $translator.outputPreview)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(translator.output, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                            .help("訳文をコピー").disabled(translator.output.isEmpty)
                    }.buttonStyle(.borderless).padding(.horizontal, 16).padding(.vertical, 10)
                    if translator.outputPreview {
                        markdownPreview(translator.output, font: preferences.outputFont)
                    } else {
                        InputEditor(text: .constant(translator.output), editable: false, font: preferences.outputFont)
                            .accessibilityLabel("翻訳結果")
                    }
                }.frame(minWidth: 280)
            }.background(.background)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    translator.optionsExpanded.toggle()
                } label: {
                    HStack {
                        Label("翻訳オプション", systemImage: "slider.horizontal.3")
                        Spacer()
                        Image(systemName: translator.optionsExpanded ? "chevron.up" : "chevron.down")
                    }.padding(.horizontal, 12).padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .keyboardShortcut("o", modifiers: [.command, .option])
                .help("翻訳オプションを開閉（⌥⌘O）")
                .accessibilityValue(translator.optionsExpanded ? "展開中" : "折りたたみ中")
                if translator.optionsExpanded {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top) {
                            Text("Context").frame(width: 72, alignment: .leading).padding(.top, 5)
                            TextEditor(text: $translator.context).font(.body)
                                .frame(height: 72).border(.quaternary)
                        }
                        HStack(spacing: 16) {
                            Toggle("辞書", isOn: $translator.useGlossary)
                            Text("\(preferences.glossary.filter { !$0.source.isEmpty && !$0.target.isEmpty }.count)語")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("Max tokens")
                            TextField("Max tokens", value: $translator.maxTokens, format: .number.grouping(.never))
                                .frame(width: 80)
                            Text("Temperature")
                            TextField("Temperature", value: $translator.temperature, format: .number)
                                .frame(width: 60)
                        }.textFieldStyle(.roundedBorder)
                    }.padding(.top, 8)
                }
                HStack(spacing: 12) {
                    if translator.busy {
                        if let progress = translator.progress {
                            ProgressView(value: progress).tint(.green).frame(width: 80)
                        } else { ProgressView().controlSize(.small).tint(.green) }
                    }
                    Text(translator.status).font(.caption).foregroundStyle(.secondary)
                    if let metrics = translator.metrics {
                        metricsView(metrics)
                    }
                    Spacer(minLength: 8)
                    if translator.busy {
                        Button("中止", action: translator.cancel).keyboardShortcut(.cancelAction)
                    }
                    Button("翻訳", action: translator.translate)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!translator.canTranslate)
                }
            }.padding(16)
            if preferences.models.isEmpty {
                HStack {
                    Text("MLXモデルのディレクトリを追加")
                    Button("モデルを追加…", action: preferences.addModel)
                }.padding(.bottom, 16)
            }
        }
        .frame(minWidth: 860, minHeight: 540)
        .onChange(of: preferences.models) { _, models in
            if !models.contains(where: { $0.id == translator.modelID }) {
                translator.modelID = models.first?.id
            }
        }
        .alert("翻訳エラー", isPresented: Binding(get: { translator.error != nil }, set: { if !$0 { translator.error = nil } })) {
            Button("OK") { translator.error = nil }
        } message: { Text(translator.error ?? "") }
    }

    private func previewButton(isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Label(isOn.wrappedValue ? "テキスト" : "プレビュー",
                  systemImage: isOn.wrappedValue ? "text.alignleft" : "eye")
        }.help(isOn.wrappedValue ? "生テキストを表示" : "Markdownをプレビュー")
    }

    private func markdownPreview(_ text: String, font: NSFont) -> some View {
        ScrollView {
            Markdown(text)
                .markdownTextStyle {
                    FontFamily(.custom(font.fontName))
                    FontSize(font.pointSize)
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func languagePicker(_ label: String, selection: Binding<String>, automatic: Bool) -> some View {
        Picker(label, selection: selection) {
            if automatic { Text("自動検出").tag("") }
            ForEach(Language.all) { language in Text(language.name).tag(language.id) }
        }.frame(width: 215)
    }

    private func metricsView(_ metrics: WorkerEvent) -> some View {
        HStack(spacing: 10) {
            if let elapsed = metrics.elapsed { Text(String(format: "%.2f秒", elapsed)) }
            if let tokens = metrics.tokens { Text("\(tokens) tokens") }
            if let tps = metrics.tps { Text(String(format: "%.1f token/s", tps)) }
        }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            .help("時間はモデル読み込み・入力処理を含む。token/sは生成速度。入力: \(metrics.prompt_tokens ?? 0) tokens、入力処理: \(String(format: "%.1f", metrics.prompt_tps ?? 0)) token/s、読み込み: \(String(format: "%.2f", metrics.load_seconds ?? 0))秒")
    }
}
