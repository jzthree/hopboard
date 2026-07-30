import SwiftUI

struct KeyboardRootView: View {
    @ObservedObject var model: KeyboardModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if model.typingMode {
                TypePad(model: model)
            } else {
                VStack(spacing: 6) {
                    centerStage
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    keyRow
                }
            }
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
                // A visible key, not a floating glyph: the drawn bounds ARE
                // the tap target, so the finger knows exactly where to land.
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 52, height: 72)
                    .background(RoundedRectangle(cornerRadius: 9)
                        .fill(Color(.secondarySystemFill)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(KeyStyle())
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
                        .buttonStyle(KeyStyle())
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
                Text("Turn on Full Access for HopBoard")
                    .font(.footnote.weight(.semibold))
                Text("Settings → General → Keyboard → Keyboards → HopBoard")
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
                    Label("Start Session", systemImage: "waveform")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(.tint))
                        .foregroundStyle(.white)
                }
                .buttonStyle(KeyStyle())
                if model.historyItems.isEmpty {
                    Text("Opens HopBoard, then swipe back here.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    chip("History", icon: "clock.arrow.circlepath") {
                        model.showingHistory = true
                    }
                }
                chip("abc", icon: "keyboard") {
                    model.setTyping(true)
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
            // The mic is the most-tapped control: keep everything else on
            // the far side of a spacer so nothing sits in mistouch range.
            HStack(spacing: 8) {
                micButton(recording: false)
                Spacer(minLength: 16)
                if model.justInserted {
                    Label("Inserted", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .glassPill(tint: .green)
                } else {
                    chip("abc", icon: "keyboard") {
                        model.setTyping(true)
                    }
                    chip(model.tone.shortLabel, icon: "wand.and.stars") {
                        model.cycleTone()
                    }
                    if !model.historyItems.isEmpty {
                        chip("History", icon: "clock.arrow.circlepath") {
                            model.showingHistory = true
                        }
                    }
                }
                endButton
            }
            .padding(.horizontal, 4)

        case .recording:
            HStack(spacing: 14) {
                micButton(recording: true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Text("Recording")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                        if let start = model.recordingStartedAt {
                            Text(timerInterval: start...Date.distantFuture, countsDown: false)
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.red)
                        }
                    }
                    KeyboardLevelMeter(level: model.micLevel)
                        .frame(height: 22)
                }
                Spacer(minLength: 0)
                endButton
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.red.opacity(0.12)))

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

    /// Small pill control for the ready row (tone cycle, History).
    private func chip(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .glassPill()
        }
        .buttonStyle(KeyStyle())
    }

    private var endButton: some View {
        Button {
            model.endSessionTapped()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("End Session")
    }

    private func micButton(recording: Bool) -> some View {
        Button {
            model.micTapped()
        } label: {
            ZStack {
                if recording { RecordingPulse().frame(width: 52, height: 52) }
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
        .buttonStyle(KeyStyle())
        .accessibilityLabel(recording ? "Stop and transcribe" : "Start dictating")
    }

    // MARK: bottom key row

    /// Globe fixed; space/delete/return share the width equally — return
    /// and delete get used at least as often as space here.
    private var keyRow: some View {
        HStack(spacing: 8) {
            if model.showsGlobe {
                GlobeKey(controller: model.globeController)
                    .frame(width: 44, height: 38)
                    .background(keyBackground)
            }
            key("space", flexible: true) { model.spaceTapped() }
            RepeatKey(systemName: "delete.left") { model.deleteTapped() }
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(keyBackground)
            key("return", flexible: true) { model.returnTapped() }
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
        .buttonStyle(KeyStyle())
    }
}

/// Every key's press feel: dim + slight shrink while pressed, one haptic
/// and system click on touch-down — the physicality the plain style lacked.
struct KeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.5 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { KeyFeedback.tap() }
            }
    }
}

/// The correction pad: a deliberately minimal QWERTY for typing "yes"
/// instead of dictating it. No autocorrect, no prediction, no prose
/// ambitions — the mic key returns to dictation.
struct TypePad: View {
    @ObservedObject var model: KeyboardModel
    @State private var shifted = false

