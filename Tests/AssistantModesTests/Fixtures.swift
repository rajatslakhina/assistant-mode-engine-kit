import AssistantModes
import Foundation

/// The three-mode graph the tests share: capture → plan → review, with review private.
enum Fixture {
    static let topic: StateKey = "topic"
    static let notes: StateKey = "notes"
    static let steps: StateKey = "steps"

    static func modes(reviewEscalation: EscalationRule = .forbidden) -> [ModeDefinition] {
        [
            ModeDefinition(
                id: "capture", title: "Capture",
                instructions: "Turn what the user says into short notes.",
                contextBudget: 400, writableKeys: [topic, notes],
                transitions: ["plan": [topic, notes]]
            ),
            ModeDefinition(
                id: "plan", title: "Plan",
                instructions: "Turn the notes into ordered steps.",
                requirements: [.onDeviceText, .guidedGeneration],
                contextBudget: 600, writableKeys: [steps],
                transitions: ["review": [topic, steps], "capture": [topic]]
            ),
            ModeDefinition(
                id: "review", title: "Review",
                instructions: "Critique the plan. Private: never leaves the device.",
                contextBudget: 600, writableKeys: [],
                escalation: reviewEscalation,
                transitions: ["capture": []]
            ),
        ]
    }

    static func graph(reviewEscalation: EscalationRule = .forbidden) throws -> ModeGraph {
        try ModeGraph(initialMode: "capture", modes: modes(reviewEscalation: reviewEscalation))
    }

    static let iPhone = PlatformProfile.iPhone(contextTokens: 4096)
    static let appleTV = PlatformProfile.appleTV(contextTokens: 4096)

    static func echo(_ tag: String, availability: ModelAvailability = .available) -> ClosureModel {
        ClosureModel(availability: availability) { request in "\(tag):\(request.mode):\(request.prompt)" }
    }

    static func engine(
        profile: PlatformProfile = iPhone,
        onDevice: any OnDeviceModel = echo("device"),
        escalation: (any EscalationModel)? = echo("cloud"),
        clock: any MonotonicClock = SystemMonotonicClock(),
        limits: EngineLimits = EngineLimits(),
        cloudConsent: Bool = true,
        reviewEscalation: EscalationRule = .forbidden
    ) throws -> AssistantEngine {
        try AssistantEngine(
            graph: graph(reviewEscalation: reviewEscalation), profile: profile, onDevice: onDevice,
            escalation: escalation, clock: clock, limits: limits, cloudConsent: cloudConsent
        )
    }
}

/// Suspends callers until `open()`; counts arrivals so a test can wait until a model is mid-call.
actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private(set) var arrivals = 0

    func wait() async {
        arrivals += 1
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// Polls `condition` with `Task.yield()` until it holds. Bounded, so a broken test fails instead of hanging.
func waitUntil(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<100_000 {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}

/// A clock that advances by a fixed step on every read.
final class SteppingClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var now: UInt64
    private let step: UInt64

    init(start: UInt64 = 1_000, step: UInt64) {
        self.now = start
        self.step = step
    }

    func nowNanoseconds() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let value = now
        now &+= step
        return value
    }
}

/// A clock that goes backwards on its second read (a misbehaving source).
final class BackwardsClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    func nowNanoseconds() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        return reads == 1 ? 5_000 : 1_000
    }
}

/// Reports the marker text as Int.max tokens and everything else as free, to exercise overflow.
struct HugeEstimator: TokenEstimator {
    static let huge = "HUGE"
    func estimate(_ text: String) -> Int { text == Self.huge ? Int.max : 0 }
}

/// Exactly one token per UTF-8 byte: makes budget arithmetic in tests easy to read.
struct ByteEstimator: TokenEstimator {
    func estimate(_ text: String) -> Int { text.utf8.count }
}
