/// Bounds on everything the engine keeps in memory.
public struct EngineLimits: Equatable, Sendable {
    /// Turns retained in the active mode's transcript; older ones are removed from it. (`TurnRecord`s
    /// keep counts and token estimates, not turn text; see `TurnRecord`.)
    public let maxTranscriptTurns: Int
    /// Turn records kept for inspection and evals (a ring: oldest first out).
    public let maxRecords: Int
    /// Input budget used when a turn escalates. Unlike the on-device path, no response reserve is
    /// subtracted: set this to your cloud model's window minus your longest expected answer.
    public let escalationContextTokens: Int
    /// Tokens of the on-device context window kept free for the model's answer. The on-device window
    /// holds input and output together, so every mode budget plus this reserve must fit inside it.
    /// 1,024 is this package's default, not an Apple figure; size it to your longest expected answer.
    public let reservedResponseTokens: Int

    public init(
        maxTranscriptTurns: Int = 32,
        maxRecords: Int = 200,
        escalationContextTokens: Int = 100_000,
        reservedResponseTokens: Int = 1024
    ) {
        self.maxTranscriptTurns = max(1, maxTranscriptTurns)
        self.maxRecords = max(1, maxRecords)
        self.escalationContextTokens = max(1, escalationContextTokens)
        self.reservedResponseTokens = max(0, reservedResponseTokens)
    }
}

public enum EngineError: Error, Equatable, Sendable {
    /// A mode's budget plus the response reserve is larger than the platform's on-device context window.
    case budgetExceedsContext(mode: ModeID, budget: Int, reserved: Int, context: Int)
    case unknownMode(ModeID)
    case illegalTransition(from: ModeID, to: ModeID)
    case keyNotWritable(key: StateKey, mode: ModeID)
}

public struct TransitionReport: Equatable, Sendable {
    public let from: ModeID
    public let to: ModeID
    public let carriedKeys: [StateKey]
    public let clearedKeys: [StateKey]
    public let droppedTranscriptTurns: Int
    /// What the new mode needs that this platform lacks: its requests will escalate or be refused.
    public let missingCapabilities: [Capability]
    /// True when a generation was in flight. It was cancelled, and if its answer still arrives it is
    /// discarded, not shown in the new mode.
    public let interruptedGeneration: Bool
}

public enum Route: String, Equatable, Sendable {
    case onDevice
    case escalated
}

public enum RejectionReason: Equatable, Sendable {
    case emptyPrompt
    /// One generation at a time: a second `send` while one is in flight is rejected, not queued.
    case busy
    case tooLargeEvenForEscalation(fixed: Int, budget: Int)
}

public enum TurnOutcome: Equatable, Sendable {
    case answered(text: String, route: Route, plan: ContextPlan)
    case refused(OnDeviceBlocker, EscalationBlocker)
    /// The mode changed while the call was in flight. The call was cancelled, and any result that
    /// still arrived was dropped: it belongs to a context that no longer exists.
    case discardedModeChanged(route: Route, startedIn: ModeID, nowIn: ModeID)
    case failed(route: Route, message: String)
    case cancelled(route: Route)
    case rejected(RejectionReason)
}

/// What the engine remembers about a finished turn, for inspection and evals.
///
/// Records outlive the transcript (they survive trimming and mode switches, up to `maxRecords`),
/// so they keep less: plans carry counts and token estimates but no turn text, and an answer or a
/// failure message from a private (`.forbidden`) mode is replaced by a redaction, so private text
/// doesn't linger in memory or in the UI after the user leaves that mode.
public struct TurnRecord: Equatable, Sendable {
    /// The text stored instead of an answer given in a private mode.
    public static func redacted(characters: Int) -> String { "[private answer: \(characters) characters, not kept]" }
    /// The message stored instead of a failure's text in a private mode.
    public static let redactedFailure = "[private failure, message not kept]"

    public let sequence: UInt64
    public let mode: ModeID
    public let decision: RouteDecision?
    public let outcome: TurnOutcome
    public let latencyNanoseconds: UInt64
}

/// A read-only copy of the engine's state, for UIs and evals.
public struct EngineSnapshot: Equatable, Sendable {
    public let profile: PlatformProfile
    public let mode: ModeID
    public let state: SessionState
    public let transcript: [Turn]
    public let records: [TurnRecord]
    public let cloudConsent: Bool
    public let isOnline: Bool
    public let isGenerating: Bool
}

