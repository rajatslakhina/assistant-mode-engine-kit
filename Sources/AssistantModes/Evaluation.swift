import Foundation

/// What a step is expected to do.
public enum StepExpectation: Equatable, Sendable {
    case succeeds
    case fails
}

/// The expected end of one `send`.
public enum RouteExpectation: Equatable, Sendable, CustomStringConvertible {
    case onDevice
    case escalated
    case refused(EscalationBlocker)
    case rejected
    case discarded

    public var description: String {
        switch self {
        case .onDevice: return "on-device"
        case .escalated: return "escalated"
        case .refused(let blocker): return "refused(\(blocker))"
        case .rejected: return "rejected"
        case .discarded: return "discarded"
        }
    }
}

/// One scripted step of a mode-transition eval.
public enum EvalStep: Equatable, Sendable {
    case transition(to: ModeID, expect: StepExpectation)
    case write(StateKey, StateValue?, expect: StepExpectation)
    case send(String, needs: Set<Capability> = [], expect: RouteExpectation)
    case setCloudConsent(Bool)
    case setOnline(Bool)
    /// Asserts the value currently stored under a key (`nil` means "absent").
    case expectState(StateKey, StateValue?)
}

public struct EvalCase: Equatable, Sendable {
    public let name: String
    public let steps: [EvalStep]
    public init(name: String, steps: [EvalStep]) {
        self.name = name
        self.steps = steps
    }
}

public struct EvalFailure: Equatable, Sendable {
    public let stepIndex: Int
    public let expected: String
    public let actual: String
}

public struct EvalResult: Equatable, Sendable {
    public let name: String
    public let stepsRun: Int
    public let failures: [EvalFailure]
    public var passed: Bool { failures.isEmpty && stepsRun > 0 }
}

/// Runs scripted mode-transition and routing evals against a real engine. Because the cases assert
/// routing and state, not the wording of an answer, the same case can run against a scripted model
/// in CI and against the system model (the demo's `-scenario eval` does the latter).
public enum EvalRunner {
    public static func run(_ evalCase: EvalCase, on engine: AssistantEngine) async -> EvalResult {
        var failures: [EvalFailure] = []
        for (index, step) in evalCase.steps.enumerated() {
            switch step {
            case .transition(let target, let expect):
                let actual: StepExpectation
                do { try await engine.transition(to: target); actual = .succeeds } catch { actual = .fails }
                if actual != expect {
                    failures.append(EvalFailure(stepIndex: index, expected: "transition \(expect)", actual: "\(actual)"))
                }
            case .write(let key, let value, let expect):
                let actual: StepExpectation
                do { try await engine.setState(value, for: key); actual = .succeeds } catch { actual = .fails }
                if actual != expect {
                    failures.append(EvalFailure(stepIndex: index, expected: "write \(expect)", actual: "\(actual)"))
                }
            case .send(let prompt, let needs, let expect):
                let outcome = await engine.send(prompt, needs: needs)
                let actual = classify(outcome)
                if actual != expect {
                    failures.append(EvalFailure(
                        stepIndex: index, expected: expect.description,
                        actual: actual?.description ?? String(describing: outcome)
                    ))
                }
            case .setCloudConsent(let granted):
                await engine.setCloudConsent(granted)
            case .setOnline(let online):
                await engine.setOnline(online)
            case .expectState(let key, let expected):
                let actual = await engine.state[key]
                if actual != expected {
                    failures.append(EvalFailure(
                        stepIndex: index,
                        expected: "\(key) = \(expected.map { String(describing: $0) } ?? "absent")",
                        actual: actual.map { String(describing: $0) } ?? "absent"
                    ))
                }
            }
        }
        return EvalResult(name: evalCase.name, stepsRun: evalCase.steps.count, failures: failures)
    }

    /// Maps an outcome onto the expectation vocabulary; `nil` for outcomes no expectation names
    /// (a model error or a cancellation), which always count as a failure.
    static func classify(_ outcome: TurnOutcome) -> RouteExpectation? {
        switch outcome {
        case .answered(_, .onDevice, _): return .onDevice
        case .answered(_, .escalated, _): return .escalated
        case .refused(_, let blocker): return .refused(blocker)
        case .rejected: return .rejected
        case .discardedModeChanged: return .discarded
        case .failed, .cancelled: return nil
        }
    }
}

/// How repeatable a model's answer is for one fixed request.
public struct StabilityReport: Equatable, Sendable {
    public let runs: Int
    public let failures: Int
    public let distinctOutputs: Int
    /// How many successful runs produced the most common (normalised) output.
    public let modalCount: Int
    /// `modalCount / runs`, in 0...1. Failures count against agreement.
    public var agreement: Double { runs > 0 ? Double(modalCount) / Double(runs) : 0 }
}

/// Sends the same request several times and measures agreement. Useful against the real system
/// model, where sampling makes structured output drift; against a scripted model it only checks
/// the arithmetic.
public enum StabilityProbe {
    public static let maxRuns = 50

    public static func measure(
        runs requestedRuns: Int,
        request: ModelRequest,
        normalize: @Sendable (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() },
        respond: @Sendable (ModelRequest) async throws -> String
    ) async -> StabilityReport {
        let runs = min(max(requestedRuns, 1), maxRuns)
        var counts: [String: Int] = [:]
        var failures = 0
        for _ in 0..<runs {
            do {
                let output = normalize(try await respond(request))
                counts[output, default: 0] += 1
            } catch {
                failures += 1
            }
        }
        return StabilityReport(
            runs: runs,
            failures: failures,
            distinctOutputs: counts.count,
            modalCount: counts.values.max() ?? 0
        )
    }
}
