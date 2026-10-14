import Foundation

public enum HotkeyAction: Equatable, Sendable {
    case dictateStart, dictateStop, commandStart, commandStop, cancel
}

public enum HotkeyInput: Equatable, Sendable {
    /// The trigger key went down. `withControl` is true if Control was already held.
    case triggerDown(withControl: Bool)
    case triggerUp
    /// Any non-modifier key other than Escape.
    case otherKeyDown
    case escape
}

/// Pure hotkey logic; `HotkeyMonitor` feeds it events from a CGEventTap.
public struct HotkeyStateMachine: Sendable {
    public static let minHold: TimeInterval = 0.3
    public static let doubleTapWindow: TimeInterval = 0.4

    enum State: Equatable {
        case idle(lastTapUp: TimeInterval?)
        case holding(downAt: TimeInterval, command: Bool)
        /// Second press of a double tap: locks if released quickly, otherwise acts as a normal hold.
        case lockPending(downAt: TimeInterval)
        case locked
        case awaitingRelease
    }

    private(set) var state: State = .idle(lastTapUp: nil)

    public init() {}

    public mutating func handle(_ input: HotkeyInput, at time: TimeInterval) -> HotkeyAction? {
        switch (state, input) {
        case let (.idle(lastTapUp), .triggerDown(withControl)):
            if !withControl, let last = lastTapUp, time - last <= Self.doubleTapWindow {
                state = .lockPending(downAt: time)
                return .dictateStart
            }
            state = .holding(downAt: time, command: withControl)
            return withControl ? .commandStart : .dictateStart

        case let (.holding(downAt, command), .triggerUp):
            if time - downAt < Self.minHold {
                state = .idle(lastTapUp: command ? nil : time)
                return .cancel
            }
            state = .idle(lastTapUp: nil)
            return command ? .commandStop : .dictateStop

        case let (.lockPending(downAt), .triggerUp):
            if time - downAt < Self.minHold {
                state = .locked
                return nil
            }
            state = .idle(lastTapUp: nil)
            return .dictateStop

        case (.holding, .otherKeyDown), (.holding, .escape),
             (.lockPending, .otherKeyDown), (.lockPending, .escape), (.locked, .escape):
            state = .idle(lastTapUp: nil)
            return .cancel

        case (.locked, .triggerDown):
            state = .awaitingRelease
            return .dictateStop

        case (.awaitingRelease, .triggerUp):
            state = .idle(lastTapUp: nil)
            return nil

        default:
            return nil
        }
    }
}
