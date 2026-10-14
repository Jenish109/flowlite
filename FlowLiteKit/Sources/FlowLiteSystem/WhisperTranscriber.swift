import Foundation
import FlowLiteCore
import WhisperKit

/// Local speech-to-text on the Neural Engine via WhisperKit.
public actor WhisperTranscriber: Transcribing {
    public enum State: Equatable, Sendable {
        case notLoaded
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    public static let defaultModel = "openai_whisper-large-v3-v20240930_turbo"
    public static let smallEnglishModel = "openai_whisper-small.en"
    static let repo = "argmaxinc/whisperkit-coreml"

    private let model: String
    private let modelsDirectory: URL
    private var pipe: WhisperKit?
    private var language: String?
    private var loading = false
    private var inFlight: Task<String, Error>?

    /// Compiled models WhisperKit 0.18 loads from the model folder (TextDecoderContextPrefill is optional).
    static let requiredComponents = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]

    public init(model: String = WhisperTranscriber.defaultModel, modelsDirectory: URL) {
        self.model = model
        self.modelsDirectory = modelsDirectory
    }

    public var isReady: Bool { pipe != nil }

    /// `nil` auto-detects the spoken language.
    public func setLanguage(_ code: String?) {
        language = code
    }

    /// Downloads the model on first use (~1.6 GB for large-v3-turbo), then loads it. The first load
    /// compiles the model for the Neural Engine and can take a few minutes; later loads are seconds.
    /// A call while a load is already running returns immediately.
    public func load(onState: @escaping @Sendable (State) -> Void) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        var folder: URL?
        do {
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
            let local = modelsDirectory.appendingPathComponent("models/\(Self.repo)/\(model)")
            if Self.requiredComponents.allSatisfy({
                FileManager.default.fileExists(atPath: local.appendingPathComponent($0).path)
            }) {
                folder = local
            } else {
                onState(.downloading(0))
                folder = try await WhisperKit.download(variant: model, downloadBase: modelsDirectory, from: Self.repo) { progress in
                    onState(.downloading(progress.fractionCompleted))
                }
            }
            onState(.loading)
            let config = WhisperKitConfig(model: model, downloadBase: modelsDirectory, modelFolder: folder?.path,
                                          verbose: false, prewarm: true, load: true, download: false)
            pipe = try await WhisperKit(config)
            onState(.ready)
        } catch {
            // Delete only an incomplete model (re-download next launch); a complete one may have hit a
            // transient failure (e.g. Neural Engine compile) and must be kept.
            if let folder, !Self.requiredComponents.allSatisfy({
                FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
            }) {
                try? FileManager.default.removeItem(at: folder)
            }
            onState(.failed(error.localizedDescription))
        }
    }

    /// Runs one transcription at a time: a new request cancels and waits out the previous one.
    public func transcribe(_ samples: [Float], vocabulary: [String]) async throws -> String {
        guard let pipe else { throw TranscriberError.notReady }
        while let previous = inFlight {
            previous.cancel()
            _ = try? await previous.value
            if inFlight == previous { inFlight = nil }
        }
        var options = DecodingOptions(task: .transcribe, language: language, temperature: 0,
                                      usePrefillPrompt: true, detectLanguage: language == nil,
                                      skipSpecialTokens: true, withoutTimestamps: true)
        if !vocabulary.isEmpty, let tokenizer = pipe.tokenizer {
            let prompt = " " + vocabulary.joined(separator: ", ")
            // WhisperKit keeps the most recent tokens that fit, so pass them all.
            options.promptTokens = tokenizer.encode(text: prompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
        let decodeOptions = options
        let task = Task<String, Error> {
            let results = try await pipe.transcribe(audioArray: samples, decodeOptions: decodeOptions)
            return results.map(\.text).joined(separator: " ")
        }
        inFlight = task
        defer { if inFlight == task { inFlight = nil } }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

public enum TranscriberError: Error {
    case notReady
}
