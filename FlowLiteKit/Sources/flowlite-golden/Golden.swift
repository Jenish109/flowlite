import Foundation
import FlowLiteCore
import FlowLiteSystem
import WhisperKit

struct GoldenCase: Decodable {
    let audio: String
    let app: String
    let bundleID: String
    let before: String?
    let expected: String
}

/// Runs recorded clips through transcription and cleanup and compares with expected text.
/// Usage: flowlite-golden <dir containing cases.json> [--no-clean]
@main
struct Golden {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2 else {
            print("usage: flowlite-golden <dir containing cases.json> [--no-clean]")
            exit(2)
        }
        let directory = URL(fileURLWithPath: arguments[1])
        let clean = !arguments.contains("--no-clean")
        let cases = try JSONDecoder().decode([GoldenCase].self,
                                             from: Data(contentsOf: directory.appendingPathComponent("cases.json")))

        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FlowLite")
        let store = try? FlowStore(path: support.appendingPathComponent("flowlite.sqlite").path)
        let vocabulary = (try? store?.vocabulary()) ?? []
        let rules = (try? store?.replacementRules()) ?? []
        let model = UserDefaults(suiteName: "dev.flowlite.app")?.string(forKey: "model") ?? WhisperTranscriber.defaultModel
        let strength = UserDefaults(suiteName: "dev.flowlite.app")?.string(forKey: "editingStrength")
            .flatMap(EditingStrength.init(rawValue:)) ?? .standard
        let transcriber = WhisperTranscriber(model: model, modelsDirectory: support.appendingPathComponent("Models"))
        await transcriber.load { state in print("model: \(state)") }
        guard await transcriber.isReady else {
            print("speech model failed to load")
            exit(1)
        }

        let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
        if clean && (apiKey ?? "").isEmpty {
            print("ANTHROPIC_API_KEY is not set; pass --no-clean to test transcription only")
            exit(2)
        }
        let cleaner = AnthropicCleaner(apiKey: { apiKey })

        var matches = 0
        for golden in cases {
            do {
                let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: directory.appendingPathComponent(golden.audio).path)
                let transcribeStart = Date()
                let raw = try await transcriber.transcribe(samples, vocabulary: vocabulary)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let transcribeMs = Int(Date().timeIntervalSince(transcribeStart) * 1000)

                var final = raw
                var cleanMs = 0
                // Like the app, skip cleanup for very short dictations.
                if clean, raw.split(whereSeparator: \.isWhitespace).count > 2 {
                    let context = DictationContext(appName: golden.app, bundleID: golden.bundleID, beforeText: golden.before ?? "")
                    let cleanStart = Date()
                    final = try await cleaner.clean(PromptBuilder.dictation(raw: raw, context: context, vocabulary: vocabulary,
                                                                       strength: strength))
                    cleanMs = Int(Date().timeIntervalSince(cleanStart) * 1000)
                }
                final = ReplacementEngine.apply(rules, to: final)
                let match = final == golden.expected
                if match { matches += 1 }
                print("\n=== \(golden.audio) [\(golden.app)] \(match ? "MATCH" : "DIFF") — transcribe \(transcribeMs) ms, clean \(cleanMs) ms")
                print("raw:      \(raw)")
                print("final:    \(final)")
                print("expected: \(golden.expected)")
            } catch {
                print("\n=== \(golden.audio) [\(golden.app)] ERROR: \(error)")
            }
        }
        print("\n\(matches)/\(cases.count) exact matches")
    }
}
