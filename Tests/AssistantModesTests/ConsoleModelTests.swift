@testable import AssistantModes
@testable import AssistantModesUI
import XCTest

@MainActor
final class ConsoleModelTests: XCTestCase {
    func testSendClearsTheDraftAndTheImageFlagBeforeTheModelAnswers() async throws {
        let gate = Gate()
        let model = ClosureModel { _ in await gate.wait(); return "ok" }
        let console = AssistantConsoleModel(engine: try Fixture.engine(onDevice: model), backendLabel: "test")
        console.draft = "hello"
        console.needsImageInput = true
        let sending = Task { await console.send() }
        let arrived = await waitUntil { await gate.arrivals == 1 }
        XCTAssertTrue(arrived)
        XCTAssertEqual(console.draft, "", "a second tap must not resend the same draft")
        XCTAssertFalse(console.needsImageInput)
        XCTAssertEqual(console.sendsInFlight, 1)
        await gate.open()
        await sending.value
        XCTAssertEqual(console.sendsInFlight, 0)
        XCTAssertEqual(console.snapshot?.transcript.map(\.user), ["hello"])
    }

    func testIllegalTransitionSetsLastErrorAndKeepsTheMode() async throws {
        let console = AssistantConsoleModel(engine: try Fixture.engine(), backendLabel: "test")
        await console.transition(to: "review")
        XCTAssertEqual(console.lastError, String(describing: EngineError.illegalTransition(from: "capture", to: "review")))
        XCTAssertEqual(console.snapshot?.mode, "capture")
        XCTAssertNil(console.lastTransition)
        await console.transition(to: "plan")
        XCTAssertNil(console.lastError)
        XCTAssertEqual(console.lastTransition?.to, "plan")
    }

    func testLegalTargetsFollowTheCurrentMode() async throws {
        let console = AssistantConsoleModel(engine: try Fixture.engine(), backendLabel: "test")
        await console.refresh()
        XCTAssertEqual(console.legalTargets, ["plan"])
        await console.transition(to: "plan")
        XCTAssertEqual(console.legalTargets, ["capture", "review"])
    }

    func testWriteToAKeyTheModeDoesNotOwnSurfacesAnError() async throws {
        let console = AssistantConsoleModel(engine: try Fixture.engine(), backendLabel: "test")
        await console.write(.list(["x"]), for: Fixture.steps)
        XCTAssertNotNil(console.lastError)
        XCTAssertNil(console.snapshot?.state[Fixture.steps])
    }

    func testRemainingOutcomeCopy() {
        XCTAssertEqual(OutcomeText.line(for: .rejected(.tooLargeEvenForEscalation(fixed: 120_000, budget: 100_000))).detail,
                       "Needs ~120000 tokens; even the cloud budget is 100000")
        XCTAssertEqual(OutcomeText.line(for: .rejected(.busy)).detail, "A generation is already in flight")
        XCTAssertEqual(OutcomeText.line(for: .rejected(.emptyPrompt)).detail, "Empty prompt")
        XCTAssertEqual(OutcomeText.line(for: .failed(route: .escalated, message: "down")).detail, "escalated: down")
        XCTAssertEqual(OutcomeText.line(for: .cancelled(route: .onDevice)).detail, "onDevice generation cancelled")
        XCTAssertEqual(OutcomeText.reason(.modelUnavailable(.appleIntelligenceNotEnabled)),
                       "on-device model unavailable (Apple Intelligence off)")
        XCTAssertEqual(OutcomeText.reason(.offline), "offline")
        XCTAssertEqual(OutcomeText.reason(.noEscalationModelConfigured), "no cloud model configured")
    }
}