/// The multi-mode assistant: one active instruction group at a time, session state that survives
/// transitions only where the graph says it should, and a router that keeps work on-device unless
/// the on-device model can't do it.
///
/// Concurrency contract. The actor gives mutual exclusion between suspension points, not across
/// them, so the one `await` in `send` is guarded explicitly:
/// - everything the routing decision reads is captured before the `await`;
/// - the model call runs in a child `Task` the engine holds; `transition(to:)` may run while it is
///   suspended, cancels it, frees the engine for the new mode at once, and bumps `modeEpoch`, so an
///   answer that still comes back is reported as `discardedModeChanged` instead of being appended
///   to the new mode's transcript;
/// - a second `send` during a generation is rejected with `.busy` rather than interleaved;
/// - if the caller's task is cancelled, the model call is cancelled too, and the turn ends as
///   `.cancelled` whether or not the backend honoured the cancellation; its answer is not kept.
public actor AssistantEngine {
    // Immutable and Sendable, so readable from any isolation domain without an await.
    public nonisolated let graph: ModeGraph
    public nonisolated let profile: PlatformProfile
    public nonisolated let limits: EngineLimits

    private let onDevice: any OnDeviceModel
    private let escalationModel: (any EscalationModel)?
    private let budgeter: ContextBudgeter
    private let clock: any MonotonicClock

    public private(set) var currentMode: ModeID
    public private(set) var state = SessionState()
    public private(set) var transcript: [Turn] = []
    public private(set) var records: [TurnRecord] = []
    public private(set) var cloudConsent: Bool
    public private(set) var isOnline: Bool
    /// True while a model call started by `send` is in flight in the current mode.
    public var isGenerating: Bool { inFlight != nil }

    private var activeDefinition: ModeDefinition
    private var modeEpoch: UInt64 = 0
    private var nextSequence: UInt64 = 0
    private var nextGenerationID: UInt64 = 0
    private var inFlight: (id: UInt64, task: Task<String, any Error>)?

    public init(
        graph: ModeGraph,
        profile: PlatformProfile,
        onDevice: any OnDeviceModel,
        escalation: (any EscalationModel)? = nil,
        estimator: any TokenEstimator = ConservativeTokenEstimator(),
        clock: any MonotonicClock = SystemMonotonicClock(),
        limits: EngineLimits = EngineLimits(),
        cloudConsent: Bool = false,
        isOnline: Bool = true
    ) throws {
        for id in graph.orderedIDs {
            guard let definition = graph.definition(id) else { continue }
            if Saturating.add(definition.contextBudget, limits.reservedResponseTokens) > profile.onDeviceContextTokens {
                throw EngineError.budgetExceedsContext(
                    mode: id, budget: definition.contextBudget, reserved: limits.reservedResponseTokens,
                    context: profile.onDeviceContextTokens
                )
            }
        }
        guard let initial = graph.definition(graph.initialMode) else {
            // ModeGraph's initializer guarantees this; thrown rather than force-unwrapped.
            throw EngineError.unknownMode(graph.initialMode)
        }
        self.activeDefinition = initial
        self.graph = graph
        self.profile = profile
        self.limits = limits
        self.onDevice = onDevice
        self.escalationModel = escalation
        self.budgeter = ContextBudgeter(estimator: estimator)
        self.clock = clock
        self.currentMode = graph.initialMode
        self.cloudConsent = cloudConsent
        self.isOnline = isOnline
    }

    public func snapshot() -> EngineSnapshot {
        EngineSnapshot(
            profile: profile, mode: currentMode, state: state, transcript: transcript, records: records,
            cloudConsent: cloudConsent, isOnline: isOnline, isGenerating: isGenerating
        )
    }

    public func setCloudConsent(_ granted: Bool) { cloudConsent = granted }
    public func setOnline(_ online: Bool) { isOnline = online }

    /// Writes one state slot. Only keys the active mode declares writable are accepted, so the UI
    /// can't leave a value behind that the next mode's instructions never mention.
    public func setState(_ value: StateValue?, for key: StateKey) throws {
        guard activeDefinition.writableKeys.contains(key) else {
            throw EngineError.keyNotWritable(key: key, mode: currentMode)
        }
        state.set(value, for: key)
    }

    /// Deactivates the current instruction group and activates `target`'s.
    @discardableResult
    public func transition(to target: ModeID) throws -> TransitionReport {
        guard let next = graph.definition(target) else { throw EngineError.unknownMode(target) }
        guard let carried = activeDefinition.transitions[target] else {
            throw EngineError.illegalTransition(from: currentMode, to: target)
        }
        let cleared = state.retainOnly(carried)
        let dropped = transcript.count
        let interrupted = inFlight != nil
        inFlight?.task.cancel()
        inFlight = nil
        transcript.removeAll()
        modeEpoch &+= 1
        let from = currentMode
        currentMode = target
        activeDefinition = next
        return TransitionReport(
            from: from,
            to: target,
            carriedKeys: state.values.keys.sorted(),
            clearedKeys: cleared,
            droppedTranscriptTurns: dropped,
            missingCapabilities: graph.missingCapabilities(for: target, on: profile),
            interruptedGeneration: interrupted
        )
    }

    /// Sends one prompt in the active mode. Never throws: every way a turn can end is a `TurnOutcome`,
    /// and every outcome is recorded.
    public func send(_ prompt: String, needs: Set<Capability> = []) async -> TurnOutcome {
        let start = clock.nowNanoseconds()
        let mode = currentMode
        let definition = activeDefinition
        guard !prompt.allSatisfy(\.isWhitespace) else {
            return finish(.rejected(.emptyPrompt), mode: mode, decision: nil, start: start)
        }
        guard !isGenerating else {
            return finish(.rejected(.busy), mode: mode, decision: nil, start: start)
        }

        let localPlan = budgeter.plan(
            instructions: definition.instructions, state: state, history: transcript,
            prompt: prompt, budget: definition.contextBudget
        )
        let decision = RoutePolicy.decide(RouteContext(
            modeRequirements: definition.requirements,
            requestNeeds: needs,
            profile: profile,
            availability: onDevice.availability,
            budgetResult: localPlan,
            escalation: definition.escalation,
            cloudConsent: cloudConsent,
            isOnline: isOnline,
            hasEscalationModel: escalationModel != nil
        ))

        let route: Route
        let plan: ContextPlan
        let responder: @Sendable (ModelRequest) async throws -> String
        switch decision {
        case .refuse(let blocker, let escalationBlocker):
            return finish(.refused(blocker, escalationBlocker), mode: mode, decision: decision, start: start)
        case .onDevice(let fitted):
            let model = onDevice
            route = .onDevice
            plan = fitted
            responder = { try await model.respond(to: $0) }
        case .escalate(let blocker):
            guard let model = escalationModel else {
                // RoutePolicy already checked `hasEscalationModel`; this binding just avoids a force-unwrap.
                return finish(.refused(blocker, .noEscalationModelConfigured), mode: mode, decision: decision, start: start)
            }
            switch budgeter.plan(
                instructions: definition.instructions, state: state, history: transcript,
                prompt: prompt, budget: limits.escalationContextTokens
            ) {
            case .success(let fitted):
                plan = fitted
            case .failure(.fixedPartExceedsBudget(let fixed, let budget)):
                return finish(.rejected(.tooLargeEvenForEscalation(fixed: fixed, budget: budget)),
                              mode: mode, decision: decision, start: start)
            }
            route = .escalated
            responder = { try await model.respond(to: $0) }
        }

        let request = ModelRequest(
            mode: mode, instructions: definition.instructions, stateBlock: state.rendered,
            history: plan.includedTurns, prompt: prompt
        )
        let epoch = modeEpoch
        let generationID = nextGenerationID
        nextGenerationID &+= 1
        let task = Task { try await responder(request) }
        inFlight = (generationID, task)
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }
        // ---- Suspension point above: re-read every piece of actor state from here on. ----
        // Only clear `inFlight` if it is still ours: a transition may have cleared it and a newer
        // send in the new mode may own it now.
        if inFlight?.id == generationID { inFlight = nil }

        guard modeEpoch == epoch else {
            return finish(.discardedModeChanged(route: route, startedIn: mode, nowIn: currentMode),
                          mode: mode, decision: decision, start: start)
        }
        if Task.isCancelled {
            // The caller gave up. Even if the backend ignored cancellation and answered, the answer
            // is not appended: nobody is waiting for it.
            return finish(.cancelled(route: route), mode: mode, decision: decision, start: start)
        }
        switch result {
        case .success(let text):
            transcript.append(Turn(user: prompt, assistant: text))
            let overflow = transcript.count - limits.maxTranscriptTurns
            if overflow > 0 { transcript.removeFirst(overflow) }
            return finish(.answered(text: text, route: route, plan: plan), mode: mode, decision: decision, start: start)
        case .failure(let error) where error is CancellationError:
            return finish(.cancelled(route: route), mode: mode, decision: decision, start: start)
        case .failure(let error):
            // No silent failover to the cloud: an on-device refusal may be a guardrail, and retrying
            // it elsewhere would route around that guardrail. The caller decides.
            return finish(.failed(route: route, message: String(describing: error)),
                          mode: mode, decision: decision, start: start)
        }
    }

    private func finish(_ outcome: TurnOutcome, mode: ModeID, decision: RouteDecision?, start: UInt64) -> TurnOutcome {
        let end = clock.nowNanoseconds()
        let isPrivate = graph.definition(mode)?.escalation == .forbidden
        records.append(TurnRecord(
            sequence: nextSequence,
            mode: mode,
            decision: decision.map(Self.withoutTurnText),
            outcome: Self.recordable(outcome, isPrivate: isPrivate),
            latencyNanoseconds: end >= start ? end - start : 0
        ))
        nextSequence &+= 1
        let overflow = records.count - limits.maxRecords
        if overflow > 0 { records.removeFirst(overflow) }
        return outcome
    }

    private static func withoutTurnText(_ decision: RouteDecision) -> RouteDecision {
        if case .onDevice(let plan) = decision { return .onDevice(plan.withoutTurnText()) }
        return decision
    }

    private static func recordable(_ outcome: TurnOutcome, isPrivate: Bool) -> TurnOutcome {
        switch outcome {
        case .answered(let text, let route, let plan):
            let kept = isPrivate ? TurnRecord.redacted(characters: text.count) : text
            return .answered(text: kept, route: route, plan: plan.withoutTurnText())
        case .failed(let route, _) where isPrivate:
            // A backend error can echo the request, so a private mode's error text is not kept either.
            return .failed(route: route, message: TurnRecord.redactedFailure)
        default:
            return outcome
        }
    }
}
