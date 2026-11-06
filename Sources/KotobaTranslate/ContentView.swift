import AppKit
import SwiftUI
import MarkdownUI

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var articlePopoverPresented = false
    @FocusState private var articleURLFocused: Bool
    @ObservedObject var preferences: Preferences
    @ObservedObject var translator: Translator
    var selectionService: SelectionService?

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 0) {
                    languageBar
                    Divider()
                    HSplitView {
                        sourcePane
                        outputPane
                    }
                }
                .modifier(ReadingSurface(cornerRadius: 20))
                if translator.optionsExpanded {
                    translationOptions
                        .frame(width: 284)
                        .transition(.opacity)
                }
            }
            .frame(maxHeight: .infinity)
            actionBar
        }
        .padding(20)
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 940, minHeight: 600)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: translator.optionsExpanded)
        .onAppear {
            selectionService?.showWindow = { openWindow(id: "translate") }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { openWindow(id: "server") } label: { Label("ローカルAPI", systemImage: "network") }
                    .help("ローカルAPIを開く")
                SettingsLink { Label("設定", systemImage: "gearshape") }
                    .help("設定（⌘,）")
                Toggle(isOn: $translator.optionsExpanded) {
                    Label("オプション", systemImage: "sidebar.right")
                }
                .toggleStyle(.button)
                .keyboardShortcut("o", modifiers: [.command, .option])
                .help("翻訳オプション（⌥⌘O）")
            }
        }
        .onChange(of: preferences.models) { _, models in
            if !models.contains(where: { $0.id == translator.modelID }) {
                translator.modelID = preferences.preferredModelID
            }
        }
        .onChange(of: preferences.customPresets) { _, _ in
            if translator.presetID != nil && translator.selectedPreset == nil { translator.presetID = nil }
        }
        .onChange(of: translator.inputFocusRequest) { _, _ in
            articlePopoverPresented = false
        }
        .alert("翻訳エラー", isPresented: Binding(get: { translator.error != nil }, set: { if !$0 { translator.error = nil } })) {
            Button("OK") { translator.error = nil }
        } message: { Text(translator.error ?? "") }
        .alert("記事の取得エラー", isPresented: Binding(get: { translator.articleError != nil }, set: { if !$0 { translator.articleError = nil } })) {
            Button("OK") { translator.articleError = nil }
        } message: { Text(translator.articleError ?? "") }
        .alert("ファイルの取り込みエラー", isPresented: Binding(get: { translator.fileError != nil }, set: { if !$0 { translator.fileError = nil } })) {
            Button("OK") { translator.fileError = nil }
        } message: { Text(translator.fileError ?? "") }
    }

    private var languageBar: some View {
        HStack(spacing: 12) {
            languagePicker("原文の言語", selection: $translator.source, automatic: true)
                .frame(maxWidth: .infinity)
            Button {
                let previous = translator.source
                translator.source = translator.target
                translator.target = previous
            } label: { toolIcon("言語を入れ替え", symbol: "arrow.left.arrow.right") }
            .buttonStyle(.borderless)
            .disabled(translator.source.isEmpty)
            .help("原文と訳文の言語を入れ替え")
            languagePicker("訳文の言語", selection: $translator.target, automatic: false)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private var sourceFont: NSFont {
        preferences.font(for: translator.source.isEmpty ? translator.detectedInputLanguage ?? "" : translator.source)
    }

    private var sourcePane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                paneHeading("原文")
                Spacer(minLength: 4)
                previewButton("原文", isOn: $translator.sourcePreview)
                Button { translator.input = "" } label: { toolIcon("原文を消去", symbol: "xmark") }
                    .disabled(translator.input.isEmpty).help("原文を消去")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 18).padding(.top, 12)
            if translator.sourcePreview {
                markdownPreview(translator.input, font: sourceFont, color: preferences.editorColor)
            } else {
                InputEditor(text: $translator.input, font: sourceFont,
                            textColor: preferences.editorColor, focusRequest: translator.inputFocusRequest,
                            placeholder: "テキストを入力またはペースト", accessibilityName: "翻訳するテキスト",
                            submit: translator.translate)
            }
            VStack(alignment: .leading, spacing: 10) {
                importActions
                Text("\(translator.inputStatistics.characters)文字 · 原文トークン数 約\(translator.inputStatistics.estimatedTokens)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("原文のみの概算。文字種と長さから推定し、モデルは使用しません。Context・辞書・指示トークンは含みません。")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18).padding(.top, 2)
        }
        .frame(minWidth: 260, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("原文")
    }

    private var importActions: some View {
        HStack(spacing: 12) {
            Button { articlePopoverPresented = true } label: {
                Label(translator.fetchingArticle ? "取得中" : "記事を取得", systemImage: "link")
            }
            .disabled(translator.importingFile || translator.busy)
            .help("URLから記事本文を取り込む")
            .popover(isPresented: $articlePopoverPresented) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("記事を取得").font(.headline).accessibilityAddTraits(.isHeader)
                    Text("URLから記事本文を取り込みます。")
                        .font(.callout).foregroundStyle(.secondary)
                    articleURLBar
                }
                .padding(20).frame(width: 440)
                .onAppear { articleURLFocused = true }
                .onDisappear { translator.focusInput() }
            }
            if translator.importingFile {
                ProgressView().controlSize(.small)
                Text(translator.fileProgress).font(.caption.monospacedDigit()).lineLimit(1)
                Button("中止", action: translator.cancelFileImport)
            } else {
                Button("ファイル…", systemImage: "doc.badge.plus", action: translator.chooseFile)
                    .disabled(translator.busy || translator.fetchingArticle)
                    .accessibilityLabel("ファイルを取り込む")
                    .help("PDF・TXT・Markdown・CSV・JSONなどを取り込む")
            }
            if translator.fetchingArticle {
                ProgressView().controlSize(.small).accessibilityLabel("記事を取得中")
            }
        }
        .controlSize(.small)
    }

    private var articleURLBar: some View {
        HStack(spacing: 8) {
            TextField("記事のURL", text: $translator.articleURL)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("記事のURL")
                .focused($articleURLFocused)
                .onSubmit { translator.fetchArticle() }
                .disabled(translator.fetchingArticle || translator.importingFile || translator.busy)
            if translator.fetchingArticle {
                ProgressView().controlSize(.small).accessibilityLabel("記事を取得中")
                Button("中止", action: translator.cancelArticleFetch)
            } else {
                Button("取得", action: translator.fetchArticle)
                    .buttonStyle(.borderedProminent)
                    .disabled(translator.articleURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || translator.importingFile || translator.busy)
                    .help("記事本文をMarkdownに変換し、原文を置き換えます")
            }
        }
    }

    private var outputPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                paneHeading("訳文")
                Spacer(minLength: 4)
                if translator.target == "ja" {
                    Picker("文体", selection: $translator.form) {
                        Text("文体の指定なし").tag("")
                        Text("常体").tag("plain")
                        Text("敬体").tag("polite")
                    }.labelsHidden().fixedSize().controlSize(.small).help("日本語の文体")
                }
                previewButton("訳文", isOn: $translator.outputPreview)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(translator.output, forType: .string)
                } label: { toolIcon("訳文をコピー", symbol: "doc.on.doc") }
                    .disabled(translator.output.isEmpty).help("訳文をコピー")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 18).padding(.top, 12)
            if translator.outputPreview {
                markdownPreview(translator.output, font: preferences.font(for: translator.target), color: preferences.editorColor)
            } else {
                InputEditor(text: .constant(translator.output), editable: false, font: preferences.font(for: translator.target),
                            textColor: preferences.editorColor, placeholder: "翻訳結果がここに表示されます",
                            accessibilityName: "翻訳結果")
            }
            HStack {
                if let metrics = translator.metrics { metricsView(metrics) }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 48, alignment: .bottom)
            .padding(18).padding(.top, 2)
        }
        .frame(minWidth: 260, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("訳文")
    }

    private var translationOptions: some View {
        VStack(spacing: 0) {
            HStack {
                Text("翻訳オプション").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button { translator.optionsExpanded = false } label: {
                    toolIcon("翻訳オプションを閉じる", symbol: "xmark")
                }.buttonStyle(.borderless).help("翻訳オプションを閉じる（⌥⌘O）")
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    optionSection("モデル", symbol: "square.stack.3d.up") {
                        if preferences.models.isEmpty {
                            Text("モデルを登録して翻訳を始めましょう。")
                                .font(.callout).foregroundStyle(.secondary)
                            Button("モデルを追加…", systemImage: "plus", action: preferences.addModel)
                        } else {
                            Picker("モデル", selection: $translator.modelID) {
                                Text("モデルを選択").tag(nil as UUID?)
                                ForEach(preferences.models) { Text($0.tag).tag(Optional($0.id)) }
                            }.labelsHidden().pickerStyle(.menu)
                            HStack(spacing: 6) {
                                Circle().fill(translator.busy || translator.loaded ? Color.green : Color.secondary)
                                    .frame(width: 7, height: 7).accessibilityHidden(true)
                                Text(translator.loaded ? "読み込み済み" : translator.busy ? "読み込み中" : "未読み込み")
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                                if translator.loaded {
                                    Button("解放", systemImage: "eject", action: translator.unload)
                                        .disabled(translator.busy).controlSize(.small).help("モデルをメモリから解放")
                                }
                            }
                        }
                    }
                    Divider()
                    optionSection("コンテキスト", symbol: "text.bubble") {
                        Picker("プリセット", selection: $translator.presetID) {
                            Text("プリセットなし").tag(nil as String?)
                            ForEach(preferences.contextPresets) { Text($0.label).tag(Optional($0.id)) }
                        }.labelsHidden().pickerStyle(.menu)
                        if let preset = translator.selectedPreset {
                            Text(preset.contextDescription)
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("追加のコンテキスト").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $translator.context)
                            .font(.body).scrollContentBackground(.hidden)
                            .padding(8).frame(height: 112)
                            .modifier(ReadingSurface(cornerRadius: 10))
                            .accessibilityLabel("追加のコンテキスト")
                    }
                    Divider()
                    optionSection("生成", symbol: "slider.horizontal.3") {
                        LabeledContent("最大トークン数") {
                            TextField("最大トークン数", value: $translator.maxTokens, format: .number.grouping(.never))
                                .frame(width: 80)
                        }
                        Toggle("長文を自動分割", isOn: $preferences.autoSplit)
                            .help("段落や文の区切りを優先して分割します。最大トークン数は各部分に適用し、上限に達した部分は再分割して翻訳します。")
                        LabeledContent("Temperature") {
                            TextField("Temperature", value: $translator.temperature, format: .number)
                                .frame(width: 80)
                        }
                        Toggle("辞書を使用（\(preferences.glossary.filter { !$0.source.isEmpty && !$0.target.isEmpty }.count)語）", isOn: $translator.useGlossary)
                            .padding(.top, 4)
                    }
                    .font(.callout).textFieldStyle(.roundedBorder)
                }
                .padding(18)
            }
            .scrollIndicators(.visible)
        }
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .modifier(SurfaceBorder(cornerRadius: 20))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("翻訳オプション")
    }

    private func optionSection<Content: View>(_ title: String, symbol: String,
                                              @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private var actionBar: some View {
        HStack(spacing: 16) {
            if translator.busy {
                if let progress = translator.progress {
                    ProgressView(value: progress).frame(width: 60).accessibilityLabel("翻訳の進捗")
                } else {
                    ProgressView().controlSize(.small).accessibilityLabel("翻訳を処理中")
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(translator.status.isEmpty ? idleStatus : translator.status)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2).help(translator.status)
                if translator.busy, let startedAt = translator.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { clock in
                        Text("経過 \(Int(max(0, clock.date.timeIntervalSince(startedAt))))秒")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            if translator.busy {
                Button("中止", action: translator.cancel).keyboardShortcut(.cancelAction)
            }
            Button("翻訳", systemImage: "arrow.right", action: translator.translate)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!translator.canTranslate)
                .help("翻訳（⌘Return）。入力中はReturn、改行はShift+Return")
        }
        .controlSize(.large)
        .padding(14)
        .modifier(ReadingSurface(cornerRadius: 16))
    }

    private var idleStatus: String {
        if translator.modelID == nil { return "オプションでモデルを選択してください" }
        return translator.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "テキストを入力して翻訳" : "翻訳の準備ができました"
    }

    private func paneHeading(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    private func toolIcon(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .labelStyle(.iconOnly)
            .frame(width: 30, height: 30)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private func previewButton(_ pane: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            toolIcon("Markdownプレビュー", symbol: "doc.richtext")
        }
        .toggleStyle(.button).buttonStyle(.borderless)
        .foregroundStyle(isOn.wrappedValue ? Color.accentColor : Color.secondary)
        .background(isOn.wrappedValue ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("\(pane)のMarkdownプレビュー")
        .accessibilityValue(isOn.wrappedValue ? "プレビュー" : "生テキスト")
        .help(isOn.wrappedValue ? "生テキストを表示" : "Markdownをプレビュー")
    }

    private func markdownPreview(_ text: String, font: NSFont, color: NSColor) -> some View {
        MarkdownPreview(text: text, fontName: font.fontName, fontSize: font.pointSize,
                        color: Color(nsColor: color), codeFontName: preferences.codeFont.native.fontName,
                        codeFontSize: preferences.codeFont.native.pointSize)
            .equatable()
    }

    private func languagePicker(_ label: String, selection: Binding<String>, automatic: Bool) -> some View {
        Picker(label, selection: selection) {
            if automatic { Text("自動検出").tag("") }
            ForEach(Language.all) { language in Text(language.name).tag(language.id) }
        }
        .labelsHidden().pickerStyle(.menu)
        .controlSize(.large)
        .font(.system(size: 17, weight: .medium))
        .accessibilityLabel(label)
        .help(label)
    }

    private func metricsView(_ metrics: WorkerEvent) -> some View {
        HStack(spacing: 12) {
            if let elapsed = metrics.elapsed {
                Text(String(format: "%.2f秒", elapsed)).accessibilityLabel(String(format: "所要時間 %.2f秒", elapsed))
            }
            if let tokens = metrics.tokens {
                Text("\(tokens) tokens").accessibilityLabel("生成トークン数 \(tokens)")
            }
            if let tps = metrics.tps {
                Text(String(format: "%.1f token/s", tps)).accessibilityLabel(String(format: "生成速度 毎秒%.1fトークン", tps))
            }
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
    let codeFontName: String
    let codeFontSize: CGFloat

    var body: some View {
        ScrollView {
            Markdown(text)
                .markdownCodeSyntaxHighlighter(PreviewCodeHighlighter.shared)
                .markdownTextStyle {
                    FontFamily(.custom(fontName))
                    FontSize(fontSize)
                    ForegroundColor(color)
                }
                .markdownTextStyle(\.code) {
                    FontFamily(.custom(codeFontName))
                    FontFamilyVariant(.normal)
                    FontSize(codeFontSize)
                }
                .markdownTextStyle(\.link) { ForegroundColor(.accentColor) }
                .markdownBlockStyle(\.codeBlock) { configuration in
                    ScrollView(.horizontal) {
                        configuration.label
                            .markdownTextStyle {
                                FontFamily(.custom(codeFontName))
                                FontFamilyVariant(.normal)
                                FontSize(codeFontSize)
                            }
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(Color.primary.opacity(0.045))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    }
                    .markdownMargin(top: 12, bottom: 12)
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
