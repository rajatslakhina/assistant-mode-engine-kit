# AssistantModes

**One on-device assistant, several modes, and the rules that keep them apart.** A Swift package for building a multi-mode AI assistant on Apple's on-device model. Each mode activates its own group of instructions and its own token budget. Session state crosses a mode switch only where the graph says it may. A typed router keeps work on-device and sends it to Claude only when the device can't do it, and only if the mode, the user's consent and the network all allow it.

[![CI](https://github.com/rajatslakhina/assistant-mode-engine-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/rajatslakhina/assistant-mode-engine-kit/actions/workflows/ci.yml)
![Swift 6](https://img.shields.io/badge/Swift-6-orange) ![iOS 17+ · macOS 14+](https://img.shields.io/badge/iOS%2017%2B%20%C2%B7%20macOS%2014%2B-blue) ![License: MIT](https://img.shields.io/badge/license-MIT-lightgrey)

Demo app: (added after the companion repo is pushed — see below)

<img src="docs/system-model.png" width="300" align="right" alt="The demo app on an iOS 27.2 Simulator: Apple's on-device model answering in plan mode from carried-over state, and below it an over-budget prompt escalated to Claude after consent was granted">

```mermaid
flowchart LR
  capture -- "carries topic, notes" --> plan
  plan -- "carries topic, steps" --> review["review (private)"]
  plan -- "carries topic" --> capture
  review -- "carries nothing" --> capture
```

```mermaid
flowchart LR
  P["send(prompt)"] --> B["ContextBudgeter<br/>(active mode's budget)"] --> R{RoutePolicy}
  R -- "capable, available, fits" --> D["On-device model"]
  R -- "blocked on-device, and mode allows, consent, online" --> C["Claude (your server)"]
  R -- "otherwise" --> X["Refused, with both reasons"]
```

## Why this matters

Apple's on-device model has a small context window and different capabilities on different hardware: as reported in a diff of the Xcode 27.3 beta SDK interface ([Foundation-Models-Framework-Lab PR #226](https://github.com/rudrankriyam/Foundation-Models-Framework-Lab/pull/226)), tvOS gets the system model without Private Cloud Compute, adapters or image input. The same SDK diff shows Apple moving towards *instruction groups* that switch on and off with app context. In a real app that raises questions a tutorial skips:

- When the user switches from "capture" to "plan", which instructions leave the context, and which facts come along?
- Who decides that a private mode never goes to the cloud, and where is that rule enforced, in a prompt or in code?
- What happens when the answer to a capture-mode prompt arrives *after* the user has already moved to plan mode?
- On Apple TV, what happens to a request that needs image input?

This package answers each of these in code, with a test that fails if the answer is broken.

## What's in it

| Type | Role |
|---|---|
| `ModeGraph`, `ModeDefinition` | The mode state machine. Construction throws on unknown targets, self-transitions, non-positive budgets, empty instructions, carried keys no mode can write (typos), modes unreachable from the initial one, and any transition that carries state out of a private mode into one that may escalate. If you hold a `ModeGraph`, those invariants hold. |
| `SessionState`, `StateKey`, `StateValue` | Typed state shared by the UI and the model. Each mode declares the only keys it may write. Each transition declares the only keys that survive it; everything else is cleared. Rendering is sorted, so the same state always produces the same prompt text. |
| `ContextBudgeter`, `TokenEstimator` | Fits instructions, state, history and the prompt into the active mode's budget. It also charges for the headers and `User:`/`Assistant:` prefixes the prompt adds, so the plan covers what is actually sent. Overflow never "fits". The engine also keeps a response reserve (1,024 tokens by default) free in the on-device window, because that window holds the answer too. |
| `PlatformProfile`, `Capability` | The per-platform capability matrix and context window. `iPhone(...)` and `appleTV(...)` presets. |
| `RoutePolicy`, `RouteDecision` | A pure decision table: `onDevice(plan)`, `escalate(because:)` or `refuse(because:blockedBy:)`. A request declares the capabilities it needs (for example `.imageInput`); carrying the image itself is the app's job. |
| `AssistantEngine` (actor) | Owns the active mode, state, transcript and records. Every way a turn can end is a `TurnOutcome`. Records outlive the transcript, so their plans keep counts and token estimates but not the turns sent; non-private answers and failure messages are kept, private-mode ones are redacted. |
| `EvalRunner`, `EvalCase` | Scripted transition and routing evals that run against any backend. The tests run a 19-step house eval against a scripted model; the demo's `-scenario eval -systemModel` runs a 15-step variant, on its own graph, against Apple's model. |
| `StabilityProbe` | Sends one request N times and reports agreement, to measure how much the real model's output drifts. The demo repo shows a real run against Apple's model. |
| `SystemModelBackend` | `OnDeviceModel` backed by Foundation Models' `SystemLanguageModel` (compiled where the SDK has it, iOS/macOS 26+). |
| `AssistantModesUI` | `AssistantConsoleView`, an inspector that shows each turn's route and the reason for it, the active mode's conversation, and the session state. |

## Design decisions and trade-offs

**Per-mode transcripts, explicit carried state.** A mode switch clears the transcript and keeps only the keys that transition declares. *Rejected:* one shared transcript across modes. It is simpler, but the previous mode's instructions and answers bleed into the next mode's context, and the budget becomes impossible to reason about. The cost: a user who goes back to capture starts that conversation fresh, apart from whatever state was carried.

**Privacy rules live in the graph, not in a prompt.** `EscalationRule.forbidden` is enforced by `RoutePolicy` before any model is called: a request sent from a private mode never reaches the escalation model. A prompt typed in a private mode can't be escalated from the next mode either: `send(_:needs:expectedMode:)` rejects it with `.modeChanged` if a switch lands first, and the bundled console view model pins the mode for every send and write and blocks input while a switch is in flight. `ModeGraph` closes the other path too: it refuses any transition that carries state out of a private mode into a mode that may escalate, so state written in a private mode can't leak through the next mode's escalation. A prompt that says "don't send this to the cloud" is a request to a model; these are branches the code can't take.

**One blocker, in a fixed priority order.** A missing capability is reported first, because no amount of waiting fixes it. Then model availability, which may fix itself. Then budget, which depends on this one prompt. Escalation gates are also ordered: the mode rule (a product decision), then consent (the user's), then connectivity (circumstance), then configuration (ours). The UI can always say exactly why.

**No silent failover.** If the on-device model throws, the turn is reported as `.failed`; it is not retried on Claude. An on-device refusal may be a guardrail, and retrying it elsewhere would route around it. *Rejected:* automatic cloud fallback, which hides both guardrail hits and on-device outages from the people who need to see them.

**History is trimmed as a contiguous suffix.** Oldest turns go first, and an old short turn is never kept after a newer long one was dropped. *Rejected:* greedy "fit whatever fits", which can produce a transcript with a hole in it, and that reads to the model as a different conversation.

**State goes in the prompt, never in the instructions.** Session state is user-supplied, so `SystemModelBackend` puts only the developer-written mode instructions in the session's instructions slot. User text is also indented on every continuation line (any Unicode line break counts, and each is normalised to LF), so a value can't start a line that looks like a `[key]` header or a `User:` label. That makes forged structure harder; it does not prevent prompt injection.

**A conservative token estimator.** By default the estimator divides UTF-8 bytes by 3 and rounds up. That over-counts English (about 4 characters per token) and lands near one token per character for CJK. Over-counting is the safe direction: being wrong costs one more dropped turn, not an overflowed context window. Swap in a real tokenizer through `TokenEstimator`.

## Concurrency contract

`AssistantEngine` is an actor, and actors give mutual exclusion *between* suspension points, not across them. `send` has exactly one `await` (the model call), and it is guarded explicitly:

- Everything the routing decision reads is captured before the `await`. `OnDeviceModel.availability` is synchronous on purpose, so the decision can't interleave with a mode switch.
- The model call runs in an unstructured `Task` the engine holds. It doesn't inherit the caller's cancellation, so `send` forwards it with `withTaskCancellationHandler`. `transition(to:)` may run while it is suspended: it cancels that call, frees the engine so the new mode can send at once, and bumps an epoch. An answer that still comes back is reported as `.discardedModeChanged` instead of being added to the new mode's transcript. Switching away and straight back still discards, because the context the answer was built from is gone.
- A second `send` during a generation is rejected with `.busy`, not queued or interleaved.
- A send or state write can name the mode it was made in (`expectedMode`). If a switch landed first, it is rejected (`.modeChanged`) instead of being applied under the new mode's rules.
- Cancelling the caller's task cancels the model call and ends the turn as `.cancelled`. If the backend ignores cancellation and answers anyway, the answer is not kept. A caller that is already cancelled when it calls `send` gets nothing dispatched.
- A stale call that finishes after a switch can't free the new mode's call: each call has an id, and only the call that owns the in-flight slot clears it.

## Honest limits

- **Apple's own instruction-group APIs are not used.** The Xcode 27.2 SDK used here already ships `DynamicInstructions` and `LanguageModelSession.DynamicProfile` (with `onActivate`/`onDeactivate`) for iOS 27; the 27.3 beta SDK diff adds `DynamicInstructionsGroup` and `@SessionState`, which are not in 27.2. The engine doesn't build on them for two reasons: they require iOS 27 while this package targets iOS 17, and they shape one Foundation Models session, while the engine's rules (budgets, carried state, privacy, routing) have to hold across two backends, Apple's model and the cloud one. Mapping a mode to a `DynamicProfile` inside `SystemModelBackend` on iOS 27 is a natural next step and an adapter change, not a redesign.
- **The platform presets are data, not verified facts.** `appleTV(...)` encodes what the SDK diff reports. It has not been checked on Apple TV hardware. Override the presets with what your target OS actually ships.
- **Token counts are estimates.** The budget is an upper bound only for estimators that round each piece up, like the default. Foundation Models has a real tokenizer (`tokenCount(for:)`, iOS 26.4+) and reports the real window (`SystemLanguageModel.contextSize`), but `tokenCount` is `async`, and the routing decision is taken synchronously inside one actor step so it can't interleave with a mode switch. Calibrate `bytesPerToken` against `tokenCount` offline, and pass `contextSize` as the profile's `onDeviceContextTokens` (the demo's `-systemModel` run does).
- **Capabilities are routing declarations, not payloads.** `send(_:needs: [.imageInput])` decides where a request may go; the package does not carry image data, and image tokens are not budgeted. Carrying the attachment to the chosen backend is the app's job.
- **Escalation sends the active mode's instructions, state and history to your cloud model.** That is the point of escalating, so a mode with sensitive state should be `forbidden`, and consent should be explicit. Revoking consent does not recall a request already sent, and changing state during a generation does not cancel it. The escalation budget (`escalationContextTokens`, 100,000 by default) is input-only: set it to your cloud model's window minus your longest expected answer. The demo's Claude backend is simulated; a real one belongs behind your own server, never with an API key in the app.
- **Online and consent are caller-set flags.** There is no network monitoring, consent is one engine-wide boolean (not per mode or per request), and `TurnRecord` records the route and reason but not which data left the device.
- **Records keep ordinary answers in memory.** `TurnRecord`s keep each non-private answer's text and failure message (which may echo the request), but not the turns sent, until they age out of the `maxRecords` ring (200 by default); private-mode answers and failure messages are redacted. Clear or shrink the ring if that matters for your app. Memory is released, not zeroed; a call that a mode switch cancelled keeps its request until the backend returns (its result is then discarded); and whatever a caller keeps from `send`'s return value is outside the engine's control.
- **Prompt injection is not prevented.** User text never goes in the instructions slot and is fenced by indentation, but a model can still be talked into things by its prompt.
- **The evals check routing and state, not answer quality.** `StabilityProbe` measures how much the output varies, not whether it is correct, and its numbers change from run to run.
- **`SystemModelBackend` is not covered by unit tests.** CI compiles it (a `macos-26` job builds the package with the Foundation Models SDK) but can't run it: hosted runners have no Apple Intelligence. It was exercised in the demo app on an iOS 27.2 Simulator on a Mac with Apple Intelligence (see the demo repo).
- **No tvOS or watchOS build.** The package declares and CI builds iOS and macOS only; Apple TV is a capability profile, and `SystemModelBackend` is not compiled for tvOS or watchOS.

## Run it locally

```sh
git clone https://github.com/rajatslakhina/assistant-mode-engine-kit.git && cd assistant-mode-engine-kit
swift build -Xswiftc -warnings-as-errors && swift test
python3 Scripts/mutation_check.py   # rebuilds once per mutant; takes a few minutes
```

## Install

```swift
.package(url: "https://github.com/rajatslakhina/assistant-mode-engine-kit.git", from: "1.0.8")
```

```swift
import AssistantModes
import FoundationModels

let graph = try ModeGraph(initialMode: "capture", modes: [
    ModeDefinition(id: "capture", title: "Capture", instructions: "Turn what the user says into notes.",
                   contextBudget: 1200, writableKeys: ["topic", "notes"],
                   transitions: ["plan": ["topic", "notes"]]),
    ModeDefinition(id: "plan", title: "Plan", instructions: "Turn the notes into steps.",
                   requirements: [.onDeviceText, .guidedGeneration], contextBudget: 2000,
                   writableKeys: ["steps"], transitions: ["capture": ["topic"]]),
])
let onDevice: any OnDeviceModel
var window = 4096                            // fallback when the real window can't be read
if #available(iOS 26.0, macOS 26.0, *) {
    onDevice = SystemModelBackend()          // Apple's on-device model (needs an Xcode 26+ SDK)
    window = SystemLanguageModel.default.contextSize   // iOS 26.4 SDK API, back-deployed to 26.0
} else {
    onDevice = ClosureModel(availability: .unavailable(.deviceNotEligible)) { _ in "" }
}
let engine = try AssistantEngine(
    graph: graph,
    profile: .iPhone(contextTokens: window),
    onDevice: onDevice,
    escalation: myClaudeClient,              // your server-backed EscalationModel, or nil
    cloudConsent: false
)
try await engine.setState(.text("Lisbon trip"), for: "topic")
switch await engine.send("passport expires in March") {
case .answered(let text, let route, _): print(route, text)
case .refused(let why, let blockedBy): print(why, blockedBy)
default: break
}
```

## Verification

What has actually been run, and where:

- **CI** ([Actions](https://github.com/rajatslakhina/assistant-mode-engine-kit/actions/workflows/ci.yml)), on GitHub's hosted runners, four jobs on every push: three on `macos-15` (Xcode 16.4, Swift 6.1.2) and one on `macos-26`:
  - *Build + test*: `swift build` and `swift test`, both with `-warnings-as-errors`, from a clean checkout. 114 XCTest tests.
  - *iOS Simulator build*: both library targets built for `generic/platform=iOS Simulator` with warnings as errors.
  - *Foundation Models build*: on GitHub's `macos-26` runner, `swift build` with warnings as errors against an SDK that has Foundation Models, plus a check that `SystemModelBackend` was actually compiled in rather than skipped by `#if canImport`.
  - *Mutation check*: [`Scripts/mutation_check.py`](Scripts/mutation_check.py) applies 48 small, targeted mutants to the real source, one at a time (dropping the stale-answer epoch check, letting a private mode escalate, ignoring consent, letting overflow "fit", letting state escape a private mode, and so on). For each one it runs the test that is supposed to catch it, and the job fails if any mutant survives. All 48 are killed (a mutant that makes its test crash, such as an arithmetic trap, counts as caught).
- **Locally** (Xcode 27.2, macOS 27.2.1): the same clean build, 114 tests and 48/48 mutants. Here the Foundation Models SDK is present, so `SystemModelBackend` is compiled too.
- **On a Simulator**: the [demo app](#) was built against this package resolved from GitHub and run on an iOS 27.2 Simulator in every scenario, including `-systemModel` runs against Apple's on-device model. The screenshot above is from one of those runs.
- **Not run**: tvOS or Apple TV hardware, a physical iPhone, and a real Claude backend.

## License

MIT
