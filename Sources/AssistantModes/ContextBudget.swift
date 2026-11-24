/// Estimates how many tokens a piece of text costs. Swap in the real tokenizer when you have one.
public protocol TokenEstimator: Sendable {
    func estimate(_ text: String) -> Int
}

/// UTF-8 bytes divided by `bytesPerToken`, rounded up. With the default of 3 this over-counts
/// English (roughly 4 characters per token) and lands near one token per character for CJK
/// (3 bytes each). Over-counting is the safe direction for a budget: the cost of being wrong is
/// dropping one more old turn, not overflowing the model's context window.
public struct ConservativeTokenEstimator: TokenEstimator {
    public let bytesPerToken: Int

    public init(bytesPerToken: Int = 3) {
        self.bytesPerToken = max(1, bytesPerToken)
    }

    public func estimate(_ text: String) -> Int {
        let bytes = text.utf8.count
        // bytes >= 0 and bytesPerToken >= 1, so neither the division nor the +1 can trap.
        return bytes / bytesPerToken + (bytes % bytesPerToken == 0 ? 0 : 1)
    }
}

/// One exchange in the active mode's transcript.
public struct Turn: Equatable, Sendable {
    public let user: String
    public let assistant: String
    public init(user: String, assistant: String) {
        self.user = user
        self.assistant = assistant
    }
}

/// Session state shared by the UI and the model. Rendering is sorted by key so the same state
/// always produces the same prompt text (and so the same token estimate).
public struct SessionState: Equatable, Sendable {
    public private(set) var values: [StateKey: StateValue] = [:]

    public init(values: [StateKey: StateValue] = [:]) { self.values = values }

    public subscript(key: StateKey) -> StateValue? { values[key] }

    mutating func set(_ value: StateValue?, for key: StateKey) { values[key] = value }

    /// Keeps only `keys`; returns the keys that were removed, sorted.
    mutating func retainOnly(_ keys: Set<StateKey>) -> [StateKey] {
        let removed = values.keys.filter { !keys.contains($0) }.sorted()
        for key in removed { values[key] = nil }
        return removed
    }

    /// The exact text block placed in the prompt. Empty state renders as an empty string.
    /// Every value line is indented, so a value can't forge a `[key]` header at column 0.
    public var rendered: String {
        values.keys.sorted().compactMap { key in
            values[key].map { "[\(key.rawValue)]\n" + PromptScaffold.indent + PromptScaffold.fence($0.rendered) }
        }.joined(separator: "\n\n")
    }
}

/// What fits in the budget: the newest contiguous run of turns that fits after the fixed part.
public struct ContextPlan: Equatable, Sendable {
    /// The turns sent. Empty in a plan stored in a `TurnRecord`, which keeps only the count.
    public let includedTurns: [Turn]
    public let includedTurnCount: Int
    public let droppedTurnCount: Int
    public let estimatedTokens: Int
    public let budget: Int

    public init(includedTurns: [Turn], droppedTurnCount: Int, estimatedTokens: Int, budget: Int) {
        self.includedTurns = includedTurns
        self.includedTurnCount = includedTurns.count
        self.droppedTurnCount = droppedTurnCount
        self.estimatedTokens = estimatedTokens
        self.budget = budget
    }

    private init(count: Int, droppedTurnCount: Int, estimatedTokens: Int, budget: Int) {
        self.includedTurns = []
        self.includedTurnCount = count
        self.droppedTurnCount = droppedTurnCount
        self.estimatedTokens = estimatedTokens
        self.budget = budget
    }

    /// The same plan without the turn text: counts and token estimates only.
    public func withoutTurnText() -> ContextPlan {
        ContextPlan(count: includedTurnCount, droppedTurnCount: droppedTurnCount,
                    estimatedTokens: estimatedTokens, budget: budget)
    }
}

public enum BudgetError: Error, Equatable, Sendable {
    /// Instructions + state + prompt alone are larger than the budget, even with no history.
    case fixedPartExceedsBudget(fixed: Int, budget: Int)
}

/// Fits a mode's context into its budget.
///
/// The fixed part (instructions, state, the new prompt) is never trimmed: dropping instructions
/// would silently turn one mode into another, and dropping state would break the one-source-of-truth
/// promise. Only history is trimmed, oldest first, and only as a contiguous suffix: an older short
/// turn is never kept after a newer long one was dropped, because a transcript with a hole in it
/// reads to the model as a different conversation.
public struct ContextBudgeter: Sendable {
    public let estimator: any TokenEstimator

    public init(estimator: any TokenEstimator = ConservativeTokenEstimator()) {
        self.estimator = estimator
    }

    /// A custom estimator returning a negative count is treated as zero.
    private func tokens(_ text: String) -> Int { max(0, estimator.estimate(text)) }

    /// Tokens one history turn costs, including the "User:"/"Assistant:" scaffolding the prompt adds.
    /// Saturates at `Int.max`; for display only. Fitting uses overflow-checked sums.
    public func cost(of turn: Turn) -> Int {
        Saturating.sum([tokens(PromptScaffold.fence(turn.user)), tokens(PromptScaffold.fence(turn.assistant)),
                        tokens(PromptScaffold.perTurnText)])
    }

    public func plan(
        instructions: String,
        state: SessionState,
        history: [Turn],
        prompt: String,
        budget: Int
    ) -> Result<ContextPlan, BudgetError> {
        // The scaffolding is charged separately from the text it wraps. For an estimator that rounds
        // each piece up (like the default), the sum of the pieces is never less than the estimate of
        // the joined prompt, so the plan is an upper bound on what is actually sent.
        let fixedParts = [tokens(instructions), tokens(state.rendered), tokens(PromptScaffold.fence(prompt)), tokens(PromptScaffold.fixedText)]
        // An overflowing sum is larger than any Int budget, so it never "fits" by saturating to it.
        guard let fixed = Saturating.checkedSum(fixedParts), fixed <= budget else {
            return .failure(.fixedPartExceedsBudget(fixed: Saturating.sum(fixedParts), budget: budget))
        }
        var used = fixed
        var keptFromEnd = 0
        for turn in history.reversed() {
            guard let next = Saturating.checkedSum([used, tokens(PromptScaffold.fence(turn.user)),
                                                    tokens(PromptScaffold.fence(turn.assistant)),
                                                    tokens(PromptScaffold.perTurnText)]),
                  next <= budget
            else { break }
            used = next
            keptFromEnd += 1
        }
        let included = Array(history.suffix(keptFromEnd))
        return .success(ContextPlan(
            includedTurns: included,
            droppedTurnCount: history.count - keptFromEnd,
            estimatedTokens: used,
            budget: budget
        ))
    }
}
