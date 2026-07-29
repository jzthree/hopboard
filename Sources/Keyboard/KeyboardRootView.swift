import SwiftUI

struct KeyboardRootView: View {
    @ObservedObject var model: KeyboardModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 6) {
            centerStage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            keyRow
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .tint(FlowBrand.accent)
    }

    // MARK: center stage — one compact row per state

    @ViewBuilder
    private var centerStage: some View {
        if model.showingHistory, model.state == .ready || model.state == .noSession {
            historyStrip
        } else {
            stateStage
        }
    }

    /// Scrollable previews of recent dictations; tap one to insert it.
    private var historyStrip: some View {
        HStack(spacing: 8) {
            Button {
                model.showingHistory = false
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 56)
            }
            .buttonStyle(.plain)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.historyItems) { result in
                        Button {
                            model.insert(result)
                        } label: {
                            Text(result.text)
                                .font(.caption2)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                                .frame(width: 148, alignment: .topLeading)
                                .padding(7)
                                .background(RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(.secondarySystemFill)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var stateStage: some View {
        switch model.state {
        case .needsFullAccess:
            VStack(spacing: 2) {
                Text("Turn on Full Access for FlowBoard")
                    .font(.footnote.weight(.semibold))
                Text("Settings → General → Keyboard → Keyboards → FlowBoard")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 6)

        case .noSession:
            HStack(spacing: 12) {
                // SwiftUI's environment openURL action — the same sanctioned
                // route Link uses (iOS 18 killed every selector-based path
                // to UIApplication from keyboards), but as a plain button
                // with no link previews or "Open Link" affordances.
                Button {
                    openURL(Flow.startSessionURL)
                } label: {
                    Label("Start Flow Session", systemImage: "waveform")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(.tint))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                if model.historyItems.isEmpty {
                    Text("Opens FlowBoard, then swipe back here.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    chip("history", icon: "clock.arrow.circlepath") {
                        model.showingHistory = true
                    }
                }
            }

        case .loading(let status):
            HStack(spacing: 10) {
                ProgressView()
                Text(status.isEmpty ? "Preparing model…" : status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                endButton
            }
            .padding(.horizontal, 4)

        case .ready:
            HStack(spacing: 10) {
                micButton(recording: false)
                if model.justInserted {
                    Label("Inserted", systemImage: "checkmark")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                } else {
                    chip(model.tone.shortLabel, icon: "wand.and.stars") {
                        model.cycleTone()
                    }
                    if !model.historyItems.isEmpty {
                        chip("history", icon: "clock.arrow.circlepath") {
                            model.showingHistory = true
                        }
                    }
                }
                Spacer(minLength: 0)
                endButton
            }
            .padding(.horizontal, 4)

        case .recording:
            HStack(spacing: 12) {
                micButton(recording: true)
                KeyboardLevelMeter(level: model.micLevel)
                    .frame(height: 20)
                Spacer(minLength: 0)
                endButton
            }
            .padding(.horizontal, 4)

        case .transcribing:
            HStack(spacing: 12) {
                ProgressView()
                    .frame(width: 52, height: 52)
                Text("Transcribing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                endButton
            }
            .padding(.horizontal, 4)
        }
    }

    /// Small pill control for the ready row (tone cycle, insert-last).
    private func chip(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color(.secondarySystemFill)))
        }
        .buttonStyle(.plain)
    }

    private var endButton: some View {
        Button {
            model.endSessionTapped()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("End Flow Session")
    }

    private func micButton(recording: Bool) -> some View {
        Button {
            model.micTapped()
        } label: {
            ZStack {
                Circle()
                    .fill(recording ? Color.red : FlowBrand.accent)
                    .frame(width: 52, height: 52)
                    .shadow(color: (recording ? Color.red : FlowBrand.accent).opacity(0.35),
                            radius: recording ? 10 : 6)
                Image(systemName: recording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(recording ? "Stop and transcribe" : "Start dictating")
    }

    // MARK: bottom key row

    private var keyRow: some View {
        HStack(spacing: 8) {
            if model.showsGlobe {
                GlobeKey(controller: model.globeController)
                    .frame(width: 44, height: 38)
                    .background(keyBackground)
            }
            key("space", flexible: true) { model.spaceTapped() }
            RepeatKey(systemName: "delete.left") { model.deleteTapped() }
                .frame(width: 44, height: 38)
                .background(keyBackground)
            key("return") { model.returnTapped() }
        }
        .frame(height: 38)
    }

    private var keyBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(.secondarySystemFill))
    }

    private func key(_ label: String, flexible: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline)
                .frame(maxWidth: flexible ? .infinity : nil)
                .padding(.horizontal, flexible ? 0 : 16)
                .frame(height: 38)
                .background(keyBackground)
        }
        .buttonStyle(.plain)
    }
}

/// A key that fires once on tap and auto-repeats while held (delete).
struct RepeatKey: View {
    let systemName: String
    let action: () -> Void

    @State private var pressed = false
    @State private var repeater: Timer?

    var body: some View {
        Image(systemName: systemName)
            .font(.subheadline)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .opacity(pressed ? 0.4 : 1)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        action()
                        repeater = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                            repeater = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { _ in
                                action()
                            }
                        }
                    }
                    .onEnded { _ in
                        pressed = false
                        repeater?.invalidate()
                        repeater = nil
                    }
            )
    }
}

/// Compact level meter for the keyboard.
struct KeyboardLevelMeter: View {
    let level: Float
    private static let profile: [CGFloat] = [0.4, 0.7, 1.0, 0.7, 0.4, 0.6, 0.9, 0.6]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(Self.profile.enumerated()), id: \.offset) { _, weight in
                Capsule()
                    .fill(Color.red.opacity(0.8))
                    .frame(width: 4)
                    .scaleEffect(y: max(0.2, min(1, 0.25 + CGFloat(level) * weight)), anchor: .center)
            }
        }
        .animation(.easeOut(duration: 0.15), value: level)
    }
}
