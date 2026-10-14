import Foundation
import Testing
@testable import FlowLiteCore

// MARK: Fakes

final class FakeRecorder: AudioRecording {
    var audio = RecordedAudio(samples: Array(repeating: 0.1, count: 16_000)) // 1 s, audible
    var failStart = false
    private(set) var starts = 0
    private(set) var cancels = 0

    func start() throws {
        if failStart { throw Boom() }
        starts += 1
    }
    func stop() -> RecordedAudio { audio }
    func cancel() { cancels += 1 }
}

struct FakeContextReader: ContextReading {
    var context: DictationContext
    func snapshot() async -> DictationContext { context }
}

struct HungContextReader: ContextReading {
    func snapshot() async -> DictationContext {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        return DictationContext(appName: "Late")
    }
}

struct HungTranscriber: Transcribing {
    func transcribe(_ samples: [Float], vocabulary: [String]) async throws -> String {
        try await Task.sleep(nanoseconds: 5_000_000_000)
        return "too late"
    }
}

struct FakeTranscriber: Transcribing {
    var result: Result<String, Boom>
    func transcribe(_ samples: [Float], vocabulary: [String]) async throws -> String { try result.get() }
}

struct FakeCleaner: Cleaning {
    var handler: @Sendable (CleanRequest) async throws -> String
    func clean(_ request: CleanRequest) async throws -> String { try await handler(request) }
}

actor FakeInserter: TextInserting {
    private(set) var inserted: [String] = []
    let method: InsertMethod
    init(method: InsertMethod = .ax) { self.method = method }
    func insert(_ text: String) async -> InsertMethod {
        inserted.append(text)
        return method
    }
}

@MainActor
final class FakeOverlay: OverlayPresenting {
    private(set) var states: [OverlayState] = []
    func show(_ state: OverlayState) { states.append(state) }
}

final class CallCounter: @unchecked Sendable { var count = 0 }
final class RequestBox: @unchecked Sendable { var system: String? }

// MARK: Harness

@MainActor
struct Harness {
    let coordinator: DictationCoordinator
    let recorder: FakeRecorder
    let inserter: FakeInserter
    let overlay: FakeOverlay
    let store: FlowStore

    init(context: DictationContext = DictationContext(appName: "Notes", bundleID: "com.apple.Notes"),
         transcript: Result<String, Boom> = .success(" hello there how are you "),
         cleaner: @escaping @Sendable (CleanRequest) async throws -> String = { _ in "Hello there, how are you?" },
         settings: CoordinatorSettings = CoordinatorSettings(),
         recorder: FakeRecorder = FakeRecorder(),
         inserter: FakeInserter = FakeInserter(),
         contextReader: ContextReading? = nil,
         transcriber: Transcribing? = nil,
         archive: RecordingArchive? = nil) throws {
        self.recorder = recorder
        self.inserter = inserter
        overlay = FakeOverlay()
        store = try FlowStore.inMemory()
        coordinator = DictationCoordinator(
            recorder: recorder,
            contextReader: contextReader ?? FakeContextReader(context: context),
            transcriber: transcriber ?? FakeTranscriber(result: transcript),
            cleaner: FakeCleaner(handler: cleaner),
            inserter: inserter,
            store: store,
            overlay: overlay,
            archive: archive,
            settings: { settings })
    }

    func run(_ actions: HotkeyAction...) async {
        for action in actions { coordinator.handle(action) }
        let task = coordinator.processingTask
        await task?.value
    }
}

// MARK: Tests

@Suite @MainActor struct DictationCoordinatorTests {
    @Test func dictationInsertsCleanedTextAndRecordsHistory() async throws {
        let h = try Harness()
        await h.run(.dictateStart, .dictateStop)
        #expect(await h.inserter.inserted == ["Hello there, how are you?"])
        let record = try #require(try h.store.recent().first)
        #expect(record.rawText == "hello there how are you")
        #expect(record.finalText == "Hello there, how are you?")
        #expect(record.insertMethod == "ax")
        #expect(!record.cleanupFailed)
        #expect(record.appName == "Notes")
        #expect(record.audioMs == 1_000)
        #expect(h.overlay.states == [.recording(command: false), .processing, .hidden])
    }

    @Test func cleanerFailureFallsBackToRawTranscript() async throws {
        let h = try Harness(cleaner: { _ in throw Boom() })
        await h.run(.dictateStart, .dictateStop)
        #expect(await h.inserter.inserted == ["hello there how are you"])
        #expect(try h.store.recent().first?.cleanupFailed == true)
        #expect(h.overlay.states.last == .message("Inserted without cleanup"))
    }

