@testable import AssistantModes
@testable import AssistantModesUI
import XCTest

final class EvaluationTests: XCTestCase {
    /// The house eval: the contract every graph change and every model swap must keep.
    static let privacyAndCarryOver = EvalCase(name: "privacy + carry-over", steps: [
        .write(Fixture.topic, .text("Trip"), expect: .succeeds),
        .write(Fixture.steps, .list(["x"]), expect: .fails),
        .send("note: passport", expect: .onDevice),
        .transition(to: "review", expect: .fails),
        .transition(to: "plan", expect: .succeeds),
        .expectState(Fixture.topic, .text("Trip")),
        .write(Fixture.steps, .list(["book flights"]), expect: .succeeds),
        .transition(to: "review", expect: .succeeds),
        .send("check this screenshot", needs: [.imageInput], expect: .refused(.modeForbidsEscalation)),
        .transition(to: "capture", expect: .succeeds),
        .expectState(Fixture.topic, nil),
        .setCloudConsent(false),
        .send("what is in this photo?", needs: [.imageInput], expect: .refused(.noCloudConsent)),
        .setCloudConsent(true),
        .setOnline(false),
        .send("what is in this photo?", needs: [.imageInput], expect: .refused(.offline)),
        .setOnline(true),
        .send("what is in this photo?", needs: [.imageInput], expect: .escalated),
        .send("   ", expect: .rejected),
    ])

    func testHouseEvalPassesOnAppleTV() async throws {
        let result = await EvalRunner.run(Self.privacyAndCarryOver, on: try Fixture.engine(profile: Fixture.appleTV))
        XCTAssertEqual(result.failures, [])
        XCTAssertTrue(result.passed)
        XCTAssertEqual(result.stepsRun, Self.privacyAndCarryOver.steps.count)
    }

