import AppKit
import SwiftUI
import MarkdownUI

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var articlePopoverPresented = false
    @State private var pdfAllPages = true
    @State private var pdfStartPage = "1"
    @State private var pdfEndPage = "1"
    @FocusState private var articleURLFocused: Bool
    @ObservedObject var preferences: Preferences
    @ObservedObject var translator: Translator
    var selectionService: SelectionService?

    var body: some View {
        ZStack {
            ScreenBackground(fill: KotobaTheme.mainCanvas)
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 10) {
                        directionBar
                        readingCard
                        actionBar
                    }
                    if translator.optionsExpanded {
                        translationOptions
                            .frame(width: 300)
                            .transition(.opacity)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .padding(18)
        }
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
        .sheet(isPresented: Binding(get: { translator.pendingPDF != nil }, set: {
            if !$0 { translator.pendingPDF = nil }
        })) {
            pdfPageOptions
                .onAppear {
                    pdfAllPages = true
                    pdfStartPage = "1"
                    pdfEndPage = "1"
                }
        }
        .alert("保存エラー", isPresented: Binding(get: { translator.exportError != nil }, set: { if !$0 { translator.exportError = nil } })) {
            Button("OK") { translator.exportError = nil }
        } message: { Text(translator.exportError ?? "") }
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

    // MARK: Direction

    private var directionBar: some View {
        HStack(spacing: 14) {
            languageField("原文の言語", label: "原文", selection: $translator.source, automatic: true)
            swapButton
            languageField("訳文の言語", label: "訳文", selection: $translator.target, automatic: false)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private var swapButton: some View {
        Button {
            let previous = translator.source
            translator.source = translator.target
            translator.target = previous
        } label: {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(translator.source.isEmpty ? Color.secondary.opacity(0.5) : KotobaTheme.accent)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverIconButtonStyle())
        .disabled(translator.source.isEmpty)
        .accessibilityLabel("原文と訳文の言語を入れ替え")
        .help("原文と訳文の言語を入れ替え")
    }

    private func languageField(_ accessibilityLabel: String, label: String,
                               selection: Binding<String>, automatic: Bool) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            SelectField(title: accessibilityLabel, selection: selection,
                        options: (automatic ? [SelectOption(value: "", label: "自動検出")] : [])
                            + Language.all.map { SelectOption(value: $0.id, label: $0.name) },
                        width: 150, large: true)
                .accessibilityLabel(accessibilityLabel)
                .help(accessibilityLabel)
        }
    }

    // MARK: Reading area

    private var readingCard: some View {
        HSplitView {
            sourcePane
            outputPane
        }
        .modifier(PanelSurface(cornerRadius: KotobaTheme.panelRadius))
    }

    private var sourceFont: NSFont {
        preferences.font(for: translator.source.isEmpty ? translator.detectedInputLanguage ?? "" : translator.source)
    }

    private var sourcePane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                paneHeading("原文", symbol: "text.alignleft")
                Spacer(minLength: 4)
                previewButton("原文", isOn: $translator.sourcePreview)
                Button { translator.input = "" } label: { toolIcon("原文を消去", symbol: "xmark") }
                    .disabled(translator.input.isEmpty).help("原文を消去")
            }
            .buttonStyle(HoverIconButtonStyle())
            .padding(.horizontal, 16).padding(.vertical, 10)
            .overlay(alignment: .bottom) { Divider().opacity(0.55) }
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
                HStack(spacing: 7) {
                    Text("\(translator.inputStatistics.characters)文字")
                    Circle().fill(Color.secondary.opacity(0.45))
                        .frame(width: 2.5, height: 2.5)
                        .accessibilityHidden(true)
                    Text("原文トークン数 約\(translator.inputStatistics.estimatedTokens)")
                }
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .help("原文のみの概算。文字種と長さから推定し、モデルは使用しません。Context・辞書・指示トークンは含みません。")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 12)
        }
        .frame(minWidth: 260, maxHeight: .infinity)
        .background(KotobaTheme.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("原文")
    }

    private var importActions: some View {
        HStack(spacing: 10) {
            Button { articlePopoverPresented = true } label: {
                Label(translator.fetchingArticle ? "取得中" : "記事を取得", systemImage: "link")
            }
            .disabled(translator.importingFile || translator.busy)
            .help("URLから記事本文を取り込む")
            .popover(isPresented: $articlePopoverPresented) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 11) {
                        SettingsIcon(symbol: "link", size: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("記事を取得").font(.headline).accessibilityAddTraits(.isHeader)
                            Text("URLから記事本文を取り込みます。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    articleURLBar
                }
                .padding(20).frame(width: 450)
                .background(KotobaTheme.surface)
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
                .textFieldStyle(OutlineTextFieldStyle())
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
            HStack(spacing: 6) {
                paneHeading("訳文", symbol: "text.bubble")
                Spacer(minLength: 4)
                if translator.target == "ja" {
                    SelectField(title: "文体", selection: $translator.form,
                                options: [SelectOption(value: "", label: "文体の指定なし"),
                                          SelectOption(value: "plain", label: "常体"),
                                          SelectOption(value: "polite", label: "敬体")],
                                width: 150, compact: true)
                        .help("日本語の文体")
                }
                previewButton("訳文", isOn: $translator.outputPreview)
                Button(action: translator.saveOutput) {
                    toolIcon("訳文を保存", symbol: "square.and.arrow.down")
                }
                .disabled(translator.output.isEmpty || translator.busy)
                .help("訳文をファイルに保存")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(translator.output, forType: .string)
                } label: { toolIcon("訳文をコピー", symbol: "doc.on.doc") }
                    .disabled(translator.output.isEmpty).help("訳文をコピー")
            }
            .buttonStyle(HoverIconButtonStyle())
            .padding(.horizontal, 16).padding(.vertical, 10)
            .overlay(alignment: .bottom) { Divider().opacity(0.55) }
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
            .frame(minHeight: 46, alignment: .bottom)
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 12)
        }
        .frame(minWidth: 260, maxHeight: .infinity)
        .background(KotobaTheme.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("訳文")
    }

    private var selectedPDFRange: ClosedRange<Int>? {
        guard let start = Int(pdfStartPage), let end = Int(pdfEndPage),
              start >= 1, end >= start else { return nil }
        return start...end
    }

    private var pdfPageOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 11) {
                SettingsIcon(symbol: "doc.richtext", size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text("PDFを取り込む").font(.headline).accessibilityAddTraits(.isHeader)
                    Text(translator.pendingPDF?.lastPathComponent ?? "").lineLimit(2)
                        .foregroundStyle(.secondary).font(.caption)
                }
            }
            Picker("対象ページ", selection: $pdfAllPages) {
                Text("すべてのページ").tag(true)
                Text("ページ範囲を指定").tag(false)
            }.pickerStyle(.radioGroup)
            HStack {
                TextField("開始ページ", text: $pdfStartPage)
                    .accessibilityLabel("開始ページ")
                Text("〜")
                TextField("終了ページ", text: $pdfEndPage)
                    .accessibilityLabel("終了ページ")
            }
            .textFieldStyle(OutlineTextFieldStyle())
            .disabled(pdfAllPages)
            Text("ページ番号は先頭を1として指定します。取り込むと原文を置き換えます。")
                .font(.caption).foregroundStyle(.secondary)
            if !pdfAllPages && selectedPDFRange == nil {
                Label("1以上の開始ページと、それ以降の終了ページを入力してください。",
                      systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("キャンセル") { translator.pendingPDF = nil }
                    .keyboardShortcut(.cancelAction)
                Button("取り込む") {
                    guard let url = translator.pendingPDF else { return }
                    let range = pdfAllPages ? nil : selectedPDFRange
                    translator.pendingPDF = nil
                    translator.importFile(url, pageRange: range)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!pdfAllPages && selectedPDFRange == nil)
            }
        }
        .padding(24).frame(width: 410)
        .background(KotobaTheme.surface)
    }

    // MARK: Options

    private var translationOptions: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                SettingsIcon(symbol: "slider.horizontal.3", size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("翻訳オプション").font(.system(size: 14, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("モデル・コンテキスト・生成").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button { translator.optionsExpanded = false } label: {
                    toolIcon("翻訳オプションを閉じる", symbol: "xmark")
                }.buttonStyle(HoverIconButtonStyle()).help("翻訳オプションを閉じる（⌥⌘O）")
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider().opacity(0.6)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    optionSection("モデル", symbol: "square.stack.3d.up") {
                        if preferences.models.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("モデルを登録して翻訳を始めましょう。")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button("モデルを追加…", systemImage: "plus", action: preferences.addModel)
                                    .controlSize(.small)
                            }
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(KotobaTheme.well,
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        } else {
                            SelectField(title: "モデル", selection: $translator.modelID,
                                        options: [SelectOption<UUID?>(value: nil, label: "モデルを選択")]
                                            + preferences.models.map { SelectOption(value: Optional($0.id), label: $0.tag) },
                                        placeholder: "モデルを選択",
                                        width: 268)
                            HStack(spacing: 7) {
                                Circle().fill(translator.busy || translator.loaded ? Color.green : Color.secondary.opacity(0.5))
                                    .frame(width: 7, height: 7).accessibilityHidden(true)
                                Text(translator.loaded ? "読み込み済み" : translator.busy ? "読み込み中" : "未読み込み")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                                if translator.loaded {
                                    Button("解放", systemImage: "eject", action: translator.unload)
                                        .disabled(translator.busy).controlSize(.small).help("モデルをメモリから解放")
                                }
                            }
                        }
                    }
                    Divider().opacity(0.6)
                    optionSection("コンテキスト", symbol: "text.bubble") {
                        SelectField(title: "プリセット", selection: $translator.presetID,
                                    options: [SelectOption<String?>(value: nil, label: "プリセットなし")]
                                        + preferences.contextPresets.map { SelectOption(value: Optional($0.id), label: $0.label) },
                                    width: 268)
                        if let preset = translator.selectedPreset {
                            Text(preset.contextDescription)
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(KotobaTheme.well,
                                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        Text("追加のコンテキスト")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        TextEditor(text: $translator.context)
                            .font(.system(size: 13)).scrollContentBackground(.hidden)
                            .padding(8).frame(height: 108)
                            .modifier(ReadingSurface(cornerRadius: 10, fill: KotobaTheme.well))
                            .accessibilityLabel("追加のコンテキスト")
                    }
                    Divider().opacity(0.6)
                    optionSection("生成", symbol: "slider.horizontal.3") {
                        optionValueRow("最大トークン数") {
                            TextField("最大トークン数", value: $translator.maxTokens, format: .number.grouping(.never))
                                .frame(width: 88).multilineTextAlignment(.trailing)
                        }
                        optionValueRow("Temperature") {
                            TextField("Temperature", value: $translator.temperature, format: .number)
                                .frame(width: 88).multilineTextAlignment(.trailing)
                        }
                        Text("入力と生成の合計は32,768トークン以内です。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Divider().opacity(0.5)
                        optionToggle("長文を自動分割", isOn: $preferences.autoSplit,
                                     help: "段落や文の区切りを優先して分割します。生成上限への到達や長い繰り返しを検出した部分は、さらに小さく分割して再翻訳します。")
                        optionToggle("辞書を使用（\(preferences.glossary.filter { !$0.source.isEmpty && !$0.target.isEmpty }.count)語）",
                                     isOn: $translator.useGlossary,
                                     help: "登録した用語を翻訳に反映します。")
                    }
                    .font(.system(size: 13))
                    .textFieldStyle(OutlineTextFieldStyle())
                }
                .padding(16)
            }
            .scrollIndicators(.visible)
        }
        .frame(maxHeight: .infinity)
        .modifier(PanelSurface(cornerRadius: KotobaTheme.panelRadius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("翻訳オプション")
    }

    private func optionSection<Content: View>(_ title: String, symbol: String,
                                              @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(KotobaTheme.accent)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func optionValueRow<Content: View>(_ title: String,
                                               @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
            content()
        }
        .frame(minHeight: 26)
    }

    private func optionToggle(_ title: String, isOn: Binding<Bool>, help: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .frame(minHeight: 26)
        .help(help)
    }

    // MARK: Status and actions

    private var actionBar: some View {
        HStack(spacing: 14) {
            statusGlyph
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 9) {
                    Text(translator.status.isEmpty ? idleStatus : translator.status)
                        .font(.system(size: 13, weight: translator.translationCompleted ? .semibold : .regular))
                        .foregroundStyle(translator.translationCompleted ? Color.primary : Color.secondary)
                        .lineLimit(2).help(translator.status)
                    if translator.busy, let progress = translator.progress {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(KotobaTheme.accent)
                            .frame(width: 74)
                            .accessibilityLabel("翻訳の進捗")
                    }
                }
                if !translator.recoveryStatus.isEmpty {
                    Text(translator.recoveryStatus)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(2).help(translator.recoveryStatus)
                }
                if translator.busy, let startedAt = translator.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { clock in
                        Text("経過 \(Int(max(0, clock.date.timeIntervalSince(startedAt))))秒")
                            .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            if translator.busy {
                Button("中止", action: translator.cancel).keyboardShortcut(.cancelAction)
            }
            Button(action: translator.translate) {
                Label("翻訳", systemImage: "arrow.right")
                    .frame(minWidth: 84)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!translator.canTranslate)
            .help("翻訳（⌘Return）。入力中はReturn、改行はShift+Return")
        }
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private var statusGlyph: some View {
        Group {
            if translator.busy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: translator.translationCompleted ? "checkmark.circle.fill" : "text.bubble")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(translator.translationCompleted ? KotobaTheme.accent : Color.secondary)
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .frame(width: 26, height: 26)
        .accessibilityHidden(true)
    }

    private var idleStatus: String {
        if translator.modelID == nil { return "オプションでモデルを選択してください" }
        return translator.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "テキストを入力して翻訳" : "翻訳の準備ができました"
    }

    // MARK: Small pieces

    private func paneHeading(_ title: String, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(KotobaTheme.accent)
                .symbolRenderingMode(.hierarchical)
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func toolIcon(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .labelStyle(.iconOnly)
            .font(.system(size: 12, weight: .medium))
            .frame(width: 28, height: 28)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func previewButton(_ pane: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            toolIcon("Markdownプレビュー", symbol: "doc.richtext")
        }
        .toggleStyle(.button).buttonStyle(HoverIconButtonStyle())
        .foregroundStyle(isOn.wrappedValue ? KotobaTheme.accent : Color.secondary)
        .background(isOn.wrappedValue ? KotobaTheme.accentSoft : .clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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

    private func metricsView(_ metrics: WorkerEvent) -> some View {
        HStack(spacing: 10) {
            if let elapsed = metrics.elapsed {
                Text(String(format: "%.2f秒", elapsed)).accessibilityLabel(String(format: "所要時間 %.2f秒", elapsed))
            }
            if let tokens = metrics.tokens {
                Text("\(tokens) tokens").accessibilityLabel("生成トークン数 \(tokens)")
            }
            if let tps = metrics.tps {
                Text(String(format: "%.1f token/s", tps)).accessibilityLabel(String(format: "生成速度 毎秒%.1fトークン", tps))
            }
        }.font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
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
                .markdownTextStyle(\.link) { ForegroundColor(KotobaTheme.accent) }
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
                    .background(KotobaTheme.well)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(KotobaTheme.border.opacity(0.8), lineWidth: 0.75)
                    }
                    .markdownMargin(top: 12, bottom: 12)
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
