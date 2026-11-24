import AssistantModes
import Observation

/// Main-actor view model over an `AssistantEngine`. It never caches engine state of its own:
/// after every action it re-reads one `EngineSnapshot`, so the UI and the model share one source
/// of truth (the engine) rather than two copies that can drift.
@MainActor
@Observable
public final class AssistantConsoleModel {
    public let engine: AssistantEngine
    /// Which on-device backend the engine was given, shown in the UI ("scripted", "Foundation Models", ...).
    public let backendLabel: String
    public private(set) var snapshot: EngineSnapshot?
    public private(set) var lastTransition: TransitionReport?
    public private(set) var lastError: String?
    public var draft = ""
    /// Marks the next request as needing `imageInput`. This is a routing declaration only: the
    /// package does not carry image data (see the README's Honest limits).
    public var needsImageInput = false

    public init(engine: AssistantEngine, backendLabel: String) {
        self.engine = engine
        self.backendLabel = backendLabel
    }

    public func refresh() async {
        snapshot = await engine.snapshot()
    }

    /// Sends the current draft. The draft is cleared before the await so a second tap can't resend it.
    public func send() async {
        let prompt = draft
        let needs: Set<Capability> = needsImageInput ? [.imageInput] : []
        draft = ""
        needsImageInput = false
        lastError = nil
        sendsInFlight += 1
        _ = await engine.send(prompt, needs: needs)
        sendsInFlight -= 1
        await refresh()
    }

    /// Sends this view model started that have not returned yet (UI affordance only; the engine's
    /// own `isGenerating` is the authority on whether a generation is running).
    public private(set) var sendsInFlight = 0

    public func transition(to mode: ModeID) async {
        do {
            lastTransition = try await engine.transition(to: mode)
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        await refresh()
    }

    public func write(_ value: StateValue?, for key: StateKey) async {
        do {
            try await engine.setState(value, for: key)
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        await refresh()
    }

    public func setCloudConsent(_ granted: Bool) async {
        await engine.setCloudConsent(granted)
        await refresh()
    }

    public func setOnline(_ online: Bool) async {
        await engine.setOnline(online)
        await refresh()
    }

    /// Modes reachable from the current one, in stable order.
    public var legalTargets: [ModeID] {
        guard let mode = snapshot?.mode, let definition = engine.graph.definition(mode) else { return [] }
        return definition.transitions.keys.sorted()
    }
}
