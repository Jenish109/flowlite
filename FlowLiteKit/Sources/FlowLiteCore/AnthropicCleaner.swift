import Foundation

public protocol Cleaning: Sendable {
    func clean(_ request: CleanRequest) async throws -> String
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

public enum CleanerError: Error, Equatable {
    case missingAPIKey
    case http(status: Int, body: String)
    case refusal
    /// The reply ended for a reason other than finishing (e.g. `max_tokens`); `"none"` if absent.
    case truncated(stopReason: String)
    case emptyResponse
}

/// Calls Claude Haiku through the Messages API. Swift has no official Anthropic SDK, so this is raw HTTPS.
public struct AnthropicCleaner: Cleaning {
    public static let model = "claude-haiku-5-5"
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    private let apiKey: @Sendable () -> String?
    private let transport: HTTPTransport

    public init(apiKey: @escaping @Sendable () -> String?, transport: HTTPTransport = URLSessionTransport()) {
        self.apiKey = apiKey
        self.transport = transport
    }

    public func clean(_ request: CleanRequest) async throws -> String {
        guard let key = apiKey(), !key.isEmpty else { throw CleanerError.missingAPIKey }
        let (data, response) = try await transport.send(try makeURLRequest(request, apiKey: key))
        return try Self.parse(data: data, status: response.statusCode)
    }

    func makeURLRequest(_ request: CleanRequest, apiKey: String) throws -> URLRequest {
        var urlRequest = URLRequest(url: Self.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 30
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.httpBody = try JSONEncoder().encode(Body(request))
        return urlRequest
    }

    struct Body: Encodable {
        struct Thinking: Encodable { let type = "disabled" }
        struct OutputConfig: Encodable { let effort = "low" }
        struct SystemBlock: Encodable {
            let type = "text"
            let text: String
        }
        struct Message: Encodable {
            let role = "user"
            let content: String
        }

        let model = AnthropicCleaner.model
        let max_tokens: Int
        let thinking = Thinking()
        let output_config = OutputConfig()
        let system: [SystemBlock]
        let messages: [Message]

        init(_ request: CleanRequest) {
            max_tokens = request.maxTokens
            system = [SystemBlock(text: request.system)]
            messages = [Message(content: request.user)]
        }
    }

    struct Response: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let content: [Block]
        let stop_reason: String?
    }

    static func parse(data: Data, status: Int) throws -> String {
        guard (200..<300).contains(status) else {
            throw CleanerError.http(status: status, body: String(decoding: data.prefix(500), as: UTF8.self))
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        switch response.stop_reason {
        case "end_turn", "stop_sequence": break
        case "refusal": throw CleanerError.refusal
        case let other: throw CleanerError.truncated(stopReason: other ?? "none")
        }
        let text = response.content
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CleanerError.emptyResponse }
        return text
    }
}
