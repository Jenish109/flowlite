import AppKit
import ApplicationServices
import FlowLiteCore

/// Reads the frontmost app and the focused text field. Runs off the main thread; every
/// missing piece becomes an empty string, never an error.
public struct AXContextReader: ContextReading {
    public init() {}

    public func snapshot() async -> DictationContext {
        Self.read()
    }

    static func read() -> DictationContext {
        guard let front = AX.frontmost() else { return DictationContext() }
        var context = DictationContext(appName: front.app.localizedName ?? "",
                                       bundleID: front.app.bundleIdentifier ?? "")
        if let window = AX.element(front.element, kAXFocusedWindowAttribute),
           let document = AX.string(window, kAXDocumentAttribute), !document.isEmpty {
            context.url = document
        }
        guard let focused = AX.focusedElement(in: front.element) else { return context }
        if AX.isSecure(focused) {
            context.isSecure = true
            return context
        }
        context.selectedText = AX.string(focused, kAXSelectedTextAttribute) ?? ""
        if let value = AX.string(focused, kAXValueAttribute), let range = AX.selectedRange(focused) {
            let text = value as NSString
            let start = max(0, min(range.location, text.length))
            let end = max(start, min(range.location + range.length, text.length))
            context.beforeText = String(text.substring(to: start).suffix(PromptBuilder.maxBefore))
            context.afterText = String(text.substring(from: end).prefix(PromptBuilder.maxAfter))
        }
        return context
    }
}
