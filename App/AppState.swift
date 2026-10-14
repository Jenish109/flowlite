import AVFoundation
import os
import SwiftUI
import FlowLiteCore
import FlowLiteSystem

/// Forwards to the current WhisperTranscriber so the speech model can change without rebuilding the coordinator.
final class SwappableTranscriber: Transcribing, @unchecked Sendable {
    private let current: OSAllocatedUnfairLock<WhisperTranscriber>

    init(_ initial: WhisperTranscriber) { current = OSAllocatedUnfairLock(initialState: initial) }

    func replace(with transcriber: WhisperTranscriber) { current.withLock { $0 = transcriber } }

    func transcribe(_ samples: [Float], vocabulary: [String]) async throws -> String {
        let transcriber = current.withLock { $0 }
        return try await transcriber.transcribe(samples, vocabulary: vocabulary)
    }
}

/// Owns every service, the user's settings and permission status, and wires the hotkey to the coordinator.
@MainActor
final class AppState: ObservableObject {
    struct Language: Hashable {
        let code: String
        let name: String
    }

    static let languages = [
        Language(code: "", name: "Auto-detect"), Language(code: "en", name: "English"),
        Language(code: "hi", name: "Hindi"), Language(code: "gu", name: "Gujarati"),
        Language(code: "es", name: "Spanish"), Language(code: "fr", name: "French"),
        Language(code: "de", name: "German"),
    ]

    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("FlowLite")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    @Published var modelState: WhisperTranscriber.State = .notLoaded
    @Published var permissions: [Permission: Bool] = [:]
    @Published var hotkeyActive = false
    @Published var hasAPIKey = false
    @Published var cleanupEnabled: Bool {
        didSet { defaults.set(cleanupEnabled, forKey: "cleanupEnabled") }
    }
    @Published var editingStrength: EditingStrength {
        didSet { defaults.set(editingStrength.rawValue, forKey: "editingStrength") }
    }
    @Published var trigger: HotkeyTrigger {
        didSet { defaults.set(trigger.rawValue, forKey: "trigger"); hotkey.trigger = trigger }
    }
    @Published var language: String {
        didSet {
            defaults.set(language, forKey: "language")
            let code = language.isEmpty ? nil : language
            let transcriber = self.transcriber
            Task { await transcriber.setLanguage(code) }
        }
    }
    @Published var modelName: String {
        didSet {
            defaults.set(modelName, forKey: "model")
            if modelName != oldValue { switchModel() }
        }
    }

    let store: FlowStore
    private(set) var transcriber: WhisperTranscriber
    private let router: SwappableTranscriber
    private let apiKeyCache: OSAllocatedUnfairLock<String?>
    private let modelsDirectory: URL
    private let defaults = UserDefaults.standard
    private let recorder = AudioRecorder()
    private let hotkey = HotkeyMonitor()
    private let overlay = OverlayController()
    private var coordinator: DictationCoordinator!
    private var permissionTimer: Timer?

