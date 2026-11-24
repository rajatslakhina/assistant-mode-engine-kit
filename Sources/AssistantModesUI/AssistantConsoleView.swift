import AssistantModes
import SwiftUI

/// An inspector for the engine: active mode, capability matrix, session state, and every turn's
/// route with the reason it took that route.
public struct AssistantConsoleView: View {
    @Bindable private var model: AssistantConsoleModel

    public init(model: AssistantConsoleModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let snapshot = model.snapshot {
                        modeBar(snapshot)
                        capabilityCard(snapshot)
                        turnLog(snapshot)
                        conversationCard(snapshot)
                        stateCard(snapshot)
                        if let report = model.lastTransition { transitionCard(report) }
                        if let error = model.lastError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.footnote).foregroundStyle(.red)
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) { composer }
            .navigationTitle("Assistant modes")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .task { await model.refresh() }
        }
    }

    // MARK: Sections

    private func modeBar(_ snapshot: EngineSnapshot) -> some View {
        let legal = Set(model.legalTargets)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.engine.graph.orderedIDs, id: \.self) { id in
                    let isCurrent = id == snapshot.mode
                    Button {
                        Task { await model.transition(to: id) }
                    } label: {
                        Text(model.engine.graph.definition(id)?.title ?? id.rawValue)
                            .font(.subheadline.weight(isCurrent ? .bold : .regular))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(isCurrent ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(isCurrent ? Color.white : Color.primary)
                    }
                    .disabled(isCurrent || !legal.contains(id))
                    .accessibilityLabel(isCurrent ? "Current mode \(id.rawValue)" : "Switch to \(id.rawValue)")
                }
            }
        }
    }

    private func capabilityCard(_ snapshot: EngineSnapshot) -> some View {
        let definition = model.engine.graph.definition(snapshot.mode)
        let needed = definition?.requirements ?? []
        return card(title: "\(snapshot.profile.name) · \(definition?.title ?? snapshot.mode.rawValue)") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6, alignment: .leading)],
                      alignment: .leading, spacing: 6) {
                ForEach(Capability.allCases, id: \.self) { capability in
                    let has = snapshot.profile.capabilities.contains(capability)
                    Text(capability.rawValue)
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background((has ? Color.green : Color.red).opacity(needed.contains(capability) ? 0.35 : 0.12),
                                    in: RoundedRectangle(cornerRadius: 4))
                        .strikethrough(!has)
                        .accessibilityLabel("\(capability.rawValue), \(has ? "available" : "not on this device")"
                                            + (needed.contains(capability) ? ", required by this mode" : ""))
                }
            }
            Text("Darker: required by this mode · struck through: not on this device")
                .font(.caption2).foregroundStyle(.secondary)
            Text("On-device backend: \(model.backendLabel)")
                .font(.caption.weight(.semibold))
            Text("Budget \(definition?.contextBudget ?? 0) of \(snapshot.profile.onDeviceContextTokens) tokens · "
                 + (definition?.escalation == .forbidden ? "never leaves the device" : "may escalate to Claude"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Toggle("Cloud consent", isOn: Binding(
                    get: { snapshot.cloudConsent },
                    set: { granted in Task { await model.setCloudConsent(granted) } }
                ))
                Toggle("Online", isOn: Binding(
                    get: { snapshot.isOnline },
                    set: { online in Task { await model.setOnline(online) } }
                ))
            }
            .font(.caption)
        }
    }

    private func turnLog(_ snapshot: EngineSnapshot) -> some View {
        card(title: "Turns (newest first)") {
            if snapshot.records.isEmpty {
                Text("No turns yet. Send a prompt below.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(snapshot.records.suffix(8).reversed()), id: \.sequence) { record in
                let line = OutcomeText.line(for: record.outcome)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(line.badge)
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(color(line.tone).opacity(0.2), in: Capsule())
                            .foregroundStyle(color(line.tone))
                        Text(record.mode.rawValue).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Spacer()
                        Text(OutcomeText.latency(record.latencyNanoseconds))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if let why = OutcomeText.escalationReason(for: record.decision) {
                        Text("Escalated because \(why)").font(.caption).foregroundStyle(.orange)
                    }
                    Text(line.detail).font(.footnote)
                }
                Divider()
            }
        }
    }

    /// The active mode's transcript, in full. The turn log above shows routing and, for private
    /// modes, a redaction; the answer itself lives here, and is cleared when the mode is left.
    private func conversationCard(_ snapshot: EngineSnapshot) -> some View {
        card(title: "Conversation in this mode") {
            if snapshot.transcript.isEmpty {
                Text("Nothing yet. A mode switch starts a new conversation.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(snapshot.transcript.suffix(3).enumerated()), id: \.offset) { _, turn in
                VStack(alignment: .leading, spacing: 2) {
                    Text(turn.user).font(.caption.bold()).lineLimit(2)
                    Text(turn.assistant).font(.footnote)
                }
            }
        }
    }

    private func stateCard(_ snapshot: EngineSnapshot) -> some View {
        card(title: "Session state") {
            if snapshot.state.values.isEmpty {
                Text("Empty").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(snapshot.state.values.keys.sorted(), id: \.self) { key in
                HStack(alignment: .top) {
                    Text(key.rawValue).font(.caption.monospaced().bold())
                    Text(snapshot.state[key]?.rendered ?? "").font(.caption)
                }
            }
        }
    }

    private func transitionCard(_ report: TransitionReport) -> some View {
        card(title: "Last switch: \(report.from) → \(report.to)") {
            Text("Carried: " + (report.carriedKeys.isEmpty ? "nothing" : report.carriedKeys.map(\.rawValue).joined(separator: ", ")))
                .font(.caption)
            Text("Cleared: " + (report.clearedKeys.isEmpty ? "nothing" : report.clearedKeys.map(\.rawValue).joined(separator: ", ")))
                .font(.caption)
            if !report.missingCapabilities.isEmpty {
                Text("Missing here: " + report.missingCapabilities.map(\.rawValue).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.orange)
            }
            if report.interruptedGeneration {
                Text("Interrupted a generation in flight; its answer will be discarded.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            HStack {
                TextField("Ask in this mode…", text: $model.draft)
                    .textFieldStyle(.roundedBorder)
                if model.sendsInFlight > 0 {
                    ProgressView().accessibilityLabel("Generating")
                }
                Button("Send") { Task { await model.send() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.draft.allSatisfy(\.isWhitespace))
            }
            Toggle("Mark as needing imageInput (routing only, no image is sent)", isOn: $model.needsImageInput)
                .font(.caption)
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: Helpers

    private func card<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func color(_ tone: OutcomeText.Tone) -> Color {
        switch tone {
        case .onDevice: return .green
        case .cloud: return .blue
        case .blocked: return .red
        case .neutral: return .secondary
        }
    }
}
