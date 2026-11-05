import AppKit
import SwiftUI

struct ServerView: View {
    @ObservedObject var server: LocalAPIServer
    @ObservedObject var preferences: Preferences
    @ObservedObject var translator: Translator
    @State private var portText: String

    init(server: LocalAPIServer, preferences: Preferences, translator: Translator) {
        self.server = server
        self.preferences = preferences
        self.translator = translator
        _portText = State(initialValue: String(server.port))
    }

    private var validPort: Bool {
        Int(portText).map { (1024...65535).contains($0) } ?? false
    }

    private var connectionIssue: String? {
        guard validPort else {
            return "ポートは1024〜65535の整数で指定してください。"
        }
        guard server.apiKey.count >= 16, server.apiKey.utf8.allSatisfy({ (33...126).contains($0) }) else {
            return "APIキーは空白を含まない半角16文字以上で指定してください。"
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label("ローカルAPI", systemImage: "network").font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("このMacのアプリから翻訳に接続します。利用中はKotoba Translateを起動しておいてください。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            TabView {
                connectionSettings.tabItem { Label("接続", systemImage: "network") }
                RequestBuilderView(server: server)
                    .tabItem { Label("リクエストを試す", systemImage: "curlybraces") }
            }
        }
        .padding(20)
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 720, minHeight: 700)
        .preferredColorScheme(.light)
        .onChange(of: portText) { _, value in
            if let port = Int(value), (1024...65535).contains(port) { server.port = port }
        }
        .onChange(of: server.port) { _, value in portText = String(value) }
        .onChange(of: preferences.models, initial: true) { _, models in
            if let id = server.modelID, !models.contains(where: { $0.id == id }) { server.modelID = nil }
        }
    }

    private var connectionSettings: some View {
        VStack(spacing: 16) {
            Form {
                Section("接続設定") {
                    TextField("ポート", text: $portText)
                        .disabled(server.running || server.starting)
                        .help("1024〜65535。接続先は127.0.0.1に限定されます。")
                    SecureField("APIキー", text: $server.apiKey).disabled(server.running || server.starting)
                    HStack {
                        Button("APIキーをコピー") { copy(server.apiKey) }
                            .disabled(server.apiKey.isEmpty)
                        Button("キーを再発行") { server.apiKey = UUID().uuidString + UUID().uuidString }
                            .disabled(server.running || server.starting)
                            .help("再発行後は、接続するアプリのAPIキーも更新してください。")
                    }
                    Text("接続設定は停止中に変更できます。キーを再発行した場合は、接続するアプリ側も更新してください。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let issue = connectionIssue {
                        Label(issue, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Section("接続するアプリに設定する値") {
                    LabeledContent("Base URL") {
                        Text(server.baseURL).textSelection(.enabled).font(.system(.callout, design: .monospaced))
                        Button("コピー") { copy(server.baseURL) }
                            .accessibilityLabel("Base URLをコピー").disabled(!validPort)
                    }
                    LabeledContent("モデル名") {
                        Text("plamo-translate").textSelection(.enabled).font(.system(.callout, design: .monospaced))
                        Button("コピー") { copy("plamo-translate") }.accessibilityLabel("モデル名をコピー")
                    }
                    Text("OpenAI互換APIに対応したアプリに、Base URL・APIキー・モデル名を入力します。登録した一意のタグや、モデル一覧APIのIDも指定できます。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("翻訳の既定値") {
                    Picker("モデル", selection: $server.modelID) {
                        Text("設定のデフォルト").tag(nil as UUID?)
                        ForEach(preferences.models) { Text($0.tag).tag(Optional($0.id)) }
                    }
                    if preferences.models.isEmpty {
                        Text("翻訳には、設定画面でモデルを登録してください。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    languagePicker("原文", selection: $server.source, automatic: true)
                    languagePicker("訳文", selection: $server.target, automatic: false)
                    if server.target == "ja" {
                        Picker("文体", selection: $server.form) {
                            Text("指定なし").tag(""); Text("常体").tag("plain"); Text("敬体").tag("polite")
                        }
                    }
                    Text("リクエストで言語・文体を省略した場合に使います。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ServerCapacityView(pool: server.inference)
                Section("共有モデル") {
                    HStack(spacing: 8) {
                        if translator.busy || translator.loaded {
                            Circle().fill(.green).frame(width: 7, height: 7).accessibilityHidden(true)
                        }
                        Text(translator.busy ? (translator.servingAPI ? "API: " : "翻訳画面: ") + translator.status : translator.loaded ? "読み込み済み" : "未読み込み")
                        Spacer()
                        if translator.busy && translator.servingAPI { Button("翻訳を中止", action: translator.cancel) }
                        Button("解放", systemImage: "eject", action: translator.unload)
                            .disabled(!translator.loaded || translator.busy).help("モデルをメモリから解放")
                    }
                    Picker("自動解放", selection: $preferences.unloadSeconds) {
                        Text("完了後すぐ").tag(0); Text("1分後").tag(60); Text("5分後").tag(300)
                        Text("15分後").tag(900); Text("30分後").tag(1800); Text("アプリ終了時").tag(-1)
                    }
                    if translator.busy, let startedAt = translator.startedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { clock in
                            Text("経過 \(Int(max(0, clock.date.timeIntervalSince(startedAt))))秒")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    if let metrics = translator.metrics {
                        HStack(spacing: 12) {
                            Text("直近の翻訳")
                            if let tokens = metrics.tokens { Text("\(tokens) tokens") }
                            if let tps = metrics.tps { Text(String(format: "%.1f token/s", tps)) }
                            if let elapsed = metrics.elapsed { Text(String(format: "%.2f秒", elapsed)) }
                        }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text("通常は翻訳画面と1つのモデルを共有します。混雑時だけ追加のモデルを読み込み、追加分は30秒の待機後に解放します。最後の1つは上の自動解放設定に従います。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            if let error = server.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
                if server.starting { ProgressView().controlSize(.small).accessibilityLabel("サーバーを起動中") }
                VStack(alignment: .leading, spacing: 4) {
                    Text(server.running ? "受付中" : server.starting ? "起動中" : "停止中").font(.headline)
                    Text(server.running ? "完了 \(server.completed)件 · このMacからのみ接続できます" : "このMacからのみ接続できます")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                if server.running || server.starting {
                    Button(server.starting ? "中止" : "サーバーを停止", action: server.stop)
                        .help("接続を閉じ、実行中のAPIリクエストも中止します。")
                } else {
                    Button("サーバーを開始", action: server.start).buttonStyle(.borderedProminent)
                        .disabled(connectionIssue != nil)
                }
            }
            .controlSize(.large).padding(14).modifier(ControlSurface())
        }.padding(12)
    }
}

private struct ServerCapacityView: View {
    @ObservedObject var pool: ServerInferencePool

    var body: some View {
        Section("混雑時の処理") {
            Picker("最大並列数", selection: $pool.maxConcurrency) {
                ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
            }
            Toggle("バッテリー駆動中も並列数を増やす", isOn: $pool.allowBattery)
            Picker("確保するメモリの余裕", selection: $pool.reserveGB) {
                ForEach([2, 4, 8, 12, 16], id: \.self) { Text("\($0) GB").tag($0) }
            }
            HStack(spacing: 12) {
                if pool.loadedCount > 0 { Circle().fill(.green).frame(width: 7, height: 7).accessibilityHidden(true) }
                Text("実行 \(pool.activeCount)件 · 待機 \(pool.waitingCount)件 · モデル \(pool.loadedCount)個")
                Spacer()
                Button("実行中を中止", action: pool.cancelActive).disabled(pool.activeCount == 0)
                Button("待機モデルを解放", action: pool.unloadIdle).disabled(pool.loadedCount == 0)
            }
            Text(pool.reason).font(.caption).foregroundStyle(.secondary)
            Text(String(format: "利用可能メモリの目安 %.1f GB · %@%@%@",
                        Double(pool.resources.availableBytes) / 1_073_741_824,
                        pool.resources.onACPower ? "外部電源で駆動" : "バッテリー",
                        pool.resources.lowPower ? " · 低電力モード" : "",
                        pool.resources.hot ? " · 高温" : ""))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text("通常は1並列。最大32件を待機させ、電源・温度・メモリを確認して必要なときだけ増やします。低電力モード・高温・メモリプレッシャー時は1並列。実行中の翻訳は完了まで続けます。")
                .font(.caption).foregroundStyle(.secondary)
            Text("並列ごとにモデル用メモリが必要です。GPUの競合で遅くなる場合は最大並列数を1に戻してください。接続するアプリ側の並列数は2〜4が目安です。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct RequestDraft: Equatable {
    var text = ""
    var context = ""
    var source = ""
    var target = "ja"
    var form = ""
    var useGlossary = true
    var maxTokens = "2048"
    var temperature = "0"
    var stream = true

    var issue: String? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "原文を入力してください。" }
        guard let limit = Int(maxTokens), (1..<32768).contains(limit) else {
            return "最大生成トークン数は1〜32767の整数で指定してください。"
        }
        guard let value = Double(temperature), value.isFinite, (0...2).contains(value) else {
            return "Temperatureは0〜2の数値で指定してください。小数点には「.」を使います。"
        }
        return nil
    }
}

private struct RequestBuilderView: View {
    @ObservedObject var server: LocalAPIServer
    @State private var draft = RequestDraft()
    @State private var generatedDraft: RequestDraft?
    @State private var json = ""
    @State private var response = ""
    @State private var requestError: String?
    @State private var sending = false
    @State private var sendTask: Task<Void, Never>?
    @FocusState private var jsonFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Form {
                Section("1. 翻訳する内容") {
                    Text("原文").font(.headline).accessibilityAddTraits(.isHeader)
                    TextEditor(text: $draft.text).scrollContentBackground(.hidden)
                        .padding(8).frame(height: 100).modifier(ReadingSurface(cornerRadius: 10))
                        .accessibilityLabel("JSONに含める原文")
                    languagePicker("原文の言語", selection: $draft.source, automatic: true)
                    languagePicker("訳文の言語", selection: $draft.target, automatic: false)
                    if draft.target == "ja" {
                        Picker("文体", selection: $draft.form) {
                            Text("指定なし").tag(""); Text("常体").tag("plain"); Text("敬体").tag("polite")
                        }
                    }
                    Text("コンテキスト（任意）").font(.headline).accessibilityAddTraits(.isHeader)
                    TextEditor(text: $draft.context).scrollContentBackground(.hidden)
                        .padding(8).frame(height: 80).modifier(ReadingSurface(cornerRadius: 10))
                        .accessibilityLabel("JSONに含めるコンテキスト")
                }.disabled(sending)
                Section("生成設定") {
                    TextField("最大生成トークン数", text: $draft.maxTokens)
                        .help("max_tokens: 1〜32767。入力と生成の合計は32768トークン以内。")
                    TextField("Temperature", text: $draft.temperature).help("0〜2。小数点には「.」を使います。")
                    Toggle("辞書を使用", isOn: $draft.useGlossary)
                    Toggle("ストリーミング", isOn: $draft.stream)
                    if let issue = draft.issue {
                        Label(issue, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                    }
                }.disabled(sending)
                Section("2. 送信するJSON") {
                    HStack {
                        Button("JSONを生成", systemImage: "curlybraces", action: generate)
                            .disabled(sending || draft.issue != nil)
                        Button("JSONをコピー") { copy(json) }.disabled(json.isEmpty)
                        Spacer()
                    }
                    if let generatedDraft, generatedDraft != draft {
                        Label("フォームの変更は未反映です。「JSONを生成」で更新してください。", systemImage: "exclamationmark.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    TextEditor(text: $json).font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden).padding(8).frame(height: 200)
                        .modifier(ReadingSurface(cornerRadius: 10)).accessibilityLabel("送信するJSON（編集可）")
                        .focused($jsonFocused).disabled(sending)
                    Text("送信時はこのJSONをそのまま使います。言語・文体を省略した場合は「接続」タブの既定値が使われます。APIキーは自動的にヘッダーへ付与し、JSONには含めません。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let requestError {
                        Label(requestError, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                if !response.isEmpty {
                    Section("3. 応答") {
                        InputEditor(text: .constant(response), editable: false, font: .monospacedSystemFont(ofSize: 12, weight: .regular))
                            .frame(height: 220).modifier(ReadingSurface(cornerRadius: 10))
                            .accessibilityLabel("APIの応答（読み取り専用）")
                        Button("応答をコピー") { copy(response) }
                    }
                }
                Section {
                    Text("テキスト翻訳専用です。userの本文を翻訳し、system/developerは参考情報として扱います。本文・JSON・応答は保存しません。この画面を離れると送信を中止します。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            HStack(spacing: 12) {
                Button("消去") {
                    draft.text = ""; draft.context = ""; json = ""; response = ""
                    generatedDraft = nil; requestError = nil
                }.disabled(sending || (draft.text.isEmpty && draft.context.isEmpty && json.isEmpty && response.isEmpty))
                VStack(alignment: .leading, spacing: 4) {
                    Text(sending ? "送信中" : server.running ? "送信先" : "サーバーが停止しています")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(server.running ? "POST \(server.baseURL)/chat/completions" : "「接続」タブでサーバーを開始してください。")
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                Spacer(minLength: 0)
                if sending {
                    ProgressView().controlSize(.small).accessibilityLabel("APIの応答を待機中")
                    Button("中止") { sendTask?.cancel() }
                } else {
                    Button("送信して試す", systemImage: "paperplane", action: send)
                        .buttonStyle(.borderedProminent)
                        .disabled(!server.running || json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .controlSize(.large).padding(14).modifier(ControlSurface())
        }
        .padding(12)
        .onChange(of: json) { _, _ in requestError = nil }
        .onDisappear { sendTask?.cancel() }
    }

    private func generate() {
        guard draft.issue == nil, let maxTokens = Int(draft.maxTokens), let temperature = Double(draft.temperature) else { return }
        let value: [String: Any] = [
            "model": "plamo-translate", "messages": [["role": "user", "content": draft.text]],
            "source_lang": draft.source, "target_lang": draft.target, "form": draft.target == "ja" ? draft.form : "",
            "context": draft.context, "use_glossary": draft.useGlossary,
            "max_tokens": maxTokens, "temperature": temperature, "stream": draft.stream
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            json = String(decoding: data, as: UTF8.self)
            generatedDraft = draft
            requestError = nil
        } catch { requestError = error.localizedDescription }
    }

    private func send() {
        guard server.running, !sending else { return }
        do {
            guard try JSONSerialization.jsonObject(with: Data(json.utf8)) is [String: Any] else {
                requestError = "JSONの最上位にはオブジェクト（{ … }）を指定してください。"
                jsonFocused = true
                return
            }
        } catch {
            requestError = "JSONの構文を確認してください。" + error.localizedDescription
            jsonFocused = true
            return
        }
        requestError = nil
        guard let url = URL(string: server.baseURL + "/chat/completions") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(json.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + server.apiKey, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 600
        sending = true
        response = ""
        sendTask = Task { @MainActor in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForResource = 600
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel(); sending = false; sendTask = nil }
            do {
                let (bytes, reply) = try await session.bytes(for: request)
                response = "HTTP \((reply as? HTTPURLResponse)?.statusCode ?? 0)\n"
                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    response += line + "\n"
                }
            } catch { response += Task.isCancelled ? "\n中止" : "\n" + error.localizedDescription }
        }
    }
}

private func languagePicker(_ title: String, selection: Binding<String>, automatic: Bool) -> some View {
    Picker(title, selection: selection) {
        if automatic { Text("自動検出").tag("") }
        ForEach(Language.all) { Text($0.name).tag($0.id) }
    }.pickerStyle(.menu)
}

private func copy(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
}
