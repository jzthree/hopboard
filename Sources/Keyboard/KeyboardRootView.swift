import SwiftUI

struct KeyboardRootView: View {
    @ObservedObject var model: KeyboardModel

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Spacer(minLength: 0)
            centerStage
            Spacer(minLength: 0)
            keyRow
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .tint(FlowBrand.accent)
    }

    // MARK: top status line

    private var statusBar: some View {
        HStack {
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if isSessionActive {
                Button {
                    model.endSessionTapped()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("End Flow Session")
            }
        }
        .frame(height: 22)
    }

    private var isSessionActive: Bool {
        switch model.state {
        case .ready, .recording, .transcribing, .loading: true
        default: false
        }
    }

    private var statusText: String {
        switch model.state {
        case .needsFullAccess: "Full Access needed"
        case .noSession: "FlowBoard"
        case .loading: "FlowBoard — preparing"
        case .ready: model.justInserted ? "Inserted ✓" : "FlowBoard — session active"
        case .recording: "Listening…"
        case .transcribing: "Transcribing…"
        }
    }

    // MARK: center stage

    @ViewBuilder
    private var centerStage: some View {
        switch model.state {
        case .needsFullAccess:
            VStack(spacing: 8) {
                Text("Turn on Full Access for FlowBoard")
                    .font(.subheadline.weight(.semibold))
                Text("Settings → General → Keyboard → Keyboards → FlowBoard → Allow Full Access")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 8)

        case .noSession:
            VStack(spacing: 10) {
                // A real SwiftUI Link, not a button with an openURL hack:
                // iOS 18 killed every selector-based route to UIApplication
                // from keyboard extensions, but a genuine link tap is still
                // allowed to open the containing app.
                Link(destination: Flow.startSessionURL) {
                    Label("Start Flow Session", systemImage: "waveform")
                        .font(.headline)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .background(Capsule().fill(.tint))
                        .foregroundStyle(.white)
                }
                Text("Opens FlowBoard for a moment, then swipe back and dictate.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

        case .loading(let status):
            VStack(spacing: 10) {
                ProgressView()
                Text(status.isEmpty ? "Preparing model…" : status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .padding(.horizontal, 8)

        case .ready:
            micButton(recording: false)

        case .recording:
            HStack(spacing: 14) {
                micButton(recording: true)
                KeyboardLevelMeter(level: model.micLevel)
                    .frame(height: 20)
            }

        case .transcribing:
            VStack(spacing: 10) {
                ProgressView()
                Text("Transcribing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func micButton(recording: Bool) -> some View {
        Button {
            model.micTapped()
        } label: {
            ZStack {
                Circle()
                    .fill(recording ? Color.red : FlowBrand.accent)
                    .frame(width: 62, height: 62)
                    .shadow(color: (recording ? Color.red : FlowBrand.accent).opacity(0.35),
                            radius: recording ? 12 : 7)
                Image(systemName: recording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 23, weight: .semibold))
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
                    .frame(width: 44, height: 40)
                    .background(keyBackground)
            }
            key("space", flexible: true) { model.spaceTapped() }
            RepeatKey(systemName: "delete.left") { model.deleteTapped() }
                .frame(width: 44, height: 40)
                .background(keyBackground)
            key("return") { model.returnTapped() }
        }
        .frame(height: 42)
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
                .frame(height: 40)
                .background(keyBackground)
        }
        .buttonStyle(.plain)
    }

    private func keyIcon(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.subheadline)
                .frame(width: 44, height: 40)
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
