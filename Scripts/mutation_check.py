#!/usr/bin/env python3
"""Mutation check: break each load-bearing guard on purpose and prove a named test catches it.

Each mutant is a small, targeted edit to the real source. The script applies it, confirms the package still
compiles (a mutant that does not compile proves nothing), runs only the test that is supposed to
catch it, and restores the file. A mutant whose test still passes is a "survivor": that test was not
actually guarding the property, and the script exits non-zero.

Run from the package root:  python3 Scripts/mutation_check.py
"""
import pathlib
import re
import subprocess
import sys

SRC = pathlib.Path("Sources/AssistantModes")
T = "AssistantModesTests."

MUTANTS = [
    (
        "stale-answer-lands-in-new-mode",
        SRC / "AssistantEngine.swift",
        "guard modeEpoch == epoch else {",
        "guard modeEpoch == epoch || true else {",
        T + "EngineTests/testAnswerArrivingAfterModeSwitchIsDiscarded",
    ),
    (
        "second-send-interleaves",
        SRC / "AssistantEngine.swift",
        "guard !isGenerating else {",
        "guard !isGenerating || true else {",
        T + "EngineTests/testSecondSendWhileGeneratingIsRejected",
    ),
    (
        "transition-keeps-all-state",
        SRC / "AssistantEngine.swift",
        "let cleared = state.retainOnly(carried)",
        "let cleared: [StateKey] = []",
        T + "EngineTests/testTransitionKeepsOnlyCarriedKeys",
    ),
    (
        "transition-keeps-old-transcript",
        SRC / "AssistantEngine.swift",
        "        transcript.removeAll()\n",
        "\n",
        T + "EngineTests/testTransitionStartsNewModeWithEmptyTranscript",
    ),
    (
        "write-ignores-ownership",
        SRC / "AssistantEngine.swift",
        "guard activeDefinition.writableKeys.contains(key) else {",
        "guard activeDefinition.writableKeys.contains(key) || true else {",
        T + "EngineTests/testWriteToKeyTheModeDoesNotOwnIsRejected",
    ),
    (
        "transcript-grows-unbounded",
        SRC / "AssistantEngine.swift",
        "if overflow > 0 { transcript.removeFirst(overflow) }",
        "if false && overflow > 0 { transcript.removeFirst(overflow) }",
        T + "EngineTests/testTranscriptIsCappedToTheNewestTurns",
    ),
    (
        "records-grow-unbounded",
        SRC / "AssistantEngine.swift",
        "if overflow > 0 { records.removeFirst(overflow) }",
        "if false && overflow > 0 { records.removeFirst(overflow) }",
        T + "EngineTests/testRecordsAreARingOfTheNewestTurns",
    ),
    (
        "history-trim-skips-instead-of-stopping",
        SRC / "ContextBudget.swift",
        "            else { break }",
        "            else { continue }",
        T + "ContextBudgetTests/testHistoryIsTrimmedAsContiguousSuffix",
    ),
    (
        "overflow-counts-as-fitting",
        SRC / "ContextBudget.swift",
        "guard let next = Saturating.checkedSum([used, tokens(PromptScaffold.fence(turn.user)),\n                                                    tokens(PromptScaffold.fence(turn.assistant)),\n                                                    tokens(PromptScaffold.perTurnText)]),\n                  next <= budget",
        "guard let next = Optional(Saturating.sum([used, tokens(PromptScaffold.fence(turn.user)),\n                                                    tokens(PromptScaffold.fence(turn.assistant)),\n                                                    tokens(PromptScaffold.perTurnText)])),\n                  next <= budget",
        T + "ContextBudgetTests/testOverflowingEstimatesNeverFitAndNeverTrap",
    ),
    (
        "budget-ignores-prompt-scaffolding",
        SRC / "ContextBudget.swift",
        "tokens(PromptScaffold.fence(prompt)), tokens(PromptScaffold.fixedText)]",
        "tokens(PromptScaffold.fence(prompt))]",
        T + "EngineTests/testBudgetCoversEverythingTheModelIsSent",
    ),
    (
        "budget-ignores-per-turn-scaffolding",
        SRC / "ContextBudget.swift",
        "                                                    tokens(PromptScaffold.perTurnText)]),\n",
        "                                                    0]),\n",
        T + "ContextBudgetTests/testPerTurnScaffoldingIsCharged",
    ),
    (
        "graph-lets-private-state-escape",
        SRC / "ModeGraph.swift",
        "if definition.escalation == .forbidden, byID[target]?.escalation == .allowed, !carried.isEmpty {",
        "if false, definition.escalation == .forbidden, byID[target]?.escalation == .allowed, !carried.isEmpty {",
        T + "ModeGraphTests/testCarryingStateOutOfAPrivateModeIntoAnEscalatingModeIsRejected",
    ),
    (
        "transition-leaves-engine-busy",
        SRC / "AssistantEngine.swift",
        "        inFlight?.task.cancel()\n        inFlight = nil\n",
        "\n",
        T + "EngineTests/testTransitionFreesTheEngineForTheNewModeImmediately",
    ),
    (
        "caller-cancellation-ignored",
        SRC / "AssistantEngine.swift",
        "        if Task.isCancelled {",
        "        if false && Task.isCancelled {",
        T + "EngineTests/testCallerCancellationWinsEvenIfTheBackendIgnoresIt",
    ),
    (
        "escalates-without-a-cloud-model",
        SRC / "Routing.swift",
        "if !context.hasEscalationModel {",
        "if false && !context.hasEscalationModel {",
        T + "RoutePolicyTests/testMissingCloudModelBlocksEscalation",
    ),
    (
        "caller-cancel-not-propagated",
        SRC / "AssistantEngine.swift",
        "        } onCancel: {\n            task.cancel()\n        }",
        "        } onCancel: {\n        }",
        T + "EngineTests/testCancellingTheCallerCancelsTheModelCallAndFreesTheEngine",
    ),
    (
        "stale-call-frees-new-generation",
        SRC / "AssistantEngine.swift",
        "if inFlight?.id == generationID { inFlight = nil }",
        "inFlight = nil",
        T + "EngineTests/testAStaleCallFinishingDoesNotFreeTheNewModesGeneration",
    ),
    (
        "records-keep-private-answers",
        SRC / "AssistantEngine.swift",
        "let kept = isPrivate ? TurnRecord.redacted(characters: text.count) : text",
        "let kept = text",
        T + "EngineTests/testRecordsKeepNoTurnTextAndRedactPrivateAnswers",
    ),
    (
        "records-keep-private-failures",
        SRC / "AssistantEngine.swift",
        "        case .failed(let route, _) where isPrivate:",
        "        case .failed(let route, _) where false && isPrivate:",
        T + "EngineTests/testPrivateModeFailureMessagesAreRedactedInRecords",
    ),
    (
        "backend-cancellation-reported-as-failure",
        SRC / "AssistantEngine.swift",
        "case .failure(let error) where error is CancellationError:",
        "case .failure(let error) where false && error is CancellationError:",
        T + "EngineTests/testBackendCancellationErrorIsReportedAsCancelled",
    ),
    (
        "negative-reserve-accepted",
        SRC / "AssistantEngine.swift",
        "self.reservedResponseTokens = max(0, reservedResponseTokens)",
        "self.reservedResponseTokens = reservedResponseTokens",
        T + "EngineTests/testLimitsClampNonPositiveValuesToOne",
    ),
    (
        "fence-handles-only-lf",
        SRC / "Models.swift",
        "whereSeparator: \\.isNewline)",
        "whereSeparator: { $0 == \"\\n\" })",
        T + "ContextBudgetTests/testEveryKindOfLineBreakIsFencedAndNormalisedToLF",
    ),
    (
        "probe-ignores-cancellation",
        SRC / "Evaluation.swift",
        "            if Task.isCancelled { break }",
        "            if false && Task.isCancelled { break }",
        T + "EvaluationTests/testProbeStopsWhenCancelled",
    ),
    (
        "records-redact-every-failure",
        SRC / "AssistantEngine.swift",
        "        case .failed(let route, _) where isPrivate:",
        "        case .failed(let route, _) where true || isPrivate:",
        T + "EngineTests/testPrivateModeFailureMessagesAreRedactedInRecords",
    ),
    (
        "init-budget-check-traps",
        SRC / "AssistantEngine.swift",
        "if Saturating.add(definition.contextBudget, limits.reservedResponseTokens) > profile.onDeviceContextTokens {",
        "if definition.contextBudget + limits.reservedResponseTokens > profile.onDeviceContextTokens {",
        T + "EngineTests/testEngineRejectsAnIntMaxBudgetInsteadOfTrapping",
    ),
    (
        "ui-keeps-stale-send-active",
        pathlib.Path("Sources/AssistantModesUI") / "AssistantConsoleModel.swift",
        "            if activeSend == releasing { activeSend = nil } // the engine cancelled that call and is free\n",
        "\n",
        T + "ConsoleModelTests/testTransitionReleasesTheInFlightSendSoTheNewModeCanSend",
    ),
    (
        "eval-ignores-transition-result",
        SRC / "Evaluation.swift",
        "                if actual != expect {\n                    failures.append(EvalFailure(stepIndex: index, expected: \"transition",
        "                if false && actual != expect {\n                    failures.append(EvalFailure(stepIndex: index, expected: \"transition",
        T + "EvaluationTests/testTransitionWriteAndStateStepsReportFailures",
    ),
    (
        "eval-ignores-write-result",
        SRC / "Evaluation.swift",
        "                if actual != expect {\n                    failures.append(EvalFailure(stepIndex: index, expected: \"write",
        "                if false && actual != expect {\n                    failures.append(EvalFailure(stepIndex: index, expected: \"write",
        T + "EvaluationTests/testTransitionWriteAndStateStepsReportFailures",
    ),
    (
        "eval-ignores-state",
        SRC / "Evaluation.swift",
        "                if actual != expected {",
        "                if false && actual != expected {",
        T + "EvaluationTests/testTransitionWriteAndStateStepsReportFailures",
    ),
    (
        "ui-stale-send-releases-newer",
        pathlib.Path("Sources/AssistantModesUI") / "AssistantConsoleModel.swift",
        "if activeSend == id { activeSend = nil }",
        "activeSend = nil",
        T + "ConsoleModelTests/testAStaleSendFinishingDoesNotReleaseTheNewerSend",
    ),
    (
        "ui-send-reentrant",
        pathlib.Path("Sources/AssistantModesUI") / "AssistantConsoleModel.swift",
        "guard !isSending, !isTransitioning, !draft.allSatisfy(\\.isWhitespace), let mode = snapshot?.mode else { return }",
        "guard !isTransitioning, !draft.allSatisfy(\\.isWhitespace), let mode = snapshot?.mode else { return }",
        T + "ConsoleModelTests/testSendWhileSendingIsIgnoredAndKeepsTheDraft",
    ),
    (
        "send-ignores-expected-mode",
        SRC / "AssistantEngine.swift",
        "        if let expected = expectedMode, expected != mode {",
        "        if false, let expected = expectedMode, expected != mode {",
        T + "EngineTests/testPromptForAModeThatIsNoLongerActiveIsRejectedWithoutCallingAModel",
    ),
    (
        "write-ignores-expected-mode",
        SRC / "AssistantEngine.swift",
        "        if let expected = expectedMode, expected != currentMode {",
        "        if false, let expected = expectedMode, expected != currentMode {",
        T + "EngineTests/testStateWriteForAModeThatIsNoLongerActiveThrowsAndWritesNothing",
    ),
    (
        "ui-sends-during-transition",
        pathlib.Path("Sources/AssistantModesUI") / "AssistantConsoleModel.swift",
        "guard !isSending, !isTransitioning, !draft.allSatisfy(\\.isWhitespace), let mode = snapshot?.mode else { return }",
        "guard !isSending, !draft.allSatisfy(\\.isWhitespace), let mode = snapshot?.mode else { return }",
        T + "ConsoleModelTests/testSendIsIgnoredWhileTransitioning",
    ),
    (
        "ui-sends-blank-draft",
        pathlib.Path("Sources/AssistantModesUI") / "AssistantConsoleModel.swift",
        "guard !isSending, !isTransitioning, !draft.allSatisfy(\\.isWhitespace), let mode = snapshot?.mode else { return }",
        "guard !isSending, !isTransitioning, let mode = snapshot?.mode else { return }",
        T + "ConsoleModelTests/testSendWhileSendingIsIgnoredAndKeepsTheDraft",
    ),
    (
        "ui-writes-during-transition",
        pathlib.Path("Sources/AssistantModesUI") / "AssistantConsoleModel.swift",
        "        guard !isTransitioning, let mode = snapshot?.mode else { return }\n        do {\n            try await engine.setState",
        "        guard let mode = snapshot?.mode else { return }\n        do {\n            try await engine.setState",
        T + "ConsoleModelTests/testWriteIsIgnoredWhileTransitioning",
    ),
    (
        "ui-write-unpinned",
        pathlib.Path("Sources/AssistantModesUI") / "AssistantConsoleModel.swift",
        "try await engine.setState(value, for: key, expectedMode: mode)",
        "try await engine.setState(value, for: key, expectedMode: nil); _ = mode",
        T + "ConsoleModelTests/testWritePinsTheModeTheConsoleShowed",
    ),
    (
        "ui-send-unpinned",
        pathlib.Path("Sources/AssistantModesUI") / "AssistantConsoleModel.swift",
        "_ = await engine.send(prompt, needs: needs, expectedMode: mode)",
        "_ = await engine.send(prompt, needs: needs, expectedMode: nil); _ = mode",
        T + "ConsoleModelTests/testSendPinsTheModeTheConsoleShowed",
    ),
    (
        "ui-transition-reentrant",
        pathlib.Path("Sources/AssistantModesUI") / "AssistantConsoleModel.swift",
        "        guard !isTransitioning else { return }\n        isTransitioning = true",
        "        isTransitioning = true",
        T + "ConsoleModelTests/testSecondTransitionWhileTransitioningIsIgnored",
    ),
    (
        "private-mode-escalates",
        SRC / "Routing.swift",
        "if context.escalation == .forbidden {",
        "if false && context.escalation == .forbidden {",
        T + "RoutePolicyTests/testForbiddenModeNeverEscalatesEvenWithConsentAndNetwork",
    ),
    (
        "escalates-without-consent",
        SRC / "Routing.swift",
        "if !context.cloudConsent {",
        "if false && !context.cloudConsent {",
        T + "RoutePolicyTests/testNoConsentBlocksEscalation",
    ),
    (
        "escalates-offline",
        SRC / "Routing.swift",
        "if !context.isOnline {",
        "if false && !context.isOnline {",
        T + "RoutePolicyTests/testOfflineBlocksEscalation",
    ),
    (
        "ignores-missing-capabilities",
        SRC / "Routing.swift",
        "if !missing.isEmpty {",
        "if false && !missing.isEmpty {",
        T + "RoutePolicyTests/testMissingCapabilityIsReportedBeforeAvailabilityAndBudget",
    ),
    (
        "graph-accepts-unreachable-mode",
        SRC / "ModeGraph.swift",
        "if let orphan = byID.keys.sorted().first(where: { !reached.contains($0) }) {",
        "if false, let orphan = byID.keys.sorted().first(where: { !reached.contains($0) }) {",
        T + "ModeGraphTests/testModeUnreachableFromTheInitialModeIsRejected",
    ),
    (
        "saturating-add-wraps",
        SRC / "Vocabulary.swift",
        "if overflow { return rhs > 0 ? Int.max : Int.min }",
        "if false && overflow { return rhs > 0 ? Int.max : Int.min }",
        T + "ContextBudgetTests/testSaturatingAddClampsBothDirections",
    ),
    (
        "eval-ignores-route",
        SRC / "Evaluation.swift",
        "                if actual != expect {\n                    failures.append(EvalFailure(\n",
        "                if false && actual != expect {\n                    failures.append(EvalFailure(\n",
        T + "EvaluationTests/testHouseEvalCatchesAReviewModeThatLeaksToTheCloud",
    ),
]


