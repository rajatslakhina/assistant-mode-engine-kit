@testable import AssistantModes
import XCTest

final class RoutePolicyTests: XCTestCase {
    private let fits = ContextPlan(includedTurns: [], droppedTurnCount: 0, estimatedTokens: 10, budget: 100)

    private func context(
        requirements: Set<Capability> = [.onDeviceText],
        needs: Set<Capability> = [],
        profile: PlatformProfile = Fixture.iPhone,
        availability: ModelAvailability = .available,
        overBudget: Bool = false,
        escalation: EscalationRule = .allowed,
        consent: Bool = true,
        online: Bool = true,
        hasCloud: Bool = true
    ) -> RouteContext {
        RouteContext(
            modeRequirements: requirements, requestNeeds: needs, profile: profile, availability: availability,
            budgetResult: overBudget ? .failure(.fixedPartExceedsBudget(fixed: 500, budget: 100)) : .success(fits),
            escalation: escalation, cloudConsent: consent, isOnline: online, hasEscalationModel: hasCloud
        )
    }

    func testServesOnDeviceWhenCapableAvailableAndWithinBudget() {
        XCTAssertEqual(RoutePolicy.decide(context()), .onDevice(fits))
    }

    func testRequestNeedsAreCheckedAgainstTheProfileNotJustModeRequirements() {
        XCTAssertEqual(RoutePolicy.decide(context(needs: [.imageInput], profile: Fixture.appleTV)),
                       .escalate(because: .missingCapabilities([.imageInput])))
        XCTAssertEqual(RoutePolicy.decide(context(needs: [.imageInput], profile: Fixture.iPhone)), .onDevice(fits))
    }

    func testMissingCapabilityIsReportedBeforeAvailabilityAndBudget() {
        let decision = RoutePolicy.decide(context(
            needs: [.imageInput], profile: Fixture.appleTV,
            availability: .unavailable(.modelNotReady), overBudget: true
        ))
        XCTAssertEqual(decision, .escalate(because: .missingCapabilities([.imageInput])))
    }

    func testUnavailableModelIsReportedBeforeBudget() {
        XCTAssertEqual(RoutePolicy.decide(context(availability: .unavailable(.appleIntelligenceNotEnabled), overBudget: true)),
                       .escalate(because: .modelUnavailable(.appleIntelligenceNotEnabled)))
    }

    func testOverBudgetEscalates() {
        XCTAssertEqual(RoutePolicy.decide(context(overBudget: true)),
                       .escalate(because: .overBudget(fixed: 500, budget: 100)))
    }

    func testForbiddenModeNeverEscalatesEvenWithConsentAndNetwork() {
        XCTAssertEqual(RoutePolicy.decide(context(overBudget: true, escalation: .forbidden)),
                       .refuse(because: .overBudget(fixed: 500, budget: 100), blockedBy: .modeForbidsEscalation))
    }

    func testNoConsentBlocksEscalation() {
        XCTAssertEqual(RoutePolicy.decide(context(overBudget: true, consent: false)),
                       .refuse(because: .overBudget(fixed: 500, budget: 100), blockedBy: .noCloudConsent))
    }

    func testOfflineBlocksEscalation() {
        XCTAssertEqual(RoutePolicy.decide(context(overBudget: true, online: false)),
                       .refuse(because: .overBudget(fixed: 500, budget: 100), blockedBy: .offline))
    }

    func testMissingCloudModelBlocksEscalation() {
        XCTAssertEqual(RoutePolicy.decide(context(overBudget: true, hasCloud: false)),
                       .refuse(because: .overBudget(fixed: 500, budget: 100), blockedBy: .noEscalationModelConfigured))
    }

    /// With every gate closed, the most fundamental one is reported: the mode rule, then consent,
    /// then the network, then configuration.
    func testEscalationGatesAreReportedInPriorityOrder() {
        func blocker(_ c: RouteContext) -> EscalationBlocker? {
            if case .refuse(_, let b) = RoutePolicy.decide(c) { return b }
            return nil
        }
        XCTAssertEqual(blocker(context(overBudget: true, escalation: .forbidden, consent: false, online: false, hasCloud: false)),
                       .modeForbidsEscalation)
        XCTAssertEqual(blocker(context(overBudget: true, consent: false, online: false, hasCloud: false)), .noCloudConsent)
        XCTAssertEqual(blocker(context(overBudget: true, online: false, hasCloud: false)), .offline)
    }

    func testGatesDoNotMatterWhenTheTurnStaysOnDevice() {
        XCTAssertEqual(RoutePolicy.decide(context(escalation: .forbidden, consent: false, online: false, hasCloud: false)),
                       .onDevice(fits))
    }
}
