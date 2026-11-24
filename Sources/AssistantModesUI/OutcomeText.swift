import AssistantModes

/// How a turn ended, in words a person can read. Pure functions, so the copy is unit-tested.
public enum OutcomeText {
    public enum Tone: Equatable, Sendable {
        case onDevice
        case cloud
        case blocked
        case neutral
    }

    public struct Line: Equatable, Sendable {
        public let badge: String
        public let detail: String
        public let tone: Tone
    }

    public static func line(for outcome: TurnOutcome) -> Line {
        switch outcome {
        case .answered(let text, .onDevice, let plan):
            return Line(badge: "ON-DEVICE", detail: "\(text)\n\(budget(plan))", tone: .onDevice)
        case .answered(let text, .escalated, let plan):
            return Line(badge: "CLAUDE", detail: "\(text)\n\(budget(plan))", tone: .cloud)
        case .refused(let blocker, let escalationBlocker):
            return Line(badge: "REFUSED", detail: "\(reason(blocker)); \(reason(escalationBlocker))", tone: .blocked)
        case .discardedModeChanged(_, let startedIn, let nowIn):
            return Line(
                badge: "DISCARDED",
                detail: "Answer started in \(startedIn) arrived after the switch to \(nowIn); not shown in \(nowIn)",
                tone: .neutral
            )
        case .failed(let route, let message):
            return Line(badge: "FAILED", detail: "\(route.rawValue): \(message)", tone: .blocked)
        case .cancelled(let route):
            return Line(badge: "CANCELLED", detail: "\(route.rawValue) generation cancelled", tone: .neutral)
        case .rejected(.emptyPrompt):
            return Line(badge: "REJECTED", detail: "Empty prompt", tone: .neutral)
        case .rejected(.busy):
            return Line(badge: "REJECTED", detail: "A generation is already in flight", tone: .neutral)
        case .rejected(.tooLargeEvenForEscalation(let fixed, let budget)):
            return Line(badge: "REJECTED", detail: "Needs ~\(fixed) tokens; even the cloud budget is \(budget)", tone: .blocked)
        }
    }

    /// Why a turn escalated, if it did. `nil` for turns that stayed on-device or never routed.
    public static func escalationReason(for decision: RouteDecision?) -> String? {
        guard case .escalate(let blocker) = decision else { return nil }
        return reason(blocker)
    }

    public static func reason(_ blocker: OnDeviceBlocker) -> String {
        switch blocker {
        case .missingCapabilities(let missing):
            return "this device lacks " + missing.map(\.rawValue).joined(separator: ", ")
        case .modelUnavailable(let why):
            return "on-device model unavailable (\(unavailable(why)))"
        case .overBudget(let fixed, let budget):
            return "needs ~\(fixed) tokens, mode budget is \(budget)"
        }
    }

    public static func reason(_ blocker: EscalationBlocker) -> String {
        switch blocker {
        case .modeForbidsEscalation: return "this mode never leaves the device"
        case .noCloudConsent: return "cloud consent is off"
        case .offline: return "offline"
        case .noEscalationModelConfigured: return "no cloud model configured"
        }
    }

    static func unavailable(_ reason: UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: return "device not eligible"
        case .appleIntelligenceNotEnabled: return "Apple Intelligence off"
        case .modelNotReady: return "model still downloading"
        case .other(let text): return text
        }
    }

    /// Whole milliseconds, or "<1 ms" for sub-millisecond turns (scripted models, refusals).
    public static func latency(_ nanoseconds: UInt64) -> String {
        let milliseconds = nanoseconds / 1_000_000
        return milliseconds == 0 ? "<1 ms" : "\(milliseconds) ms"
    }

    static func budget(_ plan: ContextPlan) -> String {
        let dropped = plan.droppedTurnCount == 0 ? "" : " · \(plan.droppedTurnCount) old turn(s) left out"
        return "~\(plan.estimatedTokens)/\(plan.budget) tokens\(dropped)"
    }
}
