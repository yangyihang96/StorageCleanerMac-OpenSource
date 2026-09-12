import Foundation

/// The one UI-facing phase for a Smart Scan session. It never creates,
/// approves, or executes a cleanup plan.
enum SmartScanPresentationState: Equatable, Sendable {
    case idle
    case preparing
    case scanning
    case finalizing
    case results
    case confirming
    case cleaning
    case verifying
    case completed
    case cancelling
    case failed
    case cancelled

    var showsProgressPage: Bool {
        switch self {
        case .preparing, .scanning, .finalizing, .cancelling:
            true
        case .idle, .results, .confirming, .cleaning, .verifying, .completed, .failed, .cancelled:
            false
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            true
        case .idle, .preparing, .scanning, .finalizing, .results, .confirming,
             .cleaning, .verifying, .cancelling:
            false
        }
    }

    func canTransition(to next: Self) -> Bool {
        if self == next { return true }

        if next == .failed || next == .cancelled {
            return !isTerminal && self != .idle
        }

        switch (self, next) {
        case (.preparing, .scanning),
             (.preparing, .cancelling),
             (.scanning, .finalizing),
             (.scanning, .cancelling),
             (.finalizing, .results),
             (.results, .verifying),
             (.verifying, .confirming),
             (.verifying, .results),
             (.confirming, .cleaning),
             (.confirming, .results),
             (.cleaning, .cancelling),
             (.cleaning, .verifying),
             (.cancelling, .verifying),
             (.verifying, .completed):
            return true
        default:
            return false
        }
    }
}

/// Stores the display phase and the token that owns it together. A delayed
/// callback can only update the session that started it.
struct ScanPresentation: Equatable, Sendable {
    private(set) var sessionID: UUID?
    private(set) var state: SmartScanPresentationState

    init(
        sessionID: UUID? = nil,
        state: SmartScanPresentationState = .idle
    ) {
        self.sessionID = sessionID
        self.state = state
    }

    mutating func begin(sessionID: UUID = UUID()) {
        self.sessionID = sessionID
        state = .preparing
    }

    @discardableResult
    mutating func transition(
        to state: SmartScanPresentationState,
        matching sessionID: UUID
    ) -> Bool {
        guard self.sessionID == sessionID else { return false }
        guard self.state.canTransition(to: state) else {
#if DEBUG
            assertionFailure("Invalid Smart Scan presentation transition: \(self.state) -> \(state)")
#endif
            return false
        }
        self.state = state
        return true
    }

    mutating func reset() {
        sessionID = nil
        state = .idle
    }
}

/// Compatibility spelling for existing view code while Smart Scan owns the
/// presentation contract above.
typealias ScanPresentationState = SmartScanPresentationState
