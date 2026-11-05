import AppKit
import SwiftUI

struct ServerView: View {
    @ObservedObject var server: LocalAPIServer
    @ObservedObject var preferences: Preferences
    @ObservedObject var translator: Translator

    var body: some View {
        TabView {
            Form {
                Section("ローカルAPI") {
                    Text("このMacの他アプリやブラウザ拡張から、OpenAI互換APIで翻訳できます。アプリを起動したまま使用してください。")
                        .foregroundStyle(.secondary)
                    TextField("ポート", value: $server.port, format: .number.grouping(.never))
                        .disabled(server.running || server.starting)
                    SecureField("APIキー", text: $server.apiKey).disabled(server.running || server.starting)
                    HStack {
                        Button("APIキーをコピー") { copy(server.apiKey) }
                        Button("キーを再発行") { server.apiKey = UUID().uuidString + UUID().uuidString }
                            .disabled(server.running || server.starting)
                    }
                    LabeledContent("Base URL") {
                        Text(server.baseURL).textSelection(.enabled).font(.system(.body, design: .monospaced))
                        Button("コピー") { copy(server.baseURL) }
                    }
                    Text("接続先のBase URL・APIキーを設定し、モデルには plamo-translate を指定してください。モデル一覧APIのID、または登録した一意のタグも使えます。")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        if server.running {
                            Text("受付中 · 完了 \(server.completed)件")
                            Button("サーバーを停止", action: server.stop)
                        } else if server.starting {
                            ProgressView().controlSize(.small)
                            Text("起動中")
                            Button("中止", action: server.stop)
                        } else {
                            Text("停止中").foregroundStyle(.secondary)
                            Button("サーバーを開始", action: server.start).buttonStyle(.borderedProminent)
                        }
                    }
                    if let error = server.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }
                Section("翻訳の既定値") {
                    Picker("モデル", selection: $server.modelID) {
                        Text("設定のデフォルト").tag(nil as UUID?)
                        ForEach(preferences.models) { Text($0.tag).tag(Optional($0.id)) }
                    }
                    languagePicker("原文", selection: $server.source, automatic: true)
                    languagePicker("訳文", selection: $server.target, automatic: false)
                    if server.target == "ja" {
                        Picker("文体", selection: $server.form) {
                            Text("指定なし").tag(""); Text("常体").tag("plain"); Text("敬体").tag("polite")
                        }
                    }
                    Picker("自動解放", selection: $preferences.unloadSeconds) {
                        Text("完了後すぐ").tag(0); Text("1分後").tag(60); Text("5分後").tag(300)
                        Text("15分後").tag(900); Text("30分後").tag(1800); Text("アプリ終了時").tag(-1)
                    }
                    HStack {
                        if translator.busy || translator.loaded { Circle().fill(.green).frame(width: 7, height: 7) }
                        Text(translator.busy ? (translator.servingAPI ? "API: " : "翻訳画面: ") + translator.status : translator.loaded ? "モデル読み込み済み" : "モデル未読み込み")
                        Spacer()
                        if translator.busy && translator.servingAPI { Button("翻訳を中止", action: translator.cancel) }
                        Button("モデルを解放", action: translator.unload).disabled(!translator.loaded || translator.busy)
                    }
                    if translator.busy, let startedAt = translator.startedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { clock in
                            Text("経過 \(Int(max(0, clock.date.timeIntervalSince(startedAt))))秒")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    if let metrics = translator.metrics {
                        Text("直近の翻訳: \(metrics.tokens ?? 0) tokens · \(String(format: "%.1f", metrics.tps ?? 0)) token/s" +
                             (metrics.elapsed.map { String(format: " · %.2f秒", $0) } ?? ""))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text("リクエスト時だけロードし、完了後の無通信時間で解放します。次のリクエストで再ロードします。通常の翻訳画面とモデルを共有し、実行中の追加リクエストには429を返します。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("接続", systemImage: "network") }
            RequestBuilderView(server: server)
                .tabItem { Label("リクエストJSON", systemImage: "curlybraces") }
        }
        .padding(12)
        .frame(minWidth: 720, minHeight: 700)
        .preferredColorScheme(.light)
    }
}

private struct RequestBuilderView: View {
    @ObservedObject var server: LocalAPIServer
    @State private var text = ""
    @State private var context = ""
    @State private var source = ""
    @State private var target = "ja"
    @State private var form = ""
    @State private var useGlossary = true
    @State private var maxTokens = 2048
    @State private var temperature = 0.0
    @State private var stream = true
    @State private var json = ""
    @State private var response = ""
    @State private var sending = false
    @State private var sendTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("POST \(server.baseURL)/chat/completions").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Text("Authorization: Bearer <APIキー> · Content-Type: application/json")
                    .font(.caption).foregroundStyle(.secondary)
                Text("原文").font(.headline)
                TextEditor(text: $text).frame(height: 90).border(.quaternary)
                    .accessibilityLabel("JSONに含める原文")
                HStack {
                    languagePicker("原文", selection: $source, automatic: true)
                    languagePicker("訳文", selection: $target, automatic: false)
                    if target == "ja" {
                        Picker("文体", selection: $form) {
                            Text("指定なし").tag(""); Text("常体").tag("plain"); Text("敬体").tag("polite")
                        }
                    }
                }
                Text("コンテキスト（任意）").font(.headline)
                TextEditor(text: $context).frame(height: 60).border(.quaternary).accessibilityLabel("JSONのコンテキスト")
                HStack {
                    TextField("Max tokens", value: $maxTokens, format: .number.grouping(.never))
                    TextField("Temperature", value: $temperature, format: .number)
                    Toggle("辞書", isOn: $useGlossary)
                    Toggle("ストリーミング", isOn: $stream)
                }.textFieldStyle(.roundedBorder)
                Text("userの本文を翻訳します。system/developerは翻訳の参考情報として扱い、会話や任意の指示実行には対応しません。言語・文体は専用フィールドで指定してください。省略時は「接続」タブの既定値を使います。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("JSONを生成", action: generate)
                    Button("JSONをコピー") { copy(json) }.disabled(json.isEmpty)
                    Spacer()
                    if sending {
                        ProgressView().controlSize(.small)
                        Button("中止") { sendTask?.cancel() }
                    } else {
                        Button("送信して試す", action: send).disabled(!server.running || json.isEmpty)
                    }
                    Button("消去") { text = ""; context = ""; json = ""; response = "" }.disabled(sending)
                }
                Text("送信するJSON（編集可）").font(.headline)
                TextEditor(text: $json).font(.system(.body, design: .monospaced)).frame(height: 190)
                    .border(.quaternary).accessibilityLabel("送信するJSON")
                Text("フォームの変更は「JSONを生成」で反映します。APIキーはJSONに含めません。本文・JSON・応答は保存しません。")
                    .font(.caption).foregroundStyle(.secondary)
                if !response.isEmpty {
                    Text("応答").font(.headline)
                    TextEditor(text: .constant(response)).font(.system(.caption, design: .monospaced))
                        .frame(height: 180).border(.quaternary).accessibilityLabel("APIの応答")
                    Button("応答をコピー") { copy(response) }
                }
            }.padding(16)
        }
        .onDisappear { sendTask?.cancel() }
    }

    private func generate() {
        let value: [String: Any] = [
            "model": "plamo-translate", "messages": [["role": "user", "content": text]],
            "source_lang": source, "target_lang": target, "form": target == "ja" ? form : "",
            "context": context, "use_glossary": useGlossary,
            "max_tokens": maxTokens, "temperature": temperature, "stream": stream
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            json = String(decoding: data, as: UTF8.self)
        } catch { response = error.localizedDescription }
    }

    private func send() {
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
