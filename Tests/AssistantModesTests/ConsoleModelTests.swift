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
        XCTAssertTrue(console.isSending)
        await gate.open()
        await sending.value
        XCTAssertFalse(console.isSending)
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

    /// A mode switch releases the UI's in-flight send at once, as the engine does: the new mode can
    /// send even if the old backend ignores cancellation and is still running.
    func testTransitionReleasesTheInFlightSendSoTheNewModeCanSend() async throws {
        let gate = Gate()
        let model = ClosureModel { request in
            if request.mode == "capture" { await gate.wait(); return "stale" } // ignores cancellation
            return "fresh"
        }
        let console = AssistantConsoleModel(engine: try Fixture.engine(onDevice: model), backendLabel: "test")
        console.draft = "slow"
        let stale = Task { await console.send() }
        let arrived = await waitUntil { await gate.arrivals == 1 }
        XCTAssertTrue(arrived)
        XCTAssertTrue(console.isSending)
        await console.transition(to: "plan")
        XCTAssertFalse(console.isSending, "the switch must release the send")

        console.draft = "plan turn"
        await console.send()
        XCTAssertEqual(console.snapshot?.transcript.map(\.assistant), ["fresh"])
        await gate.open()
        await stale.value
        XCTAssertFalse(console.isSending)
    }

    /// A stale console send finishing must not release a newer send that is still in flight.
    func testAStaleSendFinishingDoesNotReleaseTheNewerSend() async throws {
        let captureGate = Gate()
        let planGate = Gate()
        let model = ClosureModel { request in
            if request.mode == "capture" { await captureGate.wait(); return "stale" }
            await planGate.wait()
            return "fresh"
        }
        let console = AssistantConsoleModel(engine: try Fixture.engine(onDevice: model), backendLabel: "test")
        console.draft = "slow"
        let stale = Task { await console.send() }
        let staleArrived = await waitUntil { await captureGate.arrivals == 1 }
        XCTAssertTrue(staleArrived)
        await console.transition(to: "plan")
        console.draft = "plan turn"
        let fresh = Task { await console.send() }
        let freshArrived = await waitUntil { await planGate.arrivals == 1 }
        XCTAssertTrue(freshArrived)

        await captureGate.open()
        await stale.value
        XCTAssertTrue(console.isSending, "the plan send is still in flight")
        await planGate.open()
        await fresh.value
        XCTAssertFalse(console.isSending)
    }

    /// `send()` is public: a second call while one is in flight is ignored, and keeps the draft.
    func testSendWhileSendingIsIgnoredAndKeepsTheDraft() async throws {
        let gate = Gate()
        let calls = Counter()
        let model = ClosureModel { _ in await calls.increment(); await gate.wait(); return "ok" }
        let console = AssistantConsoleModel(engine: try Fixture.engine(onDevice: model), backendLabel: "test")
        console.draft = "first"
        let first = Task { await console.send() }
        let arrived = await waitUntil { await gate.arrivals == 1 }
        XCTAssertTrue(arrived)
        console.draft = "second"
        await console.send()
        XCTAssertEqual(console.draft, "second", "the ignored send must not clear the draft")
        XCTAssertTrue(console.isSending)
        await gate.open()
        await first.value
        let count = await calls.value
        XCTAssertEqual(count, 1)
        let recordsBefore = await console.engine.records.count
        console.draft = "   "
        await console.send() // a blank draft is ignored too: nothing reaches the engine
        let recordsAfter = await console.engine.records.count
        XCTAssertEqual(recordsAfter, recordsBefore)
    }

    /// While a switch is in flight, `write` is ignored: a value meant for the old mode is not applied.
    func testWriteIsIgnoredWhileTransitioning() async throws {
        let console = AssistantConsoleModel(engine: try Fixture.engine(), backendLabel: "test")
        await console.refresh()
        let switching = Task { await console.transition(to: "plan") }
        await Task.yield()
        XCTAssertTrue(console.isTransitioning)
        await console.write(.text("typed in capture"), for: Fixture.topic)
        await switching.value
        let stored = await console.engine.state[Fixture.topic]
        XCTAssertNil(stored)
        XCTAssertNil(console.lastError)
    }

    /// A second switch while one is in flight is ignored, not queued behind it.
    func testSecondTransitionWhileTransitioningIsIgnored() async throws {
        let console = AssistantConsoleModel(engine: try Fixture.engine(), backendLabel: "test")
        await console.refresh()
        let first = Task { await console.transition(to: "plan") }
        await Task.yield()
        XCTAssertTrue(console.isTransitioning)
        await console.transition(to: "review")
        await first.value
        let mode = await console.engine.currentMode
        XCTAssertEqual(mode, "plan")
    }

    /// The console pins the mode it last showed. If the engine moved on without the console seeing
    /// it, a send is rejected by the engine and never reaches a model.
    func testSendPinsTheModeTheConsoleShowed() async throws {
        let calls = Counter()
        let model = ClosureModel { _ in await calls.increment(); return "x" }
        let console = AssistantConsoleModel(engine: try Fixture.engine(onDevice: model, escalation: model), backendLabel: "test")
        await console.refresh()
        try await console.engine.transition(to: "plan") // behind the console's back
        console.draft = "typed in capture"
        await console.send()
        let count = await calls.value
        XCTAssertEqual(count, 0)
        let last = await console.engine.records.last?.outcome
        XCTAssertEqual(last, .rejected(.modeChanged(expected: "capture", actual: "plan")))
    }

    /// The same pin applies to writes: a value meant for the mode the console showed is not applied.
    func testWritePinsTheModeTheConsoleShowed() async throws {
        let console = AssistantConsoleModel(engine: try Fixture.engine(), backendLabel: "test")
        await console.refresh()
        try await console.engine.transition(to: "plan") // behind the console's back
        await console.write(.text("meant for capture"), for: Fixture.topic)
        XCTAssertEqual(console.lastError, String(describing: EngineError.modeChanged(expected: "capture", actual: "plan")))
        let stored = await console.engine.state[Fixture.topic]
        XCTAssertNil(stored)
    }

    /// A send started while a switch out of a private mode is in flight must not go anywhere: it is
    /// ignored (the draft is cleared by the switch, never sent), and the cloud model is never called.
    func testSendDuringASwitchOutOfAPrivateModeNeverReachesTheCloud() async throws {
        let cloudCalls = Counter()
        let cloud = ClosureModel { _ in await cloudCalls.increment(); return "cloud" }
        let console = AssistantConsoleModel(
            engine: try Fixture.engine(profile: Fixture.appleTV, escalation: cloud), backendLabel: "test"
        )
        await console.transition(to: "plan")
        await console.transition(to: "review")
        console.draft = "PRIVATE critique"
        console.needsImageInput = true
        let switching = Task { await console.transition(to: "capture") }
        let sending = Task { await console.send() }
        await switching.value
        await sending.value
        let count = await cloudCalls.value
        XCTAssertEqual(count, 0, "text typed in private review must never be escalated")
        XCTAssertEqual(console.draft, "", "the switch cleared the unsent draft")
        let sends = await console.engine.records
        XCTAssertTrue(sends.isEmpty, "nothing was sent: the send was ignored, not rejected by the engine")
        XCTAssertEqual(console.snapshot?.mode, "capture")
        XCTAssertFalse(console.isSending)
        XCTAssertFalse(console.isTransitioning)
        let generating = await console.engine.isGenerating
        XCTAssertFalse(generating)
    }

    /// While a switch is in flight, `send()` is ignored and keeps the user's draft untouched.
    func testSendIsIgnoredWhileTransitioning() async throws {
        let console = AssistantConsoleModel(engine: try Fixture.engine(), backendLabel: "test")
        await console.refresh()
        console.draft = "typed in capture"
        let switching = Task { await console.transition(to: "plan") }
        await Task.yield() // let the switch start and mark itself in flight
        XCTAssertTrue(console.isTransitioning)
        await console.send()
        XCTAssertEqual(console.snapshot?.transcript.count ?? 0, 0)
        await switching.value
        XCTAssertFalse(console.isTransitioning)
        let records = await console.engine.records
        XCTAssertTrue(records.isEmpty, "nothing was sent")
    }

    /// The console forwards the image flag to routing: on Apple TV, a request marked as needing image
    /// input must escalate for that reason.
    func testImageFlagReachesRouting() async throws {
        let console = AssistantConsoleModel(engine: try Fixture.engine(profile: Fixture.appleTV), backendLabel: "test")
        console.draft = "read this receipt"
        console.needsImageInput = true
        await console.send()
        let decision = await console.engine.records.last?.decision
        XCTAssertEqual(decision, .escalate(because: .missingCapabilities([.imageInput])))
    }

    /// An unsent draft typed in one mode (possibly private) must not survive a switch to another.
    func testSuccessfulTransitionClearsTheDraftAndImageFlag() async throws {
        let console = AssistantConsoleModel(engine: try Fixture.engine(), backendLabel: "test")
        console.draft = "typed but not sent"
        console.needsImageInput = true
        await console.transition(to: "review") // illegal: nothing changes
        XCTAssertEqual(console.draft, "typed but not sent")
        await console.transition(to: "plan")
        XCTAssertEqual(console.draft, "")
        XCTAssertFalse(console.needsImageInput)
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
        XCTAssertEqual(OutcomeText.line(for: .rejected(.modeChanged(expected: "review", actual: "capture"))).detail,
                       "Typed in review, but the mode is now capture; not sent")
        XCTAssertEqual(OutcomeText.line(for: .failed(route: .escalated, message: "down")).detail, "escalated: down")
        XCTAssertEqual(OutcomeText.line(for: .cancelled(route: .onDevice)).detail, "onDevice generation cancelled")
        XCTAssertEqual(OutcomeText.reason(.modelUnavailable(.appleIntelligenceNotEnabled)),
                       "on-device model unavailable (Apple Intelligence off)")
        XCTAssertEqual(OutcomeText.reason(.offline), "offline")
        XCTAssertEqual(OutcomeText.reason(.noEscalationModelConfigured), "no cloud model configured")
    }
}
