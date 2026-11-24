import Dispatch

/// What the engine hands a model for one turn: already budgeted, already filtered to the active mode.
public struct ModelRequest: Equatable, Sendable {
    public let mode: ModeID
    public let instructions: String
    public let stateBlock: String
    public let history: [Turn]
    public let prompt: String

    public init(mode: ModeID, instructions: String, stateBlock: String, history: [Turn], prompt: String) {
        self.mode = mode
        self.instructions = instructions
        self.stateBlock = stateBlock
        self.history = history
        self.prompt = prompt
    }

    /// Session state, budgeted history and the new prompt as one string, for backends that take a
    /// single prompt. Session state is user-supplied content, so it belongs here and never in the
    /// instructions slot: instructions should only ever carry text the developer wrote.
    ///
    /// Every continuation line of user text is indented (see `PromptScaffold.fence`), so a value
    /// containing "\nUser: ..." can't start a line that looks like a real history label. That makes
    /// forged structure harder, not impossible: prompt injection is not prevented here.
    public var flattenedPrompt: String {
        var parts: [String] = []
        if !stateBlock.isEmpty {
            parts.append(PromptScaffold.stateHeader)
            parts.append(stateBlock)
            parts.append("")
        }
        if !history.isEmpty {
            parts.append(PromptScaffold.historyHeader)
            for turn in history {
                parts.append(PromptScaffold.userPrefix + PromptScaffold.fence(turn.user))
                parts.append(PromptScaffold.assistantPrefix + PromptScaffold.fence(turn.assistant))
            }
            parts.append("")
        }
        parts.append(PromptScaffold.fence(prompt))
        return parts.joined(separator: "\n")
    }
}

/// The fixed text `ModelRequest.flattenedPrompt` adds around user content. The budgeter charges
/// for it too, so the budget covers what is actually sent, not just the user's words.
enum PromptScaffold {
    static let stateHeader = "Current session state:"
    static let historyHeader = "Earlier in this mode:"
    static let userPrefix = "User: "
    static let assistantPrefix = "Assistant: "

    /// Every header and separator the flattened prompt can contain outside the turns themselves.
    static let fixedText = stateHeader + "\n\n\n" + historyHeader + "\n\n"
    /// Every prefix and separator one history turn adds.
    static let perTurnText = userPrefix + "\n" + assistantPrefix + "\n"
    static let indent = "  "

    /// Indents every line after the first, so user text never starts a line at column 0. Every
    /// Unicode line separator counts (LF, CR, CRLF, NEL, U+2028, U+2029, ...), and each is normalised
    /// to LF, so a value can't use a separator the fence doesn't recognise.
    static func fence(_ text: String) -> String {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .joined(separator: "\n" + indent)
    }
}

/// The on-device model. `availability` is synchronous on purpose: the routing decision is taken
/// inside one actor step with no suspension point, so it can't interleave with a mode change.
public protocol OnDeviceModel: Sendable {
    var availability: ModelAvailability { get }
    func respond(to request: ModelRequest) async throws -> String
}

/// The cloud model used for escalation (Claude, behind your own server).
public protocol EscalationModel: Sendable {
    func respond(to request: ModelRequest) async throws -> String
}

/// A model backed by a closure. Used by the tests and the demo app; also handy for previews.
public struct ClosureModel: OnDeviceModel, EscalationModel {
    public let availability: ModelAvailability
    private let body: @Sendable (ModelRequest) async throws -> String

    public init(
        availability: ModelAvailability = .available,
        respond body: @escaping @Sendable (ModelRequest) async throws -> String
    ) {
        self.availability = availability
        self.body = body
    }

    public func respond(to request: ModelRequest) async throws -> String {
        try await body(request)
    }
}

/// Nanoseconds from a monotonic source. Injected so latency numbers are testable.
public protocol MonotonicClock: Sendable {
    func nowNanoseconds() -> UInt64
}

public struct SystemMonotonicClock: MonotonicClock {
    public init() {}
    /// `DispatchTime` uptime in nanoseconds: monotonic and unaffected by wall-clock changes.
    /// It pauses while the device sleeps, which is what a per-turn latency measurement wants.
    public func nowNanoseconds() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
}
