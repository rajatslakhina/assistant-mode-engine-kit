/// Identifies one assistant mode ("capture", "plan", "review", ...).
public struct ModeID: Hashable, Comparable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
    public static func < (lhs: ModeID, rhs: ModeID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Names one slot of session state. The UI and the model read the same slot.
public struct StateKey: Hashable, Comparable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
    public static func < (lhs: StateKey, rhs: StateKey) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A typed session-state value. Kept deliberately small: everything here has one
/// deterministic text rendering, which is what the model actually sees.
public enum StateValue: Equatable, Sendable {
    case text(String)
    case number(Int)
    case flag(Bool)
    case list([String])

    /// The exact text placed in the prompt for this value.
    public var rendered: String {
        switch self {
        case .text(let value): return value
        case .number(let value): return String(value)
        case .flag(let value): return value ? "yes" : "no"
        case .list(let values): return values.isEmpty ? "(empty)" : values.map { "- \($0)" }.joined(separator: "\n")
        }
    }
}

/// What a platform's on-device model can do. A mode or a single request declares the
/// capabilities it needs; the router compares that against the platform profile.
public enum Capability: String, CaseIterable, Comparable, Sendable {
    case onDeviceText
    case guidedGeneration
    case imageInput
    case adapters
    case privateCloudCompute

    public static func < (lhs: Capability, rhs: Capability) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The capability matrix for one platform, plus the context window the budgeter must respect.
///
/// The two presets are data, not facts the package verified on hardware: they encode what
/// the Xcode 27.3 beta SDK interface diff reports (tvOS gets `SystemLanguageModel` without
/// Private Cloud Compute, adapters or image attachments). Override them with what your
/// target OS actually ships.
public struct PlatformProfile: Equatable, Sendable {
    public let name: String
    public let capabilities: Set<Capability>
    /// Context window of the on-device model, in tokens. Every mode budget must fit inside it.
    public let onDeviceContextTokens: Int

    public init(name: String, capabilities: Set<Capability>, onDeviceContextTokens: Int) {
        self.name = name
        self.capabilities = capabilities
        self.onDeviceContextTokens = max(0, onDeviceContextTokens)
    }

    /// Assumes iOS 27 or later: image attachments to the system model are iOS 27 API in the 27.2
    /// SDK. On iOS 26.x, drop `.imageInput` (build a `PlatformProfile` directly).
    public static func iPhone(contextTokens: Int) -> PlatformProfile {
        PlatformProfile(
            name: "iPhone",
            capabilities: [.onDeviceText, .guidedGeneration, .imageInput, .adapters, .privateCloudCompute],
            onDeviceContextTokens: contextTokens
        )
    }

    public static func appleTV(contextTokens: Int) -> PlatformProfile {
        PlatformProfile(
            name: "Apple TV",
            capabilities: [.onDeviceText, .guidedGeneration],
            onDeviceContextTokens: contextTokens
        )
    }
}

/// Saturating integer arithmetic. Token counts come from user text, so a sum must never trap.
enum Saturating {
    static func add(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        if overflow { return rhs > 0 ? Int.max : Int.min }
        return sum
    }

    static func sum<S: Sequence>(_ values: S) -> Int where S.Element == Int {
        values.reduce(0) { add($0, $1) }
    }

    /// The exact sum, or `nil` if any partial sum overflows.
    static func checkedSum<S: Sequence>(_ values: S) -> Int? where S.Element == Int {
        var total = 0
        for value in values {
            let (next, overflow) = total.addingReportingOverflow(value)
            if overflow { return nil }
            total = next
        }
        return total
    }
}