def run(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(args, capture_output=True, text=True)


def main() -> int:
    killed, survivors, broken = [], [], []
    for name, path, old, new, test in MUTANTS:
        original = path.read_text()
        if original.count(old) != 1:
            broken.append(f"{name}: target text found {original.count(old)} times in {path}")
            print("INVALID  " + name, flush=True)
            continue
        try:
            path.write_text(original.replace(old, new))
            build = run("swift", "build", "--build-tests")
            if build.returncode != 0:
                broken.append(f"{name}: mutant does not compile\n{build.stdout[-2000:]}{build.stderr[-2000:]}")
                print("INVALID  " + name, flush=True)
                continue
            try:
                result = subprocess.run(["swift", "test", "--skip-build", "--filter", test],
                                        capture_output=True, text=True, timeout=300)
            except subprocess.TimeoutExpired:
                # A hang is not evidence that the test caught the mutant: report it as invalid.
                broken.append(f"{name}: {test!r} timed out (a test that hangs on a mutant must be fixed)")
                print("INVALID  " + name, flush=True)
                continue
            # A kill needs evidence: the filter matched at least one test and at least one test failed.
            # A typo in the filter, or a crash before the named test started, is reported as invalid, not as a kill.
            output = result.stdout + result.stderr
            counts = re.findall(r"Executed (\d+) tests?, with (\d+) failures?", output)
            method = test.rsplit("/", 1)[-1]
            if not counts and result.returncode != 0 and f"{method}]' started" in output:
                # The named test started and the process died (e.g. an arithmetic trap): caught.
                killed.append(f"{name} -> {test} (crashed)")
                print("KILLED   " + name + " (test crashed)", flush=True)
                continue
            if not counts or int(counts[-1][0]) == 0:
                broken.append(f"{name}: filter {test!r} ran no tests")
                print("INVALID  " + name, flush=True)
                continue
            caught = int(counts[-1][1]) > 0
            (killed if caught else survivors).append(f"{name} -> {test}")
            print(("KILLED   " if caught else "SURVIVED ") + name, flush=True)
        finally:
            path.write_text(original)

    total = len(MUTANTS)
    print(f"\nMutation check: {len(killed)}/{total} killed, {len(survivors)} survived, {len(broken)} invalid")
    for line in survivors:
        print(f"  SURVIVOR: {line}")
    for line in broken:
        print(f"  INVALID:  {line}")
    return 0 if len(killed) == total else 1


if __name__ == "__main__":
    sys.exit(main())
