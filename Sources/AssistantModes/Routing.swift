/// Why the on-device model is not available right now. Mirrors the reasons Apple's
/// `SystemLanguageModel.Availability` reports, plus an escape hatch for anything new.
public enum UnavailableReason: Equatable, Sendable {
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case other(String)
}

public enum ModelAvailability: Equatable, Sendable {
    case available
    case unavailable(UnavailableReason)
}

/// Why a request could not be served on-device. Exactly one reason is reported, in this priority
/// order: missing capability first (no amount of waiting fixes it), then model availability
/// (may fix itself), then budget (depends on this one prompt).
public enum OnDeviceBlocker: Equatable, Sendable {
    case missingCapabilities([Capability])
    case modelUnavailable(UnavailableReason)
    case overBudget(fixed: Int, budget: Int)
}

/// Why an escalation that was needed did not happen.
public enum EscalationBlocker: Equatable, Sendable {
    case modeForbidsEscalation
    case noCloudConsent
    case offline
    case noEscalationModelConfigured
}

public enum RouteDecision: Equatable, Sendable {
    /// Serve on-device with this budgeted context.
    case onDevice(ContextPlan)
    case escalate(because: OnDeviceBlocker)
    case refuse(because: OnDeviceBlocker, blockedBy: EscalationBlocker)
}

/// Everything the routing decision depends on, gathered at one instant. Pure data, so the
/// decision table is testable without a model, a network or a clock.
public struct RouteContext: Equatable, Sendable {
    public var modeRequirements: Set<Capability>
    public var requestNeeds: Set<Capability>
    public var profile: PlatformProfile
    public var availability: ModelAvailability
    public var budgetResult: Result<ContextPlan, BudgetError>
    public var escalation: EscalationRule
    public var cloudConsent: Bool
    public var isOnline: Bool
    public var hasEscalationModel: Bool

    public init(
        modeRequirements: Set<Capability>,
        requestNeeds: Set<Capability>,
        profile: PlatformProfile,
        availability: ModelAvailability,
        budgetResult: Result<ContextPlan, BudgetError>,
        escalation: EscalationRule,
        cloudConsent: Bool,
        isOnline: Bool,
        hasEscalationModel: Bool
    ) {
        self.modeRequirements = modeRequirements
        self.requestNeeds = requestNeeds
        self.profile = profile
        self.availability = availability
        self.budgetResult = budgetResult
        self.escalation = escalation
        self.cloudConsent = cloudConsent
        self.isOnline = isOnline
        self.hasEscalationModel = hasEscalationModel
    }
}

/// The typed router: on-device by default, Claude only when the on-device model can't do the
/// task, and never when the mode, the user's consent or the network says no.
public enum RoutePolicy {
    public static func decide(_ context: RouteContext) -> RouteDecision {
        let blocker: OnDeviceBlocker
        let missing = context.modeRequirements.union(context.requestNeeds)
            .subtracting(context.profile.capabilities)
        if !missing.isEmpty {
            blocker = .missingCapabilities(missing.sorted())
        } else if case .unavailable(let reason) = context.availability {
            blocker = .modelUnavailable(reason)
        } else {
            switch context.budgetResult {
            case .success(let plan):
                return .onDevice(plan)
            case .failure(.fixedPartExceedsBudget(let fixed, let budget)):
                blocker = .overBudget(fixed: fixed, budget: budget)
            }
        }
        // Escalation gates, most fundamental first: a mode rule is a product decision,
        // consent is the user's, connectivity is circumstance, configuration is ours.
        if context.escalation == .forbidden { return .refuse(because: blocker, blockedBy: .modeForbidsEscalation) }
        if !context.cloudConsent { return .refuse(because: blocker, blockedBy: .noCloudConsent) }
        if !context.isOnline { return .refuse(because: blocker, blockedBy: .offline) }
        if !context.hasEscalationModel { return .refuse(because: blocker, blockedBy: .noEscalationModelConfigured) }
        return .escalate(because: blocker)
    }
}
