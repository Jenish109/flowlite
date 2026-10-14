import Foundation
import Testing
@testable import FlowLiteCore

final class FakeTransport: HTTPTransport, @unchecked Sendable {
    var status = 200
    var responseBody = Data()
    private(set) var requests: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (responseBody, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite struct AnthropicCleanerTests {
    let request = CleanRequest(system: "SYS", user: "USER", maxTokens: 200)

    func body(_ json: String) -> Data { Data(json.utf8) }

    @Test func buildsHaikuRequest() async throws {
        let transport = FakeTransport()
        transport.responseBody = body(#"{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}"#)
        let cleaner = AnthropicCleaner(apiKey: { "sk-test" }, transport: transport)
        _ = try await cleaner.clean(request)

        let sent = try #require(transport.requests.first)
        #expect(sent.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(sent.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(sent.value(forHTTPHeaderField: "content-type") == "application/json")

        let json = try #require(try JSONSerialization.jsonObject(with: sent.httpBody!) as? [String: Any])
        #expect(json["model"] as? String == "claude-haiku-5-5")
        #expect(json["max_tokens"] as? Int == 200)
        #expect(json["temperature"] == nil)
        #expect((json["thinking"] as? [String: Any])?["type"] as? String == "disabled")
        #expect((json["output_config"] as? [String: Any])?["effort"] as? String == "low")
        let system = try #require(json["system"] as? [[String: Any]])
        #expect(system.first?["text"] as? String == "SYS")
        #expect(system.first?["type"] as? String == "text")
        #expect(system.first?["cache_control"] == nil) // prompt is below the cacheable minimum
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.first?["role"] as? String == "user")
        #expect(messages.first?["content"] as? String == "USER")
    }

    @Test func returnsOnlyTextBlocksTrimmed() async throws {
        let transport = FakeTransport()
        transport.responseBody = body(#"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"  Hello there.\n"}],"stop_reason":"end_turn"}"#)
        let result = try await AnthropicCleaner(apiKey: { "k" }, transport: transport).clean(request)
        #expect(result == "Hello there.")
    }

    @Test func refusalIsAnError() async {
        let transport = FakeTransport()
        transport.responseBody = body(#"{"content":[],"stop_reason":"refusal"}"#)
        await #expect(throws: CleanerError.refusal) {
            try await AnthropicCleaner(apiKey: { "k" }, transport: transport).clean(request)
        }
    }

    @Test func maxTokensCutIsAnError() async {
        let transport = FakeTransport()
        transport.responseBody = body(#"{"content":[{"type":"text","text":"Half a sen"}],"stop_reason":"max_tokens"}"#)
        await #expect(throws: CleanerError.truncated(stopReason: "max_tokens")) {
            try await AnthropicCleaner(apiKey: { "k" }, transport: transport).clean(request)
        }
    }

    @Test func missingStopReasonIsAnError() async {
        let transport = FakeTransport()
        transport.responseBody = body(#"{"content":[{"type":"text","text":"ok"}],"stop_reason":null}"#)
        await #expect(throws: CleanerError.truncated(stopReason: "none")) {
            try await AnthropicCleaner(apiKey: { "k" }, transport: transport).clean(request)
        }
    }

    @Test func stopSequenceIsAccepted() async throws {
        let transport = FakeTransport()
        transport.responseBody = body(#"{"content":[{"type":"text","text":"ok"}],"stop_reason":"stop_sequence"}"#)
        #expect(try await AnthropicCleaner(apiKey: { "k" }, transport: transport).clean(request) == "ok")
    }

    @Test func emptyTextIsAnError() async {
        let transport = FakeTransport()
        transport.responseBody = body(#"{"content":[{"type":"text","text":"   "}],"stop_reason":"end_turn"}"#)
        await #expect(throws: CleanerError.emptyResponse) {
            try await AnthropicCleaner(apiKey: { "k" }, transport: transport).clean(request)
        }
    }

    @Test func httpErrorsCarryStatus() async {
        let transport = FakeTransport()
        transport.status = 529
        transport.responseBody = body(#"{"type":"error"}"#)
        await #expect(throws: CleanerError.http(status: 529, body: #"{"type":"error"}"#)) {
            try await AnthropicCleaner(apiKey: { "k" }, transport: transport).clean(request)
        }
    }

    @Test func missingKeyFailsWithoutNetwork() async {
        let transport = FakeTransport()
        await #expect(throws: CleanerError.missingAPIKey) {
            try await AnthropicCleaner(apiKey: { nil }, transport: transport).clean(request)
        }
        #expect(transport.requests.isEmpty)
    }
}
