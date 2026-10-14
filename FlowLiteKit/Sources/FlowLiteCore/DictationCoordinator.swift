import Foundation

// MARK: Service protocols (implemented in FlowLiteSystem, faked in tests)

public protocol AudioRecording: AnyObject {
    func start() throws
    func stop() -> RecordedAudio
    func cancel()
}

public protocol ContextReading: Sendable {
    func snapshot() async -> DictationContext
}

public protocol Transcribing: Sendable {
    func transcribe(_ samples: [Float], vocabulary: [String]) async throws -> String
}

public enum InsertMethod: String, Sendable {
    case ax, paste, clipboard, none
}

public protocol TextInserting: Sendable {
    /// Inserts at the cursor of the currently focused field, replacing any selection.
    func insert(_ text: String) async -> InsertMethod
}

public enum OverlayState: Equatable, Sendable {
    case hidden
    case recording(command: Bool)
    case processing
    case message(String)
}

@MainActor
public protocol OverlayPresenting: AnyObject {
    func show(_ state: OverlayState)
}

public struct CoordinatorSettings: Sendable {
    public var cleanupEnabled: Bool
    public var editingStrength: EditingStrength
    /// Non-nil when dictation can't start (missing permission, model not loaded); shown to the user.
    public var blockedReason: String?

    public init(cleanupEnabled: Bool = true, editingStrength: EditingStrength = .standard,
                blockedReason: String? = nil) {
        self.cleanupEnabled = cleanupEnabled
        self.editingStrength = editingStrength
        self.blockedReason = blockedReason
    }
}

public enum DictationMode: String, Sendable {
    case dictation, command
}

// MARK: Coordinator

/// Owns one dictation session at a time: record → transcribe → clean → insert → save.
@MainActor
public final class DictationCoordinator {
    public static let minAudioMs = 300
    public static let silenceRMS: Float = 0.003

    private let recorder: AudioRecording
    private let contextReader: ContextReading
    private let transcriber: Transcribing
    private let cleaner: Cleaning
    private let inserter: TextInserting
    private let store: FlowStore
    private let overlay: OverlayPresenting
    private let archive: RecordingArchive?
    private let settings: @MainActor () -> CoordinatorSettings

    public var dictationTimeout: (String) -> Double = PromptBuilder.dictationTimeout(raw:)
    public var commandTimeout: (String) -> Double = PromptBuilder.commandTimeout(selection:)
    public var transcribeTimeout: (RecordedAudio) -> Double = { 10 + Double($0.durationMs) / 1000 }
    /// How long to wait for the on-screen context before going on without it.
    public var contextTimeout: Double = 1.0

    private struct Session {
        let mode: DictationMode
        let context: Task<DictationContext, Never>
    }

    private var session: Session?
    public private(set) var processingTask: Task<Void, Never>?

    public init(recorder: AudioRecording, contextReader: ContextReading, transcriber: Transcribing,
                cleaner: Cleaning, inserter: TextInserting, store: FlowStore, overlay: OverlayPresenting,
                archive: RecordingArchive? = nil, settings: @escaping @MainActor () -> CoordinatorSettings) {
        self.recorder = recorder
        self.contextReader = contextReader
        self.transcriber = transcriber
        self.cleaner = cleaner
        self.inserter = inserter
        self.store = store
        self.overlay = overlay
        self.archive = archive
        self.settings = settings
    }

    public func handle(_ action: HotkeyAction) {
        switch action {
        case .dictateStart: begin(.dictation)
        case .commandStart: begin(.command)
        case .cancel: cancel()
        case .dictateStop, .commandStop: stop()
        }
    }

    private func begin(_ mode: DictationMode) {
        guard session == nil else { return }
        guard processingTask == nil else {
            overlay.show(.message("Still processing…"))
            return
        }
        if let reason = settings().blockedReason {
            overlay.show(.message(reason))
            return
        }
        do {
            try recorder.start()
        } catch {
            overlay.show(.message("Microphone unavailable"))
            return
        }
        let reader = contextReader
        session = Session(mode: mode, context: Task.detached { await reader.snapshot() })
        overlay.show(.recording(command: mode == .command))
    }

    private func cancel() {
        guard let current = session else { return }
        session = nil
        current.context.cancel()
        recorder.cancel()
        overlay.show(.hidden)
    }

    private func stop() {
        guard let current = session else { return }
        session = nil
        let audio = recorder.stop()
        processingTask = Task { [weak self] in
            await self?.process(current, audio: audio)
            self?.processingTask = nil
        }
    }

