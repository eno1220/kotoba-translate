import AppKit
import SwiftUI

struct ServerView: View {
    @ObservedObject var server: LocalAPIServer
    @ObservedObject var preferences: Preferences
    @ObservedObject var translator: Translator
    @State private var portText: String
    @State private var selection: ServerPage? = .connection

    private enum ServerPage: String, CaseIterable, Identifiable {
        case connection, request
        var id: Self { self }
        var title: String { self == .connection ? "サーバー" : "リクエストを試す" }
        var symbol: String { self == .connection ? "network" : "curlybraces" }
    }

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
        guard validPort else { return "ポートは1024〜65535の整数で指定してください。" }
        guard server.apiKey.count >= 16, server.apiKey.utf8.allSatisfy({ (33...126).contains($0) }) else {
            return "APIキーは空白を含まない半角16文字以上で指定してください。"
        }
        return nil
    }

    var body: some View {
        NavigationSplitView {
            List(ServerPage.allCases, selection: $selection) { page in
                SettingsNavigationLabel(title: page.title, symbol: page.symbol).tag(page)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .textBackgroundColor))
            .navigationTitle("ローカルAPI")
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 250)
            .safeAreaInset(edge: .bottom) {
                Label(server.running ? "サーバー受付中" : server.starting ? "サーバー起動中" : "サーバー停止中",
                      systemImage: server.running ? "network" : "network.slash")
                    .font(.callout).foregroundStyle(.secondary).padding(20)
            }
        } detail: {
            VStack(spacing: 0) {
                DetailHeading(title: (selection ?? .connection).title,
                              description: selection == .request ? "JSONを作成して、このMacのAPIで翻訳を試します。" : "このMacのアプリから翻訳に接続します。")
                ZStack {
                    // Keep the draft when navigating, and cancel its request when leaving it.
                    RequestBuilderView(server: server, active: selection == .request)
                        .opacity(selection == .request ? 1 : 0)
                        .allowsHitTesting(selection == .request)
                        .accessibilityHidden(selection != .request)
                        .disabled(selection != .request)
                    if selection != .request { connectionSettings }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(minWidth: 940, minHeight: 700)
        .background(CompactWindowToolbar())
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
        SettingsPage {
            SettingsCard(title: "") {
                HStack(spacing: 16) {
                    SettingsIcon(symbol: "network", size: 36)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Kotoba Translate API").font(.system(size: 17, weight: .semibold))
                        Text(server.running ? "受付中 · 完了 \(server.completed)件" : server.starting ? "起動中" : "停止中")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                    if server.starting { ProgressView().controlSize(.small).accessibilityLabel("サーバーを起動中") }
                    if server.running || server.starting {
                        Button(server.starting ? "中止" : "サーバーを停止", action: server.stop)
                            .help("接続を閉じ、実行中のAPIリクエストも中止します。")
                    } else {
                        Button("サーバーを開始", action: server.start).buttonStyle(.borderedProminent)
                            .disabled(connectionIssue != nil)
                    }
                }
                Divider()
                Text("このMacからのみ接続できます。利用中はアプリを起動しておいてください。")
                    .font(.callout).foregroundStyle(.secondary)
                if let error = server.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).textSelection(.enabled)
                }
            }
            SettingsCard(title: "接続するアプリに設定する値") {
                SettingsRow("Base URL") {
                    Text(server.baseURL).textSelection(.enabled).font(.system(.callout, design: .monospaced))
                    Button { copy(server.baseURL) } label: { Image(systemName: "doc.on.doc") }
                        .accessibilityLabel("Base URLをコピー").help("Base URLをコピー").disabled(!validPort)
                }
                Divider()
                SettingsRow("モデル名") {
                    Text("plamo-translate").textSelection(.enabled).font(.system(.callout, design: .monospaced))
                    Button { copy("plamo-translate") } label: { Image(systemName: "doc.on.doc") }
                        .accessibilityLabel("モデル名をコピー").help("モデル名をコピー")
                }
                Text("OpenAI互換APIに対応したアプリに、Base URL・APIキー・モデル名を入力します。登録した一意のタグや、モデル一覧APIのIDも指定できます。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            SettingsCard(title: "接続設定") {
                SettingsRow("ポート", description: "127.0.0.1に限定して接続を受け付けます。") {
                    TextField("ポート", text: $portText).frame(width: 100)
                        .disabled(server.running || server.starting).help("1024〜65535")
                }
                Divider()
                SettingsRow("APIキー") {
                    SecureField("APIキー", text: $server.apiKey).frame(maxWidth: 300)
                        .disabled(server.running || server.starting)
                }
                HStack {
                    Text("接続設定は停止中に変更できます。")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("コピー") { copy(server.apiKey) }.disabled(server.apiKey.isEmpty)
                        .accessibilityLabel("APIキーをコピー")
                    Button("再発行") { server.apiKey = UUID().uuidString + UUID().uuidString }
                        .disabled(server.running || server.starting)
                        .help("接続するアプリのAPIキーも更新してください。")
                        .accessibilityLabel("APIキーを再発行")
                }
                if let issue = connectionIssue {
                    Label(issue, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.secondary)
                }
            }
            SettingsCard(title: "翻訳の既定値") {
                SettingsRow("モデル") {
                    Picker("モデル", selection: $server.modelID) {
                        Text("設定のデフォルト").tag(nil as UUID?)
                        ForEach(preferences.models) { Text($0.tag).tag(Optional($0.id)) }
                    }.pickerStyle(.menu).frame(maxWidth: 280)
                }
                if preferences.models.isEmpty {
                    Text("翻訳には、設定画面でモデルを登録してください。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Divider()
                SettingsRow("原文の言語") {
                    languagePicker("原文の言語", selection: $server.source, automatic: true).frame(width: 220)
                }
                Divider()
                SettingsRow("訳文の言語") {
                    languagePicker("訳文の言語", selection: $server.target, automatic: false).frame(width: 220)
                }
                if server.target == "ja" {
                    Divider()
                    SettingsRow("文体") {
                        Picker("文体", selection: $server.form) {
                            Text("指定なし").tag(""); Text("常体").tag("plain"); Text("敬体").tag("polite")
                        }.pickerStyle(.menu).frame(width: 160)
                    }
                }
                Text("リクエストで言語・文体を省略した場合に使います。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ServerCapacityView(pool: server.inference)
            sharedModelSettings
        }
    }

    private var sharedModelSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "共有モデル") {
                SettingsRow("状態") {
                    HStack(spacing: 7) {
                        Circle().fill(translator.busy || translator.loaded ? Color.green : Color.secondary)
                            .frame(width: 8, height: 8).accessibilityHidden(true)
                        Text(translator.busy ? (translator.servingAPI ? "API: " : "翻訳画面: ") + translator.status : translator.loaded ? "読み込み済み" : "未読み込み")
                    }
                }
                if let path = translator.loadedModelPath,
                   let model = preferences.models.first(where: { $0.path == path }) {
                    SettingsRow("モデル") { Text(model.tag).textSelection(.enabled) }
                }
                Divider()
                SettingsRow("自動解放") {
                    Picker("自動解放", selection: $preferences.unloadSeconds) {
                        Text("完了後すぐ").tag(0); Text("1分後").tag(60); Text("5分後").tag(300)
                        Text("15分後").tag(900); Text("30分後").tag(1800); Text("アプリ終了時").tag(-1)
                    }.pickerStyle(.menu).frame(width: 160)
                }
                SettingsRow("モデルの操作") {
                    Button("モデルを解放", systemImage: "eject", action: translator.unload)
                        .disabled(!translator.loaded || translator.busy).help("共有モデルをメモリから解放")
                    if translator.busy && translator.servingAPI {
                        Button("翻訳を中止", action: translator.cancel)
                    }
                }
                Text("翻訳画面とAPIで共有します。混雑時に追加したモデルは30秒後に解放し、最後の1つには上の自動解放設定を使います。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if translator.busy || translator.metrics != nil || !server.lastTimings.isEmpty {
                SettingsCard(title: "計測情報") {
                    if translator.busy, let startedAt = translator.startedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { clock in
                            SettingsRow("現在の経過時間") {
                                Text("\(Int(max(0, clock.date.timeIntervalSince(startedAt))))秒").monospacedDigit()
                            }
                        }
                    }
                    if let metrics = translator.metrics {
                        DisclosureGroup("直近の翻訳") {
                            VStack(alignment: .leading, spacing: 4) {
                                if let elapsed = metrics.elapsed {
                                    SettingsRow("所要時間") { Text(String(format: "%.2f秒", elapsed)).monospacedDigit() }
                                }
                                if let tokens = metrics.tokens {
                                    SettingsRow("生成トークン数") { Text("\(tokens) tokens").monospacedDigit() }
                                }
                                if let tps = metrics.tps {
                                    SettingsRow("生成速度") { Text(String(format: "%.1f token/s", tps)).monospacedDigit() }
                                }
                            }.padding(.top, 8)
                        }
                    }
                    if !server.lastTimings.isEmpty {
                        DisclosureGroup("直近のAPIリクエスト") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach([("total_seconds", "合計"), ("queue_seconds", "待機"),
                                         ("first_content_seconds", "最初の訳文まで"), ("load_seconds", "読み込み"),
                                         ("prompt_seconds", "入力処理"), ("generation_seconds", "生成")], id: \.0) { key, label in
                                    if let seconds = server.lastTimings[key] {
                                        SettingsRow(label) { Text(String(format: "%.2f秒", seconds)).monospacedDigit() }
                                    }
                                }
                                if let tps = server.lastTimings["generation_tps"] {
                                    SettingsRow("生成速度") { Text(String(format: "%.1f token/s", tps)).monospacedDigit() }
                                }
                            }.padding(.top, 8)
                        }
                        .help("サーバー内の計測です。合計は待機やPython起動を含みます。入力処理・生成はMLXの速度から算出。転送・描画時間は含みません。")
                    }
                }
            }
        }
    }
}

