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
        // One send at a time, and never an empty one: the view disables Send for both, but this is
        // public API, and a second call would clear the draft only to have the engine reject it.
        guard !draft.allSatisfy(\.isWhitespace) else { return }
        if snapshot == nil { await refresh() }
        // Checked after the only await above, with no suspension before the send starts; and the
        // mode the user typed in is pinned, so the engine rejects the prompt if a switch lands first.
        guard !isSending, !isTransitioning, let mode = snapshot?.mode else { return }
        let prompt = draft
        let needs: Set<Capability> = needsImageInput ? [.imageInput] : []
        draft = ""
        needsImageInput = false
        lastError = nil
        let id = nextSendID
        nextSendID &+= 1
        activeSend = id
        _ = await engine.send(prompt, needs: needs, expectedMode: mode)
        // A mode switch may have released this send already, and a newer send may own the slot.
        if activeSend == id { activeSend = nil }
        await refresh()
    }

    /// True while a send this view model started is the current one. A mode switch releases it at
    /// once, matching the engine, which frees itself for the new mode when it cancels the old call.
    public var isSending: Bool { activeSend != nil }
    private var activeSend: UInt64?
    private var nextSendID: UInt64 = 0

    /// True while a mode switch is in flight. Sends, writes and further switches wait for it, so
    /// nothing typed in the old mode is applied under the new mode's rules.
    public private(set) var isTransitioning = false

    public func transition(to mode: ModeID) async {
        guard !isTransitioning else { return }
        isTransitioning = true
        defer { isTransitioning = false }
        let releasing = activeSend
        do {
            lastTransition = try await engine.transition(to: mode)
            lastError = nil
            if activeSend == releasing { activeSend = nil } // the engine cancelled that call and is free
            // An unsent draft belongs to the mode it was typed in (it may be private); don't carry it.
            draft = ""
            needsImageInput = false
        } catch {
            lastError = String(describing: error)
        }
        await refresh()
    }

    public func write(_ value: StateValue?, for key: StateKey) async {
        guard !isTransitioning else { return }
        do {
            try await engine.setState(value, for: key, expectedMode: snapshot?.mode)
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
