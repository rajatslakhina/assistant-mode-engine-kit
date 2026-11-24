/// Whether a mode may send its context to the cloud model when the on-device model can't serve it.
public enum EscalationRule: Equatable, Sendable {
    case allowed
    /// The mode handles content that must not leave the device (for example private drafts).
    case forbidden
}

/// One mode: a group of instructions that is active only while the assistant is in this mode.
public struct ModeDefinition: Equatable, Sendable {
    public let id: ModeID
    public let title: String
    public let instructions: String
    /// Capabilities every request in this mode needs. A single request can add more (e.g. an image).
    public let requirements: Set<Capability>
    /// Token budget for instructions + state + history + prompt while this mode is active.
    public let contextBudget: Int
    /// The only state keys this mode may write. A write to any other key is rejected.
    public let writableKeys: Set<StateKey>
    public let escalation: EscalationRule
    /// Legal next modes, each with the state keys that survive that specific transition.
    /// Every other key is cleared when the transition happens.
    public let transitions: [ModeID: Set<StateKey>]

    public init(
        id: ModeID,
        title: String,
        instructions: String,
        requirements: Set<Capability> = [.onDeviceText],
        contextBudget: Int,
        writableKeys: Set<StateKey> = [],
        escalation: EscalationRule = .allowed,
        transitions: [ModeID: Set<StateKey>] = [:]
    ) {
        self.id = id
        self.title = title
        self.instructions = instructions
        self.requirements = requirements
        self.contextBudget = contextBudget
        self.writableKeys = writableKeys
        self.escalation = escalation
        self.transitions = transitions
    }
}

/// Configuration mistakes `ModeGraph` refuses at construction time, so they can't surface mid-session.
public enum ModeGraphError: Error, Equatable, Sendable {
    case noModes
    case duplicateMode(ModeID)
    case unknownInitialMode(ModeID)
    case unknownTransitionTarget(from: ModeID, to: ModeID)
    case selfTransition(ModeID)
    case nonPositiveBudget(ModeID)
    case emptyInstructions(ModeID)
    /// A transition carries a key that no mode can write: almost always a typo.
    case carriedKeyNeverWritable(from: ModeID, to: ModeID, key: StateKey)
    case unreachableMode(ModeID)
    /// A transition from a `.forbidden` (private) mode into a mode that may escalate carries state.
    /// That state could then be sent to the cloud from the next mode, so the graph refuses it.
    case carriesStateOutOfPrivateMode(from: ModeID, to: ModeID, keys: [StateKey])
}

/// A validated mode state machine. If you hold a `ModeGraph`, its invariants hold:
/// every transition target exists, every budget is positive, every carried key is writable
/// somewhere, every mode is reachable from the initial one, and no transition carries state out
/// of a private (`.forbidden`) mode into a mode that may escalate.
///
/// That last rule is what makes "a private mode's data never reaches the cloud" hold across
/// mode switches, not just within the mode: state written in a private mode can only reach an
/// escalating mode by crossing such an edge, and there are none. (State can still flow *into* a
/// private mode, and between private modes.)
public struct ModeGraph: Equatable, Sendable {
    public let initialMode: ModeID
    public let modes: [ModeID: ModeDefinition]

    /// Mode ids in a stable order, for UIs and reports.
    public var orderedIDs: [ModeID] { modes.keys.sorted() }

    public init(initialMode: ModeID, modes definitions: [ModeDefinition]) throws {
        guard !definitions.isEmpty else { throw ModeGraphError.noModes }
        var byID: [ModeID: ModeDefinition] = [:]
        for definition in definitions {
            guard byID[definition.id] == nil else { throw ModeGraphError.duplicateMode(definition.id) }
            byID[definition.id] = definition
        }
        guard byID[initialMode] != nil else { throw ModeGraphError.unknownInitialMode(initialMode) }

        let allWritable = definitions.reduce(into: Set<StateKey>()) { $0.formUnion($1.writableKeys) }
        // Sorted iteration so the first error reported is deterministic.
        for definition in definitions.sorted(by: { $0.id < $1.id }) {
            guard definition.contextBudget > 0 else { throw ModeGraphError.nonPositiveBudget(definition.id) }
            guard !definition.instructions.allSatisfy(\.isWhitespace) else {
                throw ModeGraphError.emptyInstructions(definition.id)
            }
            for target in definition.transitions.keys.sorted() {
                guard target != definition.id else { throw ModeGraphError.selfTransition(target) }
                guard byID[target] != nil else {
                    throw ModeGraphError.unknownTransitionTarget(from: definition.id, to: target)
                }
                let carried = definition.transitions[target] ?? []
                if let typo = carried.sorted().first(where: { !allWritable.contains($0) }) {
                    throw ModeGraphError.carriedKeyNeverWritable(from: definition.id, to: target, key: typo)
                }
                if definition.escalation == .forbidden, byID[target]?.escalation == .allowed, !carried.isEmpty {
                    throw ModeGraphError.carriesStateOutOfPrivateMode(from: definition.id, to: target, keys: carried.sorted())
                }
            }
        }

        // Breadth-first reachability from the initial mode. Each mode is enqueued at most once.
        var reached: Set<ModeID> = [initialMode]
        var queue: [ModeID] = [initialMode]
        var cursor = 0
        while cursor < queue.count {
            let current = queue[cursor]
            cursor += 1
            for target in byID[current]?.transitions.keys.sorted() ?? [] where !reached.contains(target) {
                reached.insert(target)
                queue.append(target)
            }
        }
        if let orphan = byID.keys.sorted().first(where: { !reached.contains($0) }) {
            throw ModeGraphError.unreachableMode(orphan)
        }

        self.initialMode = initialMode
        self.modes = byID
    }

    public func definition(_ id: ModeID) -> ModeDefinition? { modes[id] }

    /// Capabilities `mode` needs that `profile` lacks, sorted. Empty means it can run on-device
    /// (and also for an id that isn't in the graph).
    public func missingCapabilities(for id: ModeID, on profile: PlatformProfile) -> [Capability] {
        guard let definition = modes[id] else { return [] }
        return definition.requirements.subtracting(profile.capabilities).sorted()
    }
}