    /// Three layers, like the system keyboard: letters, 123, #+=.
    private enum Layer { case letters, numbers, symbols }
    @State private var layer: Layer = .letters

    private static let row1 = ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"]
    private static let row2 = ["a", "s", "d", "f", "g", "h", "j", "k", "l"]
    private static let row3 = ["z", "x", "c", "v", "b", "n", "m"]
    private static let num1 = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
    private static let num2 = ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""]
    private static let sym1 = ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="]
    private static let sym2 = ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"]
    private static let punct = [".", ",", "?", "!", "'"]

    var body: some View {
        VStack(spacing: 8) {
            switch layer {
            case .letters: letterRow(Self.row1)
            case .numbers: letterRow(Self.num1)
            case .symbols: letterRow(Self.sym1)
            }
            switch layer {
            case .letters: letterRow(Self.row2).padding(.horizontal, 14)
            case .numbers: letterRow(Self.num2)
            case .symbols: letterRow(Self.sym2)
            }
            HStack(spacing: 6) {
                if layer == .letters {
                    controlKey(shifted ? "shift.fill" : "shift") { shifted.toggle() }
                } else {
                    // The second-symbols toggle lives where shift was —
                    // exactly the system keyboard's arrangement.
                    Button {
                        layer = layer == .numbers ? .symbols : .numbers
                    } label: {
                        Text(layer == .numbers ? "#+=" : "123")
                            .font(.footnote)
                            .frame(width: 40, height: 40)
                            .background(padKeyBackground)
                    }
                    .buttonStyle(KeyStyle())
                }
                letterRow(layer == .letters ? Self.row3 : Self.punct)
                    .padding(.horizontal, layer == .letters ? 0 : 24)
                RepeatKey(systemName: "delete.left") { model.deleteTapped() }
                    .frame(width: 40, height: 40)
                    .background(padKeyBackground)
            }
            HStack(spacing: 6) {
                Button {
                    layer = layer == .letters ? .numbers : .letters
                    shifted = false
                } label: {
                    Text(layer == .letters ? "123" : "abc")
                        .font(.subheadline)
                        .frame(width: 46, height: 40)
                        .background(padKeyBackground)
                }
                .buttonStyle(KeyStyle())
                Button {
                    model.setTyping(false)
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 40)
                        .background(RoundedRectangle(cornerRadius: 7).fill(FlowBrand.accent))
                }
                .buttonStyle(KeyStyle())
                .accessibilityLabel("Back to dictation")
                key("space") { model.spaceTapped() }
                key("return") { model.returnTapped() }
                    .frame(width: 88)
            }
        }
    }

    private func letterRow(_ letters: [String]) -> some View {
        HStack(spacing: 5) {
            ForEach(letters, id: \.self) { letter in
                Button {
                    model.typeText(shifted ? letter.uppercased() : letter)
                    if shifted { shifted = false }
                } label: {
                    Text(shifted ? letter.uppercased() : letter)
                        .font(.system(size: 21))
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(padKeyBackground)
                }
                .buttonStyle(KeyStyle())
            }
        }
    }

    private func controlKey(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.subheadline.weight(.medium))
                .frame(width: 40, height: 40)
                .background(padKeyBackground)
        }
        .buttonStyle(KeyStyle())
    }

    private func key(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(padKeyBackground)
        }
        .buttonStyle(KeyStyle())
    }

    private var padKeyBackground: some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(Color(.secondarySystemFill))
    }
}

/// Expanding red rings behind the mic while recording — visible from the
/// corner of an eye, unlike a level meter alone.
struct RecordingPulse: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.red.opacity(animate ? 0 : 0.55), lineWidth: 3)
                .scaleEffect(animate ? 1.9 : 1)
            Circle()
                .stroke(Color.red.opacity(animate ? 0 : 0.35), lineWidth: 2)
                .scaleEffect(animate ? 1.5 : 1)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
                animate = true
            }
        }
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
                        KeyFeedback.tap()
                        action()
                        repeater = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                            repeater = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { _ in
                                KeyFeedback.tap()
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