    init() {
        // A local, not `self.defaults`: self can't be read until every stored property is set.
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            "cleanupEnabled": true,
            "editingStrength": EditingStrength.standard.rawValue,
            "trigger": HotkeyTrigger.fn.rawValue,
            "language": "",
            "model": WhisperTranscriber.defaultModel,
        ])
        cleanupEnabled = defaults.bool(forKey: "cleanupEnabled")
        editingStrength = EditingStrength(rawValue: defaults.string(forKey: "editingStrength") ?? "") ?? .standard
        trigger = HotkeyTrigger(rawValue: defaults.string(forKey: "trigger") ?? "") ?? .fn
        language = defaults.string(forKey: "language") ?? ""
        let model = defaults.string(forKey: "model") ?? WhisperTranscriber.defaultModel
        modelName = model

        let support = Self.supportDirectory
        do {
            store = try FlowStore(path: support.appendingPathComponent("flowlite.sqlite").path)
        } catch {
            fatalError("FlowLite cannot open its database: \(error)")
        }
        modelsDirectory = support.appendingPathComponent("Models")
        let initialTranscriber = WhisperTranscriber(model: model, modelsDirectory: modelsDirectory)
        transcriber = initialTranscriber
        router = SwappableTranscriber(initialTranscriber)
        let key = Keychain.read()
        let keyCache = OSAllocatedUnfairLock<String?>(initialState: key)
        apiKeyCache = keyCache
        hasAPIKey = key != nil
        coordinator = DictationCoordinator(
            recorder: recorder,
            contextReader: AXContextReader(),
            transcriber: router,
            cleaner: AnthropicCleaner(apiKey: { keyCache.withLock { $0 } }),
            inserter: AXTextInserter(),
            store: store,
            overlay: overlay,
            archive: RecordingArchive(directory: support.appendingPathComponent("Recordings")),
            settings: { [unowned self] in
                CoordinatorSettings(cleanupEnabled: self.cleanupEnabled && self.hasAPIKey,
                                    editingStrength: self.editingStrength,
                                    blockedReason: self.blockedReason)
            })
    }

    func start() {
        hotkey.trigger = trigger
        hotkey.onAction = { [weak self] action in
            MainActor.assumeIsolated { self?.coordinator.handle(action) }
        }
        recorder.onLevel = { [weak self] level in
            MainActor.assumeIsolated { self?.overlay.setLevel(level) }
        }

        refreshPermissions()
        if Permissions.microphoneUndetermined() { Permissions.request(.microphone) }
        hotkeyActive = hotkey.start()

        loadModel()

        // Added in .common mode so it keeps firing while the menu is open.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    /// Loads the current model (a no-op while a load is already running); states reach the main actor in order.
    private func loadModel() {
        let transcriber = self.transcriber
        let code = language.isEmpty ? nil : language
        let (states, continuation) = AsyncStream.makeStream(of: WhisperTranscriber.State.self)
        Task { @MainActor [weak self] in
            for await state in states {
                guard let self, self.transcriber === transcriber else { continue }
                self.modelState = state
            }
        }
        Task {
            await transcriber.setLanguage(code)
            await transcriber.load { continuation.yield($0) }
            continuation.finish()
        }
    }

    func reloadModel() { loadModel() }

    /// Replaces the transcriber with one for the newly selected model and loads it.
    private func switchModel() {
        let replacement = WhisperTranscriber(model: modelName, modelsDirectory: modelsDirectory)
        transcriber = replacement
        router.replace(with: replacement)
        modelState = .notLoaded
        loadModel()
    }

    func refreshPermissions() {
        var current: [Permission: Bool] = [:]
        for permission in Permission.allCases { current[permission] = Permissions.isGranted(permission) }
        if current != permissions { permissions = current }
        if !hotkeyActive, current[.inputMonitoring] == true { hotkeyActive = hotkey.start() }
    }

    func grant(_ permission: Permission) {
        if permission == .microphone, Permissions.microphoneUndetermined() {
            Permissions.request(.microphone)
            return
        }
        Permissions.request(permission)
        Permissions.openSettings(for: permission)
    }

    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { Keychain.delete() } else { Keychain.write(trimmed) }
        let stored = Keychain.read()
        apiKeyCache.withLock { $0 = stored }
        hasAPIKey = stored != nil
    }

    var blockedReason: String? {
        if permissions[.microphone] != true { return "Grant Microphone access in the FlowLite menu" }
        if permissions[.accessibility] != true { return "Grant Accessibility access in the FlowLite menu" }
        switch modelState {
        case .ready: return nil
        case .downloading(let fraction): return "Downloading speech model… \(Int(fraction * 100))%"
        case .failed: return "Speech model failed to load — see Settings"
        case .notLoaded, .loading: return "Loading speech model…"
        }
    }

    var isReady: Bool { blockedReason == nil && hotkeyActive }

    var statusText: String {
        if let reason = blockedReason { return reason }
        if !hotkeyActive { return "Hotkey inactive — grant Input Monitoring" }
        return "Ready — hold \(trigger.label) to dictate"
    }
}
