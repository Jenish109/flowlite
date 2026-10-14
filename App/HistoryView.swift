import AppKit
import SwiftUI
import FlowLiteCore

struct HistoryView: View {
    let store: FlowStore

    @State private var search = ""
    @State private var records: [DictationRecord] = []
    @State private var selection: Int64?
    @State private var confirmClear = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(records, id: \.id) { record in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.finalText.isEmpty ? record.rawText : record.finalText).lineLimit(2)
                        Text(subtitle(record)).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(record.id ?? -1)
                }
            }
            .searchable(text: $search)
            .navigationSplitViewColumnWidth(min: 280, ideal: 320)
        } detail: {
            if let record = records.first(where: { $0.id == selection }) {
                HistoryDetail(record: record) { delete(record) }
            } else {
                Text("Select a dictation").foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 760, minHeight: 440)
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise", action: reload)
            Button("Clear All", systemImage: "trash") { confirmClear = true }
        }
        .confirmationDialog("Delete all dictation history?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) {
                try? store.deleteAllHistory()
                reload()
            }
        }
        .onAppear(perform: reload)
        .onChange(of: search) { reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in reload() }
    }

    private func subtitle(_ record: DictationRecord) -> String {
        var parts = [record.appName.isEmpty ? "Unknown app" : record.appName,
                     record.createdAt.formatted(date: .abbreviated, time: .shortened)]
        if record.mode == "command" { parts.append("command") }
        if record.cleanupFailed { parts.append("uncleaned") }
        return parts.joined(separator: " · ")
    }

    private func reload() {
        records = (try? store.recent(search: search)) ?? []
    }

    private func delete(_ record: DictationRecord) {
        guard let id = record.id else { return }
        try? store.delete(id: id)
        selection = nil
        reload()
    }
}

struct HistoryDetail: View {
    let record: DictationRecord
    let onDelete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LabeledText(title: record.mode == "command" ? "Result" : "Inserted", text: record.finalText)
                LabeledText(title: record.mode == "command" ? "Instruction" : "Raw transcript", text: record.rawText)
                Text(meta).font(.caption).foregroundStyle(.secondary)
                if let error = record.error {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                HStack {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(record.finalText.isEmpty ? record.rawText : record.finalText,
                                                       forType: .string)
                    }
                    Button("Delete", role: .destructive, action: onDelete)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var meta: String {
        "\(record.appName) · audio \(record.audioMs) ms · transcribe \(record.transcribeMs) ms · "
            + "cleanup \(record.cleanMs) ms · inserted via \(record.insertMethod)"
    }
}

struct LabeledText: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            Text(text.isEmpty ? "—" : text).textSelection(.enabled)
        }
    }
}
