import AppKit
import SwiftUI

struct ServerSettingsView: View {
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
        guard validPort else { return "ポートは1024〜65535の整数で指定してください。" }
        guard server.apiKey.count >= 16, server.apiKey.utf8.allSatisfy({ (33...126).contains($0) }) else {
            return "APIキーは空白を含まない半角16文字以上で指定してください。"
        }
        return nil
    }

    private var serverSummary: String {
        if server.starting { return "接続の準備をしています。" }
        if server.running { return "127.0.0.1:\(server.port) で接続を受け付けています。" }
        return "翻訳用ローカルAPIサーバを開始します。"
    }

    var body: some View {
        connectionSettings
            .onChange(of: portText) { _, value in
                if let port = Int(value), (1024...65535).contains(port) { server.port = port }
            }
            .onChange(of: server.port) { _, value in portText = String(value) }
            .onChange(of: preferences.models, initial: true) { _, models in
                if let id = server.modelID, !models.contains(where: { $0.id == id }) { server.modelID = nil }
            }
    }

    private var connectionSettings: some View {
        SettingsPage(title: "ローカルAPI", description: "翻訳用ローカルAPIサーバを管理します。") {
            SettingsCard(title: "") {
                HStack(alignment: .center, spacing: 16) {
                    SettingsIcon(symbol: "network", size: 44)
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 9) {
                            Text("Kotoba Translate API")
                                .font(.system(size: 17, weight: .semibold))
                            StatusBadge(text: server.running ? "受付中" : server.starting ? "起動中" : "停止中",
                                        tone: server.running ? .active : server.starting ? .busy : .neutral)
                        }
                        Text(serverSummary)
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
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
                SettingsFootnote(text: "この端末内からのみ接続することができます。利用中はアプリを終了しないでください。", symbol: "lock.shield")
                if let error = server.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).textSelection(.enabled)
                        .font(.system(size: 12))
                }
            }
            SettingsCard(title: "接続するアプリに設定する値", symbol: "link") {
                SettingsRow("Base URL") {
                    CodeValue(text: server.baseURL).layoutPriority(1)
                    Button { copy(server.baseURL) } label: { Image(systemName: "doc.on.doc") }
                        .accessibilityLabel("Base URLをコピー").help("Base URLをコピー").disabled(!validPort)
                }
                Divider()
                SettingsRow("モデル名") {
                    CodeValue(text: "plamo-translate")
                    Button { copy("plamo-translate") } label: { Image(systemName: "doc.on.doc") }
                        .accessibilityLabel("モデル名をコピー").help("モデル名をコピー")
                }
                SettingsFootnote(text: "OpenAI互換APIに対応したアプリに、Base URL・APIキー・モデル名を入力してください。登録した一意のタグや、モデル一覧APIのIDも指定することができます。", symbol: "info.circle")
            }
            SettingsCard(title: "接続設定", symbol: "lock") {
                SettingsRow("ポート", description: "127.0.0.1に限定して接続を受け付けます。") {
                    TextField("ポート", text: $portText).frame(width: 100)
                        .disabled(server.running || server.starting).help("1024〜65535")
                }
                Divider()
                SettingsRow("APIキー") {
                    SecureField("APIキー", text: $server.apiKey).frame(maxWidth: 300)
                        .disabled(server.running || server.starting)
                }
                HStack(spacing: 10) {
                    Text("接続設定は停止中にのみ変更できます。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("コピー") { copy(server.apiKey) }.disabled(server.apiKey.isEmpty)
                        .accessibilityLabel("APIキーをコピー")
                    Button("再発行") { server.apiKey = UUID().uuidString + UUID().uuidString }
                        .disabled(server.running || server.starting)
                        .help("接続するアプリのAPIキーも更新してください。")
                        .accessibilityLabel("APIキーを再発行")
                }
                if let issue = connectionIssue {
                    SettingsFootnote(text: issue, symbol: "exclamationmark.circle")
                }
            }
            SettingsCard(title: "翻訳の既定値", symbol: "globe") {
                SettingsRow("モデル") {
                    SelectField(title: "モデル", selection: $server.modelID,
                                options: [SelectOption<UUID?>(value: nil, label: "設定のデフォルト")]
                                    + preferences.models.map { SelectOption(value: Optional($0.id), label: $0.tag) },
                                width: 280)
                }
                if preferences.models.isEmpty {
                    SettingsFootnote(text: "翻訳には、設定画面でモデルを登録してください。", symbol: "info.circle")
                }
                Divider()
                SettingsRow("原文の言語") {
                    languagePicker("原文の言語", selection: $server.source, automatic: true)
                }
                Divider()
                SettingsRow("訳文の言語") {
                    languagePicker("訳文の言語", selection: $server.target, automatic: false)
                }
                if server.target == "ja" {
                    Divider()
                    SettingsRow("文体") {
                        SelectField(title: "文体", selection: $server.form,
                                    options: [SelectOption(value: "", label: "指定なし"),
                                              SelectOption(value: "plain", label: "常体"),
                                              SelectOption(value: "polite", label: "敬体")],
                                    width: 160)
                    }
                }
                SettingsFootnote(text: "リクエストに言語・文体の指示がない場合に使用されます。", symbol: "info.circle")
            }
            ServerCapacityView(pool: server.inference)
            sharedModelSettings
        }
    }

    private var sharedModelSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "共有モデル", symbol: "memorychip") {
                SettingsRow("状態") {
                    HStack(spacing: 7) {
                        Circle().fill(translator.busy || translator.loaded ? Color.green : Color.secondary.opacity(0.5))
                            .frame(width: 8, height: 8).accessibilityHidden(true)
                        Text(translator.busy ? (translator.servingAPI ? "API: " : "翻訳画面: ") + translator.status : translator.loaded ? "読み込み済み" : "未読み込み")
                    }
                }
                if let path = translator.loadedModelPath,
                   let model = preferences.models.first(where: { $0.path == path }) {
                    SettingsRow("モデル") { Text(model.tag).textSelection(.enabled) }
                }
                Divider()
                SettingsRow("自動解放", hideControlLabels: false) {
                    ModelUnloadControl(preferences: preferences)
                }
                SettingsRow("モデルの操作") {
                    Button("モデルを解放", systemImage: "eject", action: translator.unload)
                        .disabled(!translator.loaded || translator.busy).help("共有モデルをメモリから解放")
                    if translator.busy && translator.servingAPI {
                        Button("翻訳を中止", action: translator.cancel)
                    }
                }
                SettingsFootnote(text: "翻訳完了からの時間を分単位で指定します。0分に設定すると翻訳完了後即座に解放されます。この設定はアプリ内の翻訳とローカルAPIで共有されます。混雑時に並列実行するモデルは翻訳完了30秒後に解放されます。", symbol: "clock")
            }
            if translator.busy || translator.metrics != nil || !server.lastTimings.isEmpty {
                SettingsCard(title: "計測情報", symbol: "chart.bar") {
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
                        .help("待機時間やPythonの起動時間を含みます。入力処理・生成はMLXの速度から算出しています。")
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
            SettingsCard(title: "混雑時の処理", symbol: "speedometer") {
                SettingsRow("最大並列数") {
                    SelectField(title: "最大並列数", selection: $pool.maxConcurrency,
                                options: (1...4).map { SelectOption(value: $0, label: "\($0)件") },
                                width: 160)
                }
                Divider()
                SettingsRow("バッテリー時", description: "バッテリー駆動中も並列数を増やすことを許可します。") {
                    Toggle("バッテリー駆動中も並列数を増やす", isOn: $pool.allowBattery)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                Divider()
                SettingsRow("メモリの余裕") {
                    SelectField(title: "確保するメモリの余裕", selection: $pool.reserveGB,
                                options: [2, 4, 8, 12, 16].map { SelectOption(value: $0, label: "\($0) GB") },
                                width: 160)
                }
                DisclosureGroup("並列処理について") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("通常は1並列。最大32件を待機させ、電源・温度・メモリの状態に応じて並列数が自動で調整されます。低電力モードに設定されている場合や端末が高温のとき、メモリの空きが少ない場合には1並列となります。")
                        Text("並列数を増やすごとにモデル用メモリが必要になるため、競合して結果的に翻訳完了が遅くなる場合があります。GPU・メモリの使用率および翻訳が完了するまでの時間を確認しながら調整してください。")
                    }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 8)
                }
            }
            SettingsCard(title: "現在の処理状況", symbol: "waveform.path.ecg") {
                HStack(spacing: 10) {
                    StatTile(title: "実行中", value: "\(pool.activeCount)件", symbol: "bolt.fill")
                    StatTile(title: "待機中", value: "\(pool.waitingCount)件", symbol: "clock")
                    StatTile(title: "読み込み済み", value: "\(pool.loadedCount)個", symbol: "square.stack.3d.up")
                }
                HStack(spacing: 10) {
                    Button("実行中を中止", action: pool.cancelActive).disabled(pool.activeCount == 0)
                    Button("待機モデルを解放", action: pool.unloadIdle).disabled(pool.loadedCount == 0)
                }
                SettingsFootnote(text: pool.reason, symbol: "info.circle")
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
                    SettingsFootnote(text: [pool.resources.lowPower ? "低電力モード" : nil,
                                            pool.resources.hot ? "高温" : nil].compactMap { $0 }.joined(separator: " · "),
                                     symbol: "thermometer.medium")
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
    var maxTokens = "4096"
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

struct RequestBuilderView: View {
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
            SettingsPage(title: "リクエストを試す", description: "ローカルAPIにリクエストするためのJSONを作成し、試すことができます。") {
                SettingsCard(title: "翻訳する内容", symbol: "1.circle.fill") {
                    Text("原文").font(.system(size: 13, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    TextEditor(text: $draft.text).font(.body).scrollContentBackground(.hidden)
                        .padding(10).frame(height: 140)
                        .modifier(ReadingSurface(cornerRadius: 12, fill: KotobaTheme.well))
                        .accessibilityLabel("JSONに含める原文")
                    SettingsRow("原文の言語") {
                        languagePicker("原文の言語", selection: $draft.source, automatic: true)
                    }
                    Divider()
                    SettingsRow("訳文の言語") {
                        languagePicker("訳文の言語", selection: $draft.target, automatic: false)
                    }
                    if draft.target == "ja" {
                        Divider()
                        SettingsRow("文体") {
                            SelectField(title: "文体", selection: $draft.form,
                                        options: [SelectOption(value: "", label: "指定なし"),
                                                  SelectOption(value: "plain", label: "常体"),
                                                  SelectOption(value: "polite", label: "敬体")],
                                        width: 160)
                        }
                    }
                    Text("コンテキスト（任意）").font(.system(size: 13, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    TextEditor(text: $draft.context).font(.body).scrollContentBackground(.hidden)
                        .padding(10).frame(height: 100)
                        .modifier(ReadingSurface(cornerRadius: 12, fill: KotobaTheme.well))
                        .accessibilityLabel("JSONに含めるコンテキスト")
                }.disabled(sending)
                SettingsCard(title: "生成設定", symbol: "slider.horizontal.3") {
                    SettingsRow("最大生成トークン数") {
                        TextField("最大生成トークン数", text: $draft.maxTokens).frame(width: 120)
                            .multilineTextAlignment(.trailing)
                            .help("max_tokens: 1〜32767。入力と生成の合計は32768トークン以内。")
                    }
                    Divider()
                    SettingsRow("Temperature") {
                        TextField("Temperature", text: $draft.temperature).frame(width: 120)
                            .multilineTextAlignment(.trailing)
                            .help("0〜2。小数点には「.」を使います。")
                    }
                    Divider()
                    Toggle("辞書を使用", isOn: $draft.useGlossary)
                    Divider()
                    Toggle("ストリーミング", isOn: $draft.stream)
                    if let issue = draft.issue {
                        SettingsFootnote(text: issue, symbol: "info.circle")
                    }
                }.disabled(sending)
                SettingsCard(title: "送信するJSON", symbol: "2.circle.fill") {
                    HStack {
                        Button("JSONを生成", systemImage: "curlybraces", action: generate)
                            .disabled(sending || draft.issue != nil)
                        Spacer()
                        Button("コピー", systemImage: "doc.on.doc") { copy(json) }
                            .disabled(json.isEmpty).accessibilityLabel("JSONをコピー")
                    }
                    if let generatedDraft, generatedDraft != draft {
                        SettingsFootnote(text: "フォームの変更は未反映です。「JSONを生成」で更新してください。", symbol: "exclamationmark.circle")
                    }
                    TextEditor(text: $json).font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden).padding(10).frame(height: 240)
                        .modifier(ReadingSurface(cornerRadius: 12, fill: KotobaTheme.well))
                        .accessibilityLabel("送信するJSON（編集可）")
                        .focused($jsonFocused).disabled(sending)
                    SettingsFootnote(text: "言語・文体を省略した場合は「ローカルAPI」画面の既定値を使います。", symbol: "info.circle")
                    if let requestError {
                        Label(requestError, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                if !response.isEmpty {
                    SettingsCard(title: "応答", symbol: "3.circle.fill") {
                        InputEditor(text: .constant(response), editable: false,
                                    font: .monospacedSystemFont(ofSize: 12, weight: .regular), accessibilityName: "APIの応答")
                            .frame(height: 240).modifier(ReadingSurface(cornerRadius: 12, fill: KotobaTheme.well))
                        Button("応答をコピー", systemImage: "doc.on.doc") { copy(response) }
                    }
                }
                SettingsFootnote(text: "テキスト翻訳専用です。userの本文を翻訳し、system/developerは参考情報として扱います。この画面を離れると送信を中止します。", symbol: "info.circle")
            }
            Divider()
            HStack(spacing: 16) {
                Button("消去") {
                    draft.text = ""; draft.context = ""; json = ""; response = ""
                    generatedDraft = nil; requestError = nil
                }.disabled(sending || (draft.text.isEmpty && draft.context.isEmpty && json.isEmpty && response.isEmpty))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(sending ? KotobaTheme.accent : server.running ? Color.green : Color.secondary.opacity(0.5))
                            .frame(width: 6, height: 6).accessibilityHidden(true)
                        Text(sending ? "送信中" : server.running ? "送信先" : "サーバーが停止しています")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    }
                    Text(server.running ? "POST \(server.baseURL)/chat/completions" : "「ローカルAPI」画面で開始してください。")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
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
            .controlSize(.large)
            .frame(maxWidth: 880)
            .padding(.horizontal, 28).padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .top) { Divider() }
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
    SelectField(title: title, selection: selection,
                options: (automatic ? [SelectOption(value: "", label: "自動検出")] : [])
                    + Language.all.map { SelectOption(value: $0.id, label: $0.name) },
                width: 220)
}

private func copy(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
}
