import Foundation

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

struct TranslationRequest: Encodable {
    var model: String
    var text: String
    var source: String
    var target: String
    var form: String
    var context: String
    var glossary: [[String: String]]
    var max_tokens: Int
    var temperature: Double
}

struct APIError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

/// Only text translation is supported; chat instructions become PFML context.
struct ChatRequest: Decodable {
    struct Message: Decodable {
        let role: String
        let content: String
    }
    struct Term: Decodable {
        let source: String
        let target: String
    }
    let model: String?
    let messages: [Message]
    let stream: Bool?
    struct StreamOptions: Decodable {
        let include_usage: Bool?
    }
    let stream_options: StreamOptions?
    let max_tokens: Int?
    let max_completion_tokens: Int?
    let temperature: Double?
    let source_lang: String?
    let target_lang: String?
    let form: String?
    let context: String?
    let use_glossary: Bool?
    let glossary: [Term]?

    func translation(modelPath: String, source: String, target: String, form defaultForm: String,
                     terms: [[String: String]]) throws -> TranslationRequest {
        guard messages.filter({ $0.role == "user" }).count == 1,
              messages.allSatisfy({ ["user", "system", "developer"].contains($0.role) }),
              let text = messages.first(where: { $0.role == "user" })?.content,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError(status: 400, message: "messagesには1件のuserテキストと、任意のsystem/developerテキストを指定してください。会話履歴・画像・ツールには対応しません。")
        }
        let source = source_lang ?? source
        let target = target_lang ?? target
        let form = self.form ?? (target == "ja" ? defaultForm : "")
        let maxTokens = max_completion_tokens ?? max_tokens ?? 2048
        let temperature = self.temperature ?? 0
        guard Language.all.contains(where: { $0.id == target }),
              source.isEmpty || Language.all.contains(where: { $0.id == source }),
              form.isEmpty || (target == "ja" && ["plain", "polite"].contains(form)),
              (1..<32768).contains(maxTokens), temperature.isFinite, (0...2).contains(temperature) else {
            throw APIError(status: 400, message: "言語・文体・生成設定が不正です。max_tokens: 1〜32767、temperature: 0〜2。")
        }
        let context = (messages.filter { $0.role != "user" }.map(\.content) + [self.context ?? ""])
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        let glossary = self.glossary?.map { ["source": $0.source, "target": $0.target] }
            ?? (use_glossary == false ? [] : terms)
        guard !([text, context] + glossary.flatMap { Array($0.values) }).contains(where: { $0.contains("<|plamo:") }),
              glossary.allSatisfy({ !$0.values.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) }) else {
            throw APIError(status: 400, message: "予約トークン、または空の辞書項目が含まれています。")
        }
        return TranslationRequest(model: modelPath, text: text, source: source, target: target, form: form,
                                  context: context, glossary: glossary, max_tokens: maxTokens, temperature: temperature)
    }
}
