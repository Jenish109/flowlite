import SwiftUI
import FlowLiteCore
import FlowLiteSystem

struct SettingsView: View {
    @ObservedObject var app: AppState

    var body: some View {
        TabView {
            GeneralSettings(app: app)
                .tabItem { Label("General", systemImage: "gear") }
            DictionarySettings(store: app.store)
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
        }
        .frame(width: 560, height: 500)
    }
}

struct GeneralSettings: View {
    @ObservedObject var app: AppState
    @State private var apiKey = ""

    var body: some View {
        Form {
            Section("Hotkey") {
                Picker("Dictation key", selection: $app.trigger) {
                    ForEach(HotkeyTrigger.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text("Hold to dictate · double-tap to lock, tap again to stop · hold Control first for command mode · Esc cancels")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Using fn? Set System Settings ▸ Keyboard ▸ “Press 🌐 key to” ▸ Do Nothing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Speech") {
                Picker("Language", selection: $app.language) {
                    ForEach(AppState.languages, id: \.code) { Text($0.name).tag($0.code) }
                }
                Picker("Model", selection: $app.modelName) {
                    Text("Large v3 Turbo (best)").tag(WhisperTranscriber.defaultModel)
                    Text("Small, English only (fastest)").tag(WhisperTranscriber.smallEnglishModel)
                }
                if case .failed(let message) = app.modelState {
                    HStack {
                        Text("Model error: \(message)").font(.caption).foregroundStyle(.red)
                        Spacer()
                        Button("Retry") { app.reloadModel() }
                    }
                }
            }
            Section("Cleanup") {
                Toggle("Clean up text with Claude Haiku", isOn: $app.cleanupEnabled)
                Picker("Editing", selection: $app.editingStrength) {
                    Text("Light — punctuation and fillers only").tag(EditingStrength.light)
                    Text("Standard — also fixes grammar").tag(EditingStrength.standard)
                }
                .disabled(!app.cleanupEnabled)
                HStack {
                    SecureField(app.hasAPIKey ? "API key saved — paste a new one to replace" : "Anthropic API key",
                                text: $apiKey)
                    Button("Save") {
                        app.saveAPIKey(apiKey)
                        apiKey = ""
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    if app.hasAPIKey {
                        Button("Remove") { app.saveAPIKey("") }
                    }
                }
            }
            Section("Permissions") {
                ForEach(Permission.allCases, id: \.self) { permission in
                    let granted = app.permissions[permission] == true
                    HStack {
                        Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(granted ? Color.green : Color.red)
                        Text(permission.title)
                        Spacer()
                        if !granted { Button("Grant…") { app.grant(permission) } }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct DictionarySettings: View {
    let store: FlowStore

    struct EditableRule: Identifiable {
        let id = UUID()
        var rule: ReplacementRule
    }

    @State private var words = ""
    @State private var rules: [EditableRule] = []
    @State private var status = ""
    @State private var loaded = false

    var body: some View {
        Form {
            Section("Vocabulary — one word or name per line") {
                TextEditor(text: $words)
                    .font(.body.monospaced())
                    .frame(minHeight: 110)
            }
            Section("Replacements — applied after cleanup") {
                ForEach($rules) { $item in
                    HStack {
                        TextField("When I say", text: $item.rule.pattern)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("Insert", text: $item.rule.replacement)
                        Toggle("Aa", isOn: $item.rule.caseSensitive)
                            .toggleStyle(.button).help("Case sensitive")
                        Toggle("Word", isOn: $item.rule.wholeWord)
                            .toggleStyle(.button).help("Whole words only")
                        Button {
                            let id = item.id
                            DispatchQueue.main.async { rules.removeAll { $0.id == id } }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add replacement") {
                    rules.append(EditableRule(rule: ReplacementRule(pattern: "", replacement: "")))
                }
            }
            HStack {
                Text(status).foregroundStyle(.secondary)
                Spacer()
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // Load once so switching tabs doesn't discard unsaved edits.
            guard !loaded else { return }
            loaded = true
            load()
        }
    }

    private func load() {
        words = ((try? store.vocabulary()) ?? []).joined(separator: "\n")
        rules = ((try? store.replacementRules()) ?? []).map { EditableRule(rule: $0) }
    }

    private func save() {
        do {
            try store.setVocabulary(words.components(separatedBy: .newlines))
            try store.setReplacementRules(rules.map(\.rule))
            load()
            status = "Saved"
        } catch {
            status = "Save failed: \(error.localizedDescription)"
        }
    }
}
