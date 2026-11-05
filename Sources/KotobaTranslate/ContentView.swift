import AppKit
import SwiftUI
import MarkdownUI

struct ContentView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var translator: Translator

    var body: some View {
        VStack(spacing: 16) {
            HSplitView {
                sourcePane
                outputPane
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }

            if translator.optionsExpanded { translationOptions }
            actionBar
        }
        .padding(20)
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 900, minHeight: 560)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                SettingsLink { Label("設定", systemImage: "gearshape") }
                    .labelStyle(.iconOnly).help("設定（⌘,）")
            }
        }
        .onChange(of: preferences.models) { _, models in
            if !models.contains(where: { $0.id == translator.modelID }) {
                translator.modelID = preferences.preferredModelID
            }
        }
        .alert("翻訳エラー", isPresented: Binding(get: { translator.error != nil }, set: { if !$0 { translator.error = nil } })) {
            Button("OK") { translator.error = nil }
        } message: { Text(translator.error ?? "") }
    }

    private var sourcePane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                languagePicker("原文", selection: $translator.source, automatic: true)
                Spacer(minLength: 0)
                Button {
                    let previous = translator.source
                    translator.source = translator.target
                    translator.target = previous
                } label: { toolIcon("言語を入れ替え", symbol: "arrow.left.arrow.right") }
                    .disabled(translator.source.isEmpty).help("言語を入れ替え")
                previewButton(isOn: $translator.sourcePreview)
                Button { translator.input = "" } label: { toolIcon("原文を消去", symbol: "xmark") }
                    .disabled(translator.input.isEmpty).help("原文を消去")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14).frame(height: 54)
            Divider()
            if translator.sourcePreview {
                markdownPreview(translator.input, font: preferences.sourceFont,
                                color: preferences.sourceColor)
            } else {
                InputEditor(text: $translator.input, font: preferences.sourceFont,
                            textColor: preferences.sourceColor, submit: translator.translate)
                    .accessibilityLabel("翻訳するテキスト")
            }
            HStack {
                Text("\(translator.inputStatistics.characters)文字 · 約\(translator.inputStatistics.estimatedTokens) tokens")
                    .help("原文のみの概算。文字種と長さから推定し、モデルは使用しません。Context・辞書・指示トークンは含みません。")
                Spacer(minLength: 0)
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            .padding(.horizontal, 18).frame(height: 34)
        }.frame(minWidth: 340)
    }

    private var outputPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                languagePicker("訳文", selection: $translator.target, automatic: false)
                Spacer(minLength: 0)
                if translator.target == "ja" {
                    Picker("文体", selection: $translator.form) {
                        Text("文体").tag("")
                        Text("常体").tag("plain")
                        Text("敬体").tag("polite")
                    }.labelsHidden().fixedSize().help("文体")
                }
                previewButton(isOn: $translator.outputPreview)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(translator.output, forType: .string)
                } label: { toolIcon("訳文をコピー", symbol: "doc.on.doc") }
                    .disabled(translator.output.isEmpty).help("訳文をコピー")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14).frame(height: 54)
            Divider()
            if translator.outputPreview {
                markdownPreview(translator.output, font: preferences.outputFont,
                                color: preferences.outputColor)
            } else {
                InputEditor(text: .constant(translator.output), editable: false, font: preferences.outputFont,
                            textColor: preferences.outputColor)
                    .accessibilityLabel("翻訳結果")
            }
            HStack {
                if let metrics = translator.metrics { metricsView(metrics) }
                Spacer(minLength: 0)
            }.padding(.horizontal, 18).frame(height: 34)
        }.frame(minWidth: 340)
    }

    private var translationOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                if preferences.models.isEmpty {
                    Button("モデルを追加…", systemImage: "plus", action: preferences.addModel)
                } else {
                    Picker("モデル", selection: $translator.modelID) {
                        Text("モデルを選択").tag(nil as UUID?)
                        ForEach(preferences.models) { model in
                            Text(model.tag).tag(Optional(model.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 440)
                }
                Spacer(minLength: 0)
                if translator.busy || translator.loaded {
                    Circle().fill(.green).frame(width: 7, height: 7)
                    Text(translator.loaded ? "読み込み済み" : "読み込み中")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if translator.loaded {
                    Button("解放", systemImage: "eject", action: translator.unload)
                        .disabled(translator.busy).help("モデルを解放")
                }
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("コンテキスト").font(.subheadline).foregroundStyle(.secondary)
                    TextEditor(text: $translator.context)
                        .font(.body).scrollContentBackground(.hidden)
                        .padding(6).frame(height: 76)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, lineWidth: 0.5) }
                        .accessibilityLabel("コンテキスト")
                }.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("辞書（\(preferences.glossary.filter { !$0.source.isEmpty && !$0.target.isEmpty }.count)語）", isOn: $translator.useGlossary)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            Text("Max tokens")
                            TextField("Max tokens", value: $translator.maxTokens, format: .number.grouping(.never))
                        }
                        GridRow {
                            Text("Temperature")
                            TextField("Temperature", value: $translator.temperature, format: .number)
                        }
                    }.textFieldStyle(.roundedBorder)
                }.frame(width: 240)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $translator.optionsExpanded) {
                Label("オプション", systemImage: "slider.horizontal.3")
            }
            .toggleStyle(.button)
            .keyboardShortcut("o", modifiers: [.command, .option])
            .help("翻訳オプション（⌥⌘O）")
            Spacer(minLength: 12)
            if translator.busy {
                if let progress = translator.progress {
                    ProgressView(value: progress).frame(width: 64)
                } else { ProgressView().controlSize(.small) }
            }
            Text(translator.status).font(.subheadline).foregroundStyle(.secondary)
                .lineLimit(1)
            if translator.busy {
                Button("中止", action: translator.cancel).keyboardShortcut(.cancelAction)
            }
            Button("翻訳", systemImage: "arrow.up", action: translator.translate)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!translator.canTranslate)
        }.controlSize(.large)
    }

    private func toolIcon(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .labelStyle(.iconOnly)
            .frame(width: 28, height: 28)
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }

    private func previewButton(isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            toolIcon("Markdownプレビュー", symbol: isOn.wrappedValue ? "text.alignleft" : "eye")
        }
        .toggleStyle(.button).buttonStyle(.borderless)
        .help(isOn.wrappedValue ? "生テキストを表示" : "Markdownをプレビュー")
    }

    private func markdownPreview(_ text: String, font: NSFont, color: NSColor) -> some View {
        MarkdownPreview(text: text, fontName: font.fontName, fontSize: font.pointSize,
                        color: Color(nsColor: color))
            .equatable()
    }

    private func languagePicker(_ label: String, selection: Binding<String>, automatic: Bool) -> some View {
        Picker(label, selection: selection) {
            if automatic { Text("自動検出").tag("") }
            ForEach(Language.all) { language in Text(language.name).tag(language.id) }
        }
        .labelsHidden().pickerStyle(.menu)
        .frame(maxWidth: 200, alignment: .leading)
        .help(label + "の言語")
    }

    private func metricsView(_ metrics: WorkerEvent) -> some View {
        HStack(spacing: 12) {
            if let elapsed = metrics.elapsed { Text(String(format: "%.2f秒", elapsed)) }
            if let tokens = metrics.tokens { Text("\(tokens) tokens") }
            if let tps = metrics.tps { Text(String(format: "%.1f token/s", tps)) }
        }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            .help("時間はモデル読み込み・入力処理を含む。token/sは生成速度。入力: \(metrics.prompt_tokens ?? 0) tokens、入力処理: \(String(format: "%.1f", metrics.prompt_tps ?? 0)) token/s、読み込み: \(String(format: "%.2f", metrics.load_seconds ?? 0))秒")
    }
}

/// Keep unrelated status and statistics updates from reparsing unchanged Markdown.
private struct MarkdownPreview: View, Equatable {
    let text: String
    let fontName: String
    let fontSize: CGFloat
    let color: Color

    var body: some View {
        ScrollView {
            Markdown(text)
                .markdownTextStyle {
                    FontFamily(.custom(fontName))
                    FontSize(fontSize)
                    ForegroundColor(color)
                }
                .markdownTextStyle(\.link) { ForegroundColor(.accentColor) }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
