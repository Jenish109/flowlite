import AppKit
import SwiftUI
import FlowLiteCore

@MainActor
final class OverlayModel: ObservableObject {
    static let barCount = 28

    @Published var state: OverlayState = .hidden
    @Published var levels: [Float] = Array(repeating: 0, count: barCount)

    func push(_ level: Float) {
        levels.removeFirst()
        levels.append(level)
    }

    func resetLevels() {
        levels = Array(repeating: 0, count: Self.barCount)
    }
}

/// A small pill at the bottom of the screen. Non-activating and click-through, so it never steals
/// focus from the field being dictated into.
@MainActor
final class OverlayController: OverlayPresenting {
    private let model = OverlayModel()
    private lazy var panel: NSPanel = makePanel()
    private var hideTask: Task<Void, Never>?

    func show(_ state: OverlayState) {
        hideTask?.cancel()
        model.state = state
        if state == .hidden {
            panel.orderOut(nil)
            return
        }
        if case .recording = state { model.resetLevels() }
        positionPanel()
        panel.orderFrontRegardless()
        if case .message = state {
            hideTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                guard !Task.isCancelled else { return }
                self?.show(.hidden)
            }
        }
    }

    func setLevel(_ level: Float) {
        if case .recording = model.state { model.push(level) }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 44),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: OverlayView(model: model))
        return panel
    }

    private func positionPanel() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 28))
    }
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .padding(.horizontal, 16)
        .frame(width: 280, height: 44)
        .background(Capsule().fill(Color.black.opacity(0.82)))
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .recording(let command):
            Image(systemName: command ? "wand.and.stars" : "mic.fill")
                .foregroundStyle(command ? Color.purple : Color.red)
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(model.levels.enumerated()), id: \.offset) { _, level in
                    Capsule().frame(width: 3, height: max(3, CGFloat(level) * 26))
                }
            }
            .animation(.linear(duration: 0.05), value: model.levels)
        case .processing:
            ProgressView().controlSize(.small).tint(.white)
            Text("Transcribing…").font(.callout)
        case .message(let text):
            Text(text).font(.callout).lineLimit(1).minimumScaleFactor(0.75)
        case .hidden:
            EmptyView()
        }
    }
}