    /// The eval must fail against a broken configuration: here review mode wrongly allows escalation,
    /// so the private screenshot would go to the cloud. If this test ever passes with zero failures,
    /// the eval has stopped guarding the privacy rule.
    func testHouseEvalCatchesAReviewModeThatLeaksToTheCloud() async throws {
        let broken = try Fixture.engine(profile: Fixture.appleTV, reviewEscalation: .allowed)
        let result = await EvalRunner.run(Self.privacyAndCarryOver, on: broken)
        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.failures.map(\.stepIndex), [8])
        XCTAssertEqual(result.failures.first?.actual, "escalated")
    }

    /// The same eval on iPhone fails exactly where the platforms differ: images run on-device there.
    func testHouseEvalReportsThePlatformDifferenceOnIPhone() async throws {
        let result = await EvalRunner.run(Self.privacyAndCarryOver, on: try Fixture.engine(profile: Fixture.iPhone))
        XCTAssertEqual(result.failures.map(\.stepIndex), [8, 12, 15, 17])
        XCTAssertTrue(result.failures.allSatisfy { $0.actual == "on-device" })
    }

    func testAnEmptyEvalCaseDoesNotCountAsPassing() async throws {
        let result = await EvalRunner.run(EvalCase(name: "empty", steps: []), on: try Fixture.engine())
        XCTAssertFalse(result.passed)
    }

    func testModelFailuresNeverMatchAnyExpectation() async throws {
        struct Boom: Error {}
        let engine = try Fixture.engine(onDevice: ClosureModel { _ in throw Boom() })
        let result = await EvalRunner.run(EvalCase(name: "boom", steps: [.send("x", expect: .onDevice)]), on: engine)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.failures.first?.actual.hasPrefix("failed") ?? false)
    }

    // MARK: Stability probe

    private let request = ModelRequest(mode: "plan", instructions: "i", stateBlock: "", history: [], prompt: "p")

    func testAlternatingOutputsGiveFiftyPercentAgreement() async {
        let calls = Counter()
        let report = await StabilityProbe.measure(runs: 4, request: request) { _ in
            await calls.increment()
            return await calls.value.isMultiple(of: 2) ? "A" : "B"
        }
        XCTAssertEqual(report, StabilityReport(runs: 4, failures: 0, distinctOutputs: 2, modalCount: 2))
        XCTAssertEqual(report.agreement, 0.5)
    }

    func testNormalisationMergesWhitespaceAndCaseVariants() async {
        let outputs = ["Yes", " yes\n", "YES"]
        let calls = Counter()
        let report = await StabilityProbe.measure(runs: 3, request: request) { _ in
            await calls.increment()
            let index = await calls.value - 1
            return outputs.indices.contains(index) ? outputs[index] : ""
        }
        XCTAssertEqual(report.distinctOutputs, 1)
        XCTAssertEqual(report.agreement, 1)
    }

    func testFailuresCountAgainstAgreement() async {
        struct Boom: Error {}
        let calls = Counter()
        let report = await StabilityProbe.measure(runs: 4, request: request) { _ in
            await calls.increment()
            if await calls.value <= 2 { throw Boom() }
            return "same"
        }
        XCTAssertEqual(report.failures, 2)
        XCTAssertEqual(report.agreement, 0.5)
    }

    func testRunCountIsClampedToOneThroughMax() async {
        let low = await StabilityProbe.measure(runs: 0, request: request) { _ in "x" }
        XCTAssertEqual(low.runs, 1)
        let negative = await StabilityProbe.measure(runs: Int.min, request: request) { _ in "x" }
        XCTAssertEqual(negative.runs, 1)
        let high = await StabilityProbe.measure(runs: Int.max, request: request) { _ in "x" }
        XCTAssertEqual(high.runs, StabilityProbe.maxRuns)
    }

    func testAllFailuresGiveZeroAgreementWithoutDividingByZero() async {
        struct Boom: Error {}
        let report = await StabilityProbe.measure(runs: 3, request: request) { _ in throw Boom() }
        XCTAssertEqual(report.modalCount, 0)
        XCTAssertEqual(report.agreement, 0)
    }

    // MARK: UI copy

    func testOutcomeCopyNamesBothReasonsForARefusal() {
        let line = OutcomeText.line(for: .refused(.missingCapabilities([.imageInput]), .modeForbidsEscalation))
        XCTAssertEqual(line.badge, "REFUSED")
        XCTAssertEqual(line.detail, "this device lacks imageInput; this mode never leaves the device")
        XCTAssertEqual(line.tone, .blocked)
    }

    func testOutcomeCopyForAnEscalatedAnswerShowsTheBudget() {
        let plan = ContextPlan(includedTurns: [], droppedTurnCount: 2, estimatedTokens: 512, budget: 100_000)
        let line = OutcomeText.line(for: .answered(text: "hi", route: .escalated, plan: plan))
        XCTAssertEqual(line.badge, "CLAUDE")
        XCTAssertEqual(line.detail, "hi\n~512/100000 tokens · 2 old turn(s) left out")
        XCTAssertEqual(OutcomeText.escalationReason(for: .escalate(because: .overBudget(fixed: 900, budget: 400))),
                       "needs ~900 tokens, mode budget is 400")
        XCTAssertNil(OutcomeText.escalationReason(for: .onDevice(plan)))
        XCTAssertNil(OutcomeText.escalationReason(for: nil))
    }

    func testLatencyCopyShowsSubMillisecondTurnsAsLessThanOne() {
        XCTAssertEqual(OutcomeText.latency(0), "<1 ms")
        XCTAssertEqual(OutcomeText.latency(999_999), "<1 ms")
        XCTAssertEqual(OutcomeText.latency(1_000_000), "1 ms")
        XCTAssertEqual(OutcomeText.latency(4_726_000_000), "4726 ms")
        XCTAssertEqual(OutcomeText.latency(UInt64.max), "\(UInt64.max / 1_000_000) ms")
    }

    func testOutcomeCopyForADiscardedAnswerNamesBothModes() {
        let line = OutcomeText.line(for: .discardedModeChanged(route: .onDevice, startedIn: "capture", nowIn: "plan"))
        XCTAssertEqual(line.badge, "DISCARDED")
        XCTAssertEqual(line.detail, "Generation started in capture was interrupted by the switch to plan; nothing from it is shown")
    }
}
