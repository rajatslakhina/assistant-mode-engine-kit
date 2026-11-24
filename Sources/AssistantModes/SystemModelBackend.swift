#if canImport(FoundationModels) && !os(tvOS) && !os(watchOS)
import FoundationModels

/// `OnDeviceModel` backed by Apple's on-device system language model (Foundation Models).
///
/// Compiled only where the SDK ships Foundation Models (Xcode 26 and later). Each turn opens a
/// fresh `LanguageModelSession`: the engine owns the transcript and its budget, so the session's
/// own history would double-count it. Only the active mode's developer-written instructions go
/// in the session's instructions; session state (user-supplied), the budgeted history and the
/// prompt go in the prompt, so user text is never placed in the instructions slot.
///
/// Not compiled for tvOS or watchOS: this package declares and builds neither platform.
///
/// This adapter uses only the shipping Foundation Models API. It does not call the instruction-group
/// or session-state APIs seen in the Xcode 27.3 beta SDK diff; the engine implements those ideas in
/// its own types so the design runs on today's SDKs.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
public struct SystemModelBackend: OnDeviceModel {
    public init() {}

    public var availability: ModelAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .unavailable(.deviceNotEligible)
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable(.appleIntelligenceNotEnabled)
        case .unavailable(.modelNotReady):
            return .unavailable(.modelNotReady)
        case .unavailable(let other):
            return .unavailable(.other(String(describing: other)))
        }
    }

    public func respond(to request: ModelRequest) async throws -> String {
        let session = LanguageModelSession(instructions: request.instructions)
        let response = try await session.respond(to: request.flattenedPrompt)
        return response.content
    }
}
#endif
