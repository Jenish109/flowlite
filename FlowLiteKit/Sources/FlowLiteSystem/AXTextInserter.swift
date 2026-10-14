import AppKit
import ApplicationServices
import FlowLiteCore

/// Inserts text at the cursor of the focused field: Accessibility first (verified by re-reading
/// the field), then a ⌘V paste that restores the user's clipboard, then clipboard-only.
public struct AXTextInserter: TextInserting {
    /// Apps where AX insertion is unreliable or verification lags, risking double insertion.
    static let pasteOnlyBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "com.google.Chrome", "com.brave.Browser", "company.thebrowser.Browser", "com.microsoft.edgemac",
    ]

    public init() {}

    /// Roles that accept typed text; with any other focus a synthetic ⌘V would go nowhere.
    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea"]

    @MainActor
    public func insert(_ text: String) async -> InsertMethod {
        guard !text.isEmpty else { return .none }
        let front = AX.frontmost()
        let focused = front.flatMap { AX.focusedElement(in: $0.element) }
        let isSecure = focused.map(AX.isSecure) ?? false
        if let front,
           !Self.pasteOnlyBundleIDs.contains(front.app.bundleIdentifier ?? ""),
           !AX.isElectron(front.app) {
            if let focused {
                // Clipboard-only just when a readable role says it isn't text; unknown focus or role
                // (poor-AX apps like Alacritty, kitty, Sublime) still gets ⌘V.
                if let role = AX.string(focused, kAXRoleAttribute), !Self.textRoles.contains(role) {
                    if isSecure { return .none }
                    Self.copyToClipboard(text)
                    return .clipboard
                }
                if !isSecure, await Self.insertViaAccessibility(text, into: focused) { return .ax }
            }
        }
        if await Self.paste(text) { return .paste }
        // Never leave secure-field text sitting on the clipboard.
        if isSecure { return .none }
        Self.copyToClipboard(text)
        return .clipboard
    }

    /// Only attempted when the field's value is readable, so success can be verified and a
    /// failed attempt never leads to the paste fallback inserting the text twice.
    @MainActor
    static func insertViaAccessibility(_ text: String, into element: AXUIElement) async -> Bool {
        guard let before = AX.string(element, kAXValueAttribute),
              AX.isSettable(element, kAXSelectedTextAttribute) else { return false }
        let rangeBefore = AX.selectedRange(element)
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
        else { return false }
        for _ in 0..<3 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            let after = AX.string(element, kAXValueAttribute)
            let rangeAfter = AX.selectedRange(element)
            // The set reported success; if the field can't be re-read, trust it rather than
            // risk a second insertion via paste.
            if after == nil, rangeAfter == nil { return true }
            if let after, after != before { return true }
            if let rangeBefore, let rangeAfter,
               rangeAfter.location != rangeBefore.location || (rangeBefore.length > 0 && rangeAfter.length == 0) {
                return true
            }
        }
        return false
    }

    @MainActor
    static func paste(_ text: String) async -> Bool {
        let pasteboard = NSPasteboard.general
        let saved = PasteboardSnapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Tells clipboard managers to ignore this temporary entry (nspasteboard.org convention).
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let ourChange = pasteboard.changeCount
        await waitForModifiersReleased()
        guard postCommandV() else {
            saved.restore(to: pasteboard)
            return false
        }
        try? await Task.sleep(nanoseconds: 600_000_000)
        if pasteboard.changeCount == ourChange { saved.restore(to: pasteboard) }
        return true
    }

    static let heldModifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskSecondaryFn, .maskCommand]

    /// A physically held modifier would combine with our ⌘V (e.g. ⌥⌘V), so wait up to 1 s for release.
    static func waitForModifiersReleased() async {
        for _ in 0..<50 {
            if CGEventSource.flagsState(.combinedSessionState).isDisjoint(with: heldModifiers) { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    static func postCommandV() -> Bool {
        let vKey: CGKeyCode = 9
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    @MainActor
    static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A copy of every item and type on the pasteboard, so a paste can put the user's clipboard back.
struct PasteboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]

    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            var types: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { types[type] = data }
            }
            return types
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { types -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}