    @Test func slowCleanerTimesOutToRawTranscript() async throws {
        let h = try Harness(cleaner: { _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return "too late"
        })
        h.coordinator.dictationTimeout = { _ in 0.05 }
        let start = ContinuousClock.now
        await h.run(.dictateStart, .dictateStop)
        #expect(await h.inserter.inserted == ["hello there how are you"])
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func cleanupDisabledInsertsRaw() async throws {
        let calls = CallCounter()
        let h = try Harness(cleaner: { _ in calls.count += 1; return "x" },
                            settings: CoordinatorSettings(cleanupEnabled: false))
        await h.run(.dictateStart, .dictateStop)
        #expect(await h.inserter.inserted == ["hello there how are you"])
        #expect(calls.count == 0)
    }

    @Test func editingStrengthReachesCleaner() async throws {
        let seen = RequestBox()
        let h = try Harness(cleaner: { seen.system = $0.system; return "x" },
                            settings: CoordinatorSettings(editingStrength: .light))
        await h.run(.dictateStart, .dictateStop)
        #expect(seen.system == PromptBuilder.dictationSystemPrompt(.light))
        #expect(CoordinatorSettings().editingStrength == .standard)
    }

    @Test func shortUtteranceSkipsCleanup() async throws {
        let calls = CallCounter()
        let h = try Harness(transcript: .success("yes"), cleaner: { _ in calls.count += 1; return "x" })
        await h.run(.dictateStart, .dictateStop)
        #expect(await h.inserter.inserted == ["yes"])
        #expect(calls.count == 0)
    }

    @Test func tooShortAudioIsDiscarded() async throws {
        let recorder = FakeRecorder()
        recorder.audio = RecordedAudio(samples: Array(repeating: 0.1, count: 1_600)) // 100 ms
        let h = try Harness(recorder: recorder)
        await h.run(.dictateStart, .dictateStop)
        #expect(await h.inserter.inserted.isEmpty)
        #expect(try h.store.recent().isEmpty)
        #expect(h.overlay.states.last == .hidden)
    }

    @Test func silentAudioIsDiscarded() async throws {
        let recorder = FakeRecorder()
        recorder.audio = RecordedAudio(samples: Array(repeating: 0, count: 16_000))
        let h = try Harness(recorder: recorder)
        await h.run(.dictateStart, .dictateStop)
        #expect(await h.inserter.inserted.isEmpty)
    }

    @Test func replacementsAndSpacingAreApplied() async throws {
        let context = DictationContext(appName: "Notes", bundleID: "com.apple.Notes", beforeText: "I love")
        let h = try Harness(context: context, cleaner: { _ in "flow lite is great" })
        try h.store.setReplacementRules([ReplacementRule(pattern: "flow lite", replacement: "FlowLite")])
        await h.run(.dictateStart, .dictateStop)
        #expect(await h.inserter.inserted == [" FlowLite is great"])
        #expect(try h.store.recent().first?.finalText == "FlowLite is great")
    }

    @Test func transcriptionFailureShowsMessage() async throws {
        let h = try Harness(transcript: .failure(Boom()))
        await h.run(.dictateStart, .dictateStop)
        #expect(await h.inserter.inserted.isEmpty)
        #expect(h.overlay.states.last == .message("Transcription failed"))
        #expect(try h.store.recent().first?.error?.hasPrefix("transcribe:") == true)
    }

    @Test func commandModeReplacesSelection() async throws {
        let context = DictationContext(appName: "Mail", bundleID: "com.apple.mail", selectedText: "hey whats up")
        let h = try Harness(context: context, transcript: .success("make this formal"), cleaner: { request in
            #expect(request.system == PromptBuilder.commandSystemPrompt)
            #expect(request.user.contains("hey whats up"))
            return "Hello, how are you?"
        })
        await h.run(.commandStart, .commandStop)
        #expect(await h.inserter.inserted == ["Hello, how are you?"])
        #expect(h.overlay.states.first == .recording(command: true))
        #expect(try h.store.recent().first?.mode == "command")
    }

    @Test func commandWithoutSelectionInsertsNothing() async throws {
        let h = try Harness(transcript: .success("make this formal"))
        await h.run(.commandStart, .commandStop)
        #expect(await h.inserter.inserted.isEmpty)
        #expect(h.overlay.states.last == .message("Select text first"))
    }

    @Test func commandFailureInsertsNothing() async throws {
        let context = DictationContext(selectedText: "text")
        let h = try Harness(context: context, transcript: .success("shorten it"), cleaner: { _ in throw Boom() })
        await h.run(.commandStart, .commandStop)
        #expect(await h.inserter.inserted.isEmpty)
        #expect(h.overlay.states.last == .message("Rewrite failed"))
    }

    @Test func cancelDiscardsRecording() async throws {
        let h = try Harness()
        await h.run(.dictateStart, .cancel)
        #expect(h.recorder.cancels == 1)
        #expect(await h.inserter.inserted.isEmpty)
        #expect(h.overlay.states == [.recording(command: false), .hidden])
    }

    @Test func blockedReasonPreventsRecording() async throws {
        let h = try Harness(settings: CoordinatorSettings(blockedReason: "Loading speech model…"))
        await h.run(.dictateStart, .dictateStop)
        #expect(h.recorder.starts == 0)
        #expect(h.overlay.states == [.message("Loading speech model…")])
    }

    @Test func microphoneFailureShowsMessage() async throws {
        let recorder = FakeRecorder()
        recorder.failStart = true
        let h = try Harness(recorder: recorder)
        await h.run(.dictateStart, .dictateStop)
        #expect(h.overlay.states == [.message("Microphone unavailable")])
    }

    @Test func clipboardFallbackIsReported() async throws {
        let h = try Harness(inserter: FakeInserter(method: .clipboard))
        await h.run(.dictateStart, .dictateStop)
        #expect(h.overlay.states.last == .message("Copied — press ⌘V"))
    }

    @Test func startWhileProcessingShowsMessage() async throws {
        let h = try Harness(cleaner: { _ in
            try await Task.sleep(nanoseconds: 100_000_000)
            return "Done."
        })
        h.coordinator.handle(.dictateStart)
        h.coordinator.handle(.dictateStop)
        await h.run(.dictateStart)
        #expect(h.recorder.starts == 1)
        #expect(h.overlay.states.contains(.message("Still processing…")))
        #expect(await h.inserter.inserted == ["Done."])
    }

    @Test func hungTranscriberTimesOut() async throws {
        let h = try Harness(transcriber: HungTranscriber())
        h.coordinator.transcribeTimeout = { _ in 0.05 }
        let start = ContinuousClock.now
        await h.run(.dictateStart, .dictateStop)
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(await h.inserter.inserted.isEmpty)
        #expect(h.overlay.states.last == .message("Transcription failed"))
        #expect(try h.store.recent().first?.error?.hasPrefix("transcribe:") == true)
    }

    @Test func transcribeTimeoutScalesWithAudio() async throws {
        let h = try Harness()
        #expect(h.coordinator.transcribeTimeout(RecordedAudio(samples: Array(repeating: 0, count: 32_000))) == 12.0)
    }

    @Test func hungContextReaderFailsClosedAsSecure() async throws {
        let calls = CallCounter()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = try Harness(cleaner: { _ in calls.count += 1; return "x" },
                            contextReader: HungContextReader(), archive: RecordingArchive(directory: dir))
        h.coordinator.contextTimeout = 0.05
        let start = ContinuousClock.now
        await h.run(.dictateStart, .dictateStop)
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(calls.count == 0)
        #expect(await h.inserter.inserted == ["hello there how are you"])
        let record = try #require(try h.store.recent().first)
        #expect(record.appName == "")
        #expect(record.rawText == "")
        #expect(record.finalText == "")
        #expect(record.error == "secure field: text not stored")
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func secureFieldSkipsCleanupAndStoresNoText() async throws {
        let calls = CallCounter()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = DictationContext(appName: "Safari", bundleID: "com.apple.Safari",
                                       beforeText: "pw", isSecure: true)
        let h = try Harness(context: context, cleaner: { _ in calls.count += 1; return "x" },
                            archive: RecordingArchive(directory: dir))
        await h.run(.dictateStart, .dictateStop)
        #expect(calls.count == 0)
        #expect(await h.inserter.inserted == [" hello there how are you"])
        let record = try #require(try h.store.recent().first)
        #expect(record.rawText == "")
        #expect(record.finalText == "")
        #expect(record.error == "secure field: text not stored")
        #expect(!FileManager.default.fileExists(atPath: dir.path)) // audio not archived either
    }

    @Test func failedInsertIsReported() async throws {
        let h = try Harness(inserter: FakeInserter(method: .none))
        await h.run(.dictateStart, .dictateStop)
        #expect(h.overlay.states.last == .message("Couldn't insert — saved to History"))
        #expect(try h.store.recent().first?.finalText == "Hello there, how are you?")
    }

    @Test func failedCommandInsertIsReported() async throws {
        let context = DictationContext(selectedText: "text")
        let h = try Harness(context: context, transcript: .success("shorten it"), cleaner: { _ in "t" },
                            inserter: FakeInserter(method: .none))
        await h.run(.commandStart, .commandStop)
        #expect(h.overlay.states.last == .message("Couldn't insert — saved to History"))
    }
}
