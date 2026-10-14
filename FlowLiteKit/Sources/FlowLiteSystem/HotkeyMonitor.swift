import AppKit
import CoreGraphics
import FlowLiteCore

public enum HotkeyTrigger: String, CaseIterable, Sendable {
    case fn, rightOption

    public var label: String {
        switch self {
        case .fn: "fn (🌐)"
        case .rightOption: "Right Option (⌥)"
        }
    }
}

/// Listens to keyboard events system-wide (listen-only: nothing is swallowed) and feeds
/// `HotkeyStateMachine`. Requires Input Monitoring. Callbacks arrive on the main thread.
public final class HotkeyMonitor {
    public var onAction: ((HotkeyAction) -> Void)?
    public var trigger: HotkeyTrigger = .fn {
        didSet {
            if triggerIsDown { onAction?(.cancel) }
            triggerIsDown = false
            machine = HotkeyStateMachine()
        }
    }

    private var machine = HotkeyStateMachine()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var triggerIsDown = false

    static let escapeKeyCode: Int64 = 53
    static let rightOptionKeyCode: Int64 = 61

    /// NX_DEVICERALTKEYMASK: the right Option key specifically (`.maskAlternate` is either side).
    static let rightOptionFlag: UInt64 = 0x40

    public init() {}

    deinit { stop() }

    public var isRunning: Bool { tap != nil }

    /// Returns false when the tap can't be created (Input Monitoring not granted).
    @discardableResult
    public func start() -> Bool {
        if tap != nil { return true }
        let mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
                 | (CGEventMask(1) << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon {
                Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue().process(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    public func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func process(type: CGEventType, event: CGEvent) {
        // Not event.timestamp: on Apple Silicon it is in mach ticks (~41.7 ns), not nanoseconds.
        let now = ProcessInfo.processInfo.systemUptime
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            let flags = event.flags
            let down: Bool
            switch trigger {
            case .fn:
                down = flags.contains(.maskSecondaryFn)
            case .rightOption:
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                down = keyCode == Self.rightOptionKeyCode ? flags.rawValue & Self.rightOptionFlag != 0 : triggerIsDown
            }
            guard down != triggerIsDown else { return }
            triggerIsDown = down
            let input: HotkeyInput = down ? .triggerDown(withControl: flags.contains(.maskControl)) : .triggerUp
            emit(machine.handle(input, at: now))
        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            emit(machine.handle(keyCode == Self.escapeKeyCode ? .escape : .otherKeyDown, at: now))
        default:
            break
        }
    }

    private func emit(_ action: HotkeyAction?) {
        if let action { onAction?(action) }
    }
}