private struct ServerCapacityView: View {
    @ObservedObject var pool: ServerInferencePool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "混雑時の処理") {
                SettingsRow("最大並列数") {
                    Picker("最大並列数", selection: $pool.maxConcurrency) {
                        ForEach(1...4, id: \.self) { Text("\($0)件").tag($0) }
                    }.pickerStyle(.menu).frame(width: 160)
                }
                Divider()
                SettingsRow("バッテリー時", description: "バッテリー駆動中も並列数を増やすことを許可します。") {
                    Toggle("バッテリー駆動中も並列数を増やす", isOn: $pool.allowBattery)
                }
                Divider()
                SettingsRow("メモリの余裕") {
                    Picker("確保するメモリの余裕", selection: $pool.reserveGB) {
                        ForEach([2, 4, 8, 12, 16], id: \.self) { Text("\($0) GB").tag($0) }
                    }.pickerStyle(.menu).frame(width: 160)
                }
                DisclosureGroup("並列処理について") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("通常は1並列。最大32件を待機させ、電源・温度・メモリを確認して必要なときだけ増やします。低電力モード・高温・メモリプレッシャー時は1並列。実行中の翻訳は完了まで続けます。")
                        Text("速度を優先する場合は、この設定と接続するアプリ側の並列数を1にしてください。並列ごとにモデル用メモリが必要で、GPUの競合により遅くなる場合があります。2以上はページ全体の完了時間を比較して選んでください。")
                    }.font(.callout).foregroundStyle(.secondary).padding(.top, 8)
                }
            }
            SettingsCard(title: "現在の処理状況") {
                SettingsRow("実行中") {
                    Text("\(pool.activeCount)件").monospacedDigit().frame(width: 64, alignment: .leading)
                    Button("実行中を中止", action: pool.cancelActive).disabled(pool.activeCount == 0)
                }
                Divider()
                SettingsRow("待機中") { Text("\(pool.waitingCount)件").monospacedDigit() }
                Divider()
                SettingsRow("読み込み済みモデル") {
                    Text("\(pool.loadedCount)個").monospacedDigit().frame(width: 64, alignment: .leading)
                    Button("待機モデルを解放", action: pool.unloadIdle).disabled(pool.loadedCount == 0)
                }
                Text(pool.reason).font(.callout).foregroundStyle(.secondary)
                Divider()
                SettingsRow("利用可能メモリの目安") {
                    Text(String(format: "%.1f GB", Double(pool.resources.availableBytes) / 1_073_741_824))
                        .monospacedDigit()
                }
                SettingsRow("電源") {
                    Label(pool.resources.onACPower ? "外部電源" : "バッテリー",
                          systemImage: pool.resources.onACPower ? "powerplug" : "battery.100")
                        .labelStyle(.titleAndIcon)
                }
                if pool.resources.lowPower || pool.resources.hot {
                    Text([pool.resources.lowPower ? "低電力モード" : nil,
                          pool.resources.hot ? "高温" : nil].compactMap { $0 }.joined(separator: " · "))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
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
    var active: Bool
    @State private var draft = RequestDraft()
    @State private var generatedDraft: RequestDraft?
    @State private var json = ""
    @State private var response = ""
    @State private var requestError: String?
    @State private var sending = false
    @State private var sendTask: Task<Void, Never>?
    @FocusState private var jsonFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SettingsPage {
                SettingsCard(title: "1. 翻訳する内容") {
                    Text("原文").font(.headline).accessibilityAddTraits(.isHeader)
                    TextEditor(text: $draft.text).font(.body).scrollContentBackground(.hidden)
                        .padding(10).frame(height: 140).modifier(ReadingSurface(cornerRadius: 12))
                        .accessibilityLabel("JSONに含める原文")
                    SettingsRow("原文の言語") {
                        languagePicker("原文の言語", selection: $draft.source, automatic: true).frame(width: 220)
                    }
                    Divider()
                    SettingsRow("訳文の言語") {
                        languagePicker("訳文の言語", selection: $draft.target, automatic: false).frame(width: 220)
                    }
                    if draft.target == "ja" {
                        Divider()
                        SettingsRow("文体") {
                            Picker("文体", selection: $draft.form) {
                                Text("指定なし").tag(""); Text("常体").tag("plain"); Text("敬体").tag("polite")
                            }.pickerStyle(.menu).frame(width: 160)
                        }
                    }
                    Text("コンテキスト（任意）").font(.headline).accessibilityAddTraits(.isHeader)
                    TextEditor(text: $draft.context).font(.body).scrollContentBackground(.hidden)
                        .padding(10).frame(height: 100).modifier(ReadingSurface(cornerRadius: 12))
                        .accessibilityLabel("JSONに含めるコンテキスト")
                }.disabled(sending)
                SettingsCard(title: "生成設定") {
                    SettingsRow("最大生成トークン数") {
                        TextField("最大生成トークン数", text: $draft.maxTokens).frame(width: 120)
                            .help("max_tokens: 1〜32767。入力と生成の合計は32768トークン以内。")
                    }
                    Divider()
                    SettingsRow("Temperature") {
                        TextField("Temperature", text: $draft.temperature).frame(width: 120)
                            .help("0〜2。小数点には「.」を使います。")
                    }
                    Divider()
                    Toggle("辞書を使用", isOn: $draft.useGlossary)
                    Divider()
                    Toggle("ストリーミング", isOn: $draft.stream)
                    if let issue = draft.issue {
                        Label(issue, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    }
                }.disabled(sending)
                SettingsCard(title: "2. 送信するJSON") {
                    HStack {
                        Button("JSONを生成", systemImage: "curlybraces", action: generate)
                            .disabled(sending || draft.issue != nil)
                        Spacer()
                        Button("コピー", systemImage: "doc.on.doc") { copy(json) }
                            .disabled(json.isEmpty).accessibilityLabel("JSONをコピー")
                    }
                    if let generatedDraft, generatedDraft != draft {
                        Label("フォームの変更は未反映です。「JSONを生成」で更新してください。", systemImage: "exclamationmark.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    TextEditor(text: $json).font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden).padding(10).frame(height: 240)
                        .modifier(ReadingSurface(cornerRadius: 12)).accessibilityLabel("送信するJSON（編集可）")
                        .focused($jsonFocused).disabled(sending)
                    Text("このJSONをそのまま送信します。言語・文体を省略した場合は「サーバー」画面の既定値を使います。APIキーはヘッダーに付与し、JSONには含めません。")
                        .font(.callout).foregroundStyle(.secondary)
                    if let requestError {
                        Label(requestError, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                if !response.isEmpty {
                    SettingsCard(title: "3. 応答") {
                        InputEditor(text: .constant(response), editable: false,
                                    font: .monospacedSystemFont(ofSize: 13, weight: .regular), accessibilityName: "APIの応答")
                            .frame(height: 240).modifier(ReadingSurface(cornerRadius: 12))
                        Button("応答をコピー", systemImage: "doc.on.doc") { copy(response) }
                    }
                }
                Text("テキスト翻訳専用です。userの本文を翻訳し、system/developerは参考情報として扱います。本文・JSON・応答は保存しません。この画面を離れると送信を中止します。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            HStack(spacing: 16) {
                Button("消去") {
                    draft.text = ""; draft.context = ""; json = ""; response = ""
                    generatedDraft = nil; requestError = nil
                }.disabled(sending || (draft.text.isEmpty && draft.context.isEmpty && json.isEmpty && response.isEmpty))
                VStack(alignment: .leading, spacing: 5) {
                    Text(sending ? "送信中" : server.running ? "送信先" : "サーバーが停止しています")
                        .font(.callout).foregroundStyle(.secondary)
                    Text(server.running ? "POST \(server.baseURL)/chat/completions" : "「サーバー」画面で開始してください。")
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
            .controlSize(.large).padding(20)
        }
        .onChange(of: json) { _, _ in requestError = nil }
        .onDisappear { sendTask?.cancel() }
        .onChange(of: active) { _, active in
            if !active { sendTask?.cancel(); jsonFocused = false }
        }
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
