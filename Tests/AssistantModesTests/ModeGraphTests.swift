@testable import AssistantModes
import XCTest

final class ModeGraphTests: XCTestCase {
    private func mode(
        _ id: ModeID, budget: Int = 100, instructions: String = "Do the thing.",
        writable: Set<StateKey> = [], transitions: [ModeID: Set<StateKey>] = [:]
    ) -> ModeDefinition {
        ModeDefinition(id: id, title: id.rawValue, instructions: instructions,
                       contextBudget: budget, writableKeys: writable, transitions: transitions)
    }

    private func assertGraphError(_ expected: ModeGraphError, initial: ModeID = "a", _ modes: [ModeDefinition],
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ModeGraph(initialMode: initial, modes: modes), file: file, line: line) { error in
            XCTAssertEqual(error as? ModeGraphError, expected, file: file, line: line)
        }
    }

    func testFixtureGraphIsValidAndOrdered() throws {
        let graph = try Fixture.graph()
        XCTAssertEqual(graph.initialMode, "capture")
        XCTAssertEqual(graph.orderedIDs, ["capture", "plan", "review"])
    }

    func testEmptyGraphIsRejected() {
        assertGraphError(.noModes, [])
    }

    func testDuplicateModeIsRejected() {
        assertGraphError(.duplicateMode("a"), [mode("a"), mode("a")])
    }

    func testUnknownInitialModeIsRejected() {
        assertGraphError(.unknownInitialMode("missing"), initial: "missing", [mode("a")])
    }

    func testTransitionToUnknownModeIsRejected() {
        assertGraphError(.unknownTransitionTarget(from: "a", to: "ghost"), [mode("a", transitions: ["ghost": []])])
    }

    func testSelfTransitionIsRejected() {
        assertGraphError(.selfTransition("a"), [mode("a", transitions: ["a": []])])
    }

    func testZeroAndNegativeBudgetsAreRejected() {
        assertGraphError(.nonPositiveBudget("a"), [mode("a", budget: 0)])
        assertGraphError(.nonPositiveBudget("a"), [mode("a", budget: -5)])
        assertGraphError(.nonPositiveBudget("a"), [mode("a", budget: Int.min)])
    }

    func testWhitespaceOnlyInstructionsAreRejected() {
        assertGraphError(.emptyInstructions("a"), [mode("a", instructions: " \n\t")])
        assertGraphError(.emptyInstructions("a"), [mode("a", instructions: "")])
    }

    func testCarryingAKeyNoModeCanWriteIsRejected() {
        assertGraphError(
            .carriedKeyNeverWritable(from: "a", to: "b", key: "tpoic"),
            [mode("a", writable: ["topic"], transitions: ["b": ["topic", "tpoic"]]), mode("b", transitions: ["a": []])]
        )
    }

    func testModeUnreachableFromTheInitialModeIsRejected() {
        assertGraphError(.unreachableMode("island"), [mode("a"), mode("island", transitions: ["a": []])])
    }

    /// State written in a private mode must not be carried into a mode that may escalate, or the
    /// next escalation would send it to the cloud.
    func testCarryingStateOutOfAPrivateModeIntoAnEscalatingModeIsRejected() {
        let drafts = ModeDefinition(id: "drafts", title: "Drafts", instructions: "Private drafts.", contextBudget: 100,
                                    writableKeys: ["draft"], escalation: .forbidden, transitions: ["a": ["draft"]])
        assertGraphError(.carriesStateOutOfPrivateMode(from: "drafts", to: "a", keys: ["draft"]),
                         [mode("a", transitions: ["drafts": []]), drafts])
    }

    func testStateMayFlowIntoAPrivateModeAndBetweenPrivateModes() throws {
        let p1 = ModeDefinition(id: "p1", title: "P1", instructions: "Private.", contextBudget: 100,
                                writableKeys: ["x"], escalation: .forbidden, transitions: ["p2": ["x"], "a": []])
        let p2 = ModeDefinition(id: "p2", title: "P2", instructions: "Private.", contextBudget: 100,
                                escalation: .forbidden, transitions: ["a": []])
        XCTAssertNoThrow(try ModeGraph(initialMode: "a", modes: [
            mode("a", writable: ["x"], transitions: ["p1": ["x"]]), p1, p2,
        ]))
    }

    func testMissingCapabilitiesComparesRequirementsAgainstTheProfile() throws {
        let graph = try Fixture.graph()
        XCTAssertEqual(graph.missingCapabilities(for: "plan", on: Fixture.iPhone), [])
        let bare = PlatformProfile(name: "bare", capabilities: [.onDeviceText], onDeviceContextTokens: 4096)
        XCTAssertEqual(graph.missingCapabilities(for: "plan", on: bare), [.guidedGeneration])
        XCTAssertEqual(graph.missingCapabilities(for: "unknown", on: bare), [])
    }

    func testPlatformProfileClampsANegativeContextWindowToZero() {
        XCTAssertEqual(PlatformProfile(name: "x", capabilities: [], onDeviceContextTokens: -1).onDeviceContextTokens, 0)
    }

    func testAppleTVPresetHasNoImagesAdaptersOrPrivateCloudCompute() {
        let tv = PlatformProfile.appleTV(contextTokens: 4096)
        XCTAssertFalse(tv.capabilities.contains(.imageInput))
        XCTAssertFalse(tv.capabilities.contains(.adapters))
        XCTAssertFalse(tv.capabilities.contains(.privateCloudCompute))
        XCTAssertTrue(tv.capabilities.contains(.onDeviceText))
    }
}
