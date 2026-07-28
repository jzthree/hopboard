import SwiftUI

struct KeyboardRootView: View {
    @ObservedObject var model: KeyboardModel

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
                // A real SwiftUI Link, not a button with an openURL hack:
                // iOS 18 killed every selector-based route to UIApplication
                // from keyboard extensions, but a genuine link tap is still
                // allowed to open the containing app.
                Link(destination: Flow.startSessionURL) {
                    Label("Start Flow Session", systemImage: "waveform")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(.tint))
                        .foregroundStyle(.white)
                }
                Text("Opens FlowBoard, then swipe back.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
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
            HStack(spacing: 12) {
                micButton(recording: false)
                Text(model.justInserted ? "Inserted ✓" : "Tap to dictate")
                    .font(.caption)
                    .foregroundStyle(model.justInserted ? .primary : .secondary)
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