    private func process(_ current: Session, audio: RecordedAudio) async {
        guard audio.durationMs >= Self.minAudioMs, audio.rms >= Self.silenceRMS else {
            current.context.cancel()
            overlay.show(.hidden)
            return
        }
        overlay.show(.processing)
        let contextTask = current.context
        let context = (try? await withTimeout(seconds: contextTimeout) { await contextTask.value }) ?? {
            // Fail closed: if we can't tell whether the field is secure, treat it as secure.
            contextTask.cancel()
            return DictationContext(isSecure: true)
        }()
        let createdAt = Date()
        if let archive, !context.isSecure { _ = try? archive.save(audio.samples, name: Self.archiveName(createdAt)) }

        var record = DictationRecord(createdAt: createdAt, mode: current.mode.rawValue,
                                     appName: context.appName, bundleID: context.bundleID,
                                     audioMs: audio.durationMs)
        let vocabulary = (try? store.vocabulary()) ?? []

        let transcribeStart = Date()
        let raw: String
        do {
            let transcriber = self.transcriber
            raw = try await withTimeout(seconds: transcribeTimeout(audio)) {
                try await transcriber.transcribe(audio.samples, vocabulary: vocabulary)
            }.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            record.error = "transcribe: \(error)"
            finish(record, message: "Transcription failed")
            return
        }
        record.transcribeMs = Self.ms(since: transcribeStart)
        if !context.isSecure { record.rawText = raw }
        guard !raw.isEmpty else {
            overlay.show(.hidden)
            return
        }

        switch current.mode {
        case .dictation: await completeDictation(raw: raw, context: context, vocabulary: vocabulary, record: record)
        case .command: await completeCommand(instruction: raw, context: context, record: record)
        }
    }

    private func completeDictation(raw: String, context: DictationContext, vocabulary: [String],
                                   record: DictationRecord) async {
        var record = record
        if context.isSecure {
            // Never send secure-field dictation to the cleaner or keep it in history.
            record.error = "secure field: text not stored"
            let method = await inserter.insert(Spacing.join(before: context.beforeText, insertion: raw))
            record.insertMethod = method.rawValue
            finish(record, message: method == .none ? "Couldn't insert" : Self.insertMessage(method, text: raw))
            return
        }
        var text = raw
        let current = settings()
        if current.cleanupEnabled, raw.split(whereSeparator: \.isWhitespace).count > 2 {
            let request = PromptBuilder.dictation(raw: raw, context: context, vocabulary: vocabulary,
                                                  strength: current.editingStrength)
            let cleaner = self.cleaner
            let cleanStart = Date()
            do {
                text = try await withTimeout(seconds: dictationTimeout(raw)) { try await cleaner.clean(request) }
            } catch {
                record.cleanupFailed = true
                record.error = "clean: \(error)"
            }
            record.cleanMs = Self.ms(since: cleanStart)
        }
        text = ReplacementEngine.apply((try? store.replacementRules()) ?? [], to: text)
        record.finalText = text

        let method = await inserter.insert(Spacing.join(before: context.beforeText, insertion: text))
        record.insertMethod = method.rawValue
        finish(record, message: Self.insertMessage(method, text: text)
                                ?? (record.cleanupFailed ? "Inserted without cleanup" : nil))
    }

    private func completeCommand(instruction: String, context: DictationContext, record: DictationRecord) async {
        var record = record
        guard !context.selectedText.isEmpty else {
            record.error = "command: no selection"
            finish(record, message: "Select text first")
            return
        }
        let request = PromptBuilder.command(instruction: instruction, selection: context.selectedText, context: context)
        let cleaner = self.cleaner
        let cleanStart = Date()
        do {
            let output = try await withTimeout(seconds: commandTimeout(context.selectedText)) {
                try await cleaner.clean(request)
            }
            record.cleanMs = Self.ms(since: cleanStart)
            record.finalText = output
            let method = await inserter.insert(output)
            record.insertMethod = method.rawValue
            finish(record, message: Self.insertMessage(method, text: output))
        } catch {
            record.cleanMs = Self.ms(since: cleanStart)
            record.cleanupFailed = true
            record.error = "command: \(error)"
            finish(record, message: "Rewrite failed")
        }
    }

    private func finish(_ record: DictationRecord, message: String?) {
        _ = try? store.save(record)
        overlay.show(message.map(OverlayState.message) ?? .hidden)
    }

    /// Overlay message for an insert that didn't land directly in the field.
    static func insertMessage(_ method: InsertMethod, text: String) -> String? {
        switch method {
        case .clipboard: "Copied — press ⌘V"
        case .none: text.isEmpty ? nil : "Couldn't insert — saved to History"
        case .ax, .paste: nil
        }
    }

    static func ms(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    static func archiveName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: date)
    }
}
