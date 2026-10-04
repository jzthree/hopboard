import SwiftUI

struct KeyboardRootView: View {
    @ObservedObject var model: KeyboardModel
    @Environment(\.openURL) private var openURL
    /// End Session is one tap from `return`; arm it before it fires.
    @State private var endArmed = false
    /// Width of the chips riding on the primary surface, measured so the
    /// row's own text can reserve room instead of sliding under them.
    @State private var clusterWidth: CGFloat = 0
    @State private var discardWidth: CGFloat = 0

    var body: some View {
        Group {
            if model.typingMode {
                TypePad(model: model)
            } else {
                VStack(spacing: 4) {
                    centerStage
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    keyRow
                }
            }
        }
        .padding(.horizontal, 8)
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
                Text("Settings ▸ Keyboards ▸ HopBoard")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)

        case .noSession:
            // Same full-row surface as ready/recording — the primary action
            // is never a small capsule the thumb has to find.
            ZStack(alignment: .trailing) {
                // SwiftUI's environment openURL action — the same sanctioned
                // route Link uses (iOS 18 killed every selector-based path
                // to UIApplication from keyboards), but as a plain button
                // with no link previews or "Open Link" affordances.
                Button {
                    openURL(Flow.startSessionURL)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "waveform")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 60, height: 60)
                            .background(Circle().fill(.tint))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Start Session")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("Opens HopBoard")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 8)
                    // Room for the chips overlaid on the trailing edge, so
                    // the caption stops before them instead of underneath.
                    .padding(.trailing, clusterWidth + 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .background(surface(FlowBrand.accent))
                }
                .buttonStyle(KeyStyle())
                HStack(spacing: 6) {
                    if !model.historyItems.isEmpty {
                        iconChip("clock.arrow.circlepath", label: "History") {
                            model.showingHistory = true
                        }
                    }
                    iconChip("gearshape", label: "Settings") {
                        openURL(Flow.settingsURL)
                    }
                }
                .measuringWidth(into: $clusterWidth)
                .padding(.trailing, 8)
            }

        case .loading(let status):
            // The model only loads while HopBoard is foreground — so the
            // honest affordance here is "go back to the app", full-row tap.
            HStack(spacing: 8) {
                Button {
                    openURL(Flow.startSessionURL)
                } label: {
                    HStack(spacing: 10) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(status.isEmpty ? "Preparing model…" : status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Tap to open HopBoard")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(KeyStyle())
            }
            .padding(.horizontal, 4)

        case .ready:
            // Eyes-free first: the ENTIRE row is the mic's tap target — one
            // drawn surface, so the bounds are honest, and the chips ride on
            // top. Anything that isn't a chip starts dictation, including
            // the strips above and below them.
            ZStack(alignment: .trailing) {
                Button {
                    model.micTapped()
                } label: {
                    HStack(spacing: 0) {
                        micVisual(recording: false)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .background(surface(FlowBrand.accent))
                }
                .buttonStyle(KeyStyle())
                .accessibilityLabel("Start dictating")

                HStack(spacing: 6) {
                    if model.justInserted {
                        Label("Inserted", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 12)
                            .frame(height: 38)
                            .glassPill(tint: .green)
                    } else if model.pendingResult != nil {
                        // A dictation that couldn't auto-insert: lingers
                        // until tapped or a new dictation replaces it.
                        // Beside it, the second chance — a mangled decode is
                        // worth re-running before it is worth re-speaking.
                        if model.canRetranscribe {
                            iconChip("arrow.clockwise", label: "Transcribe again") {
                                model.retranscribeLast()
                            }
                        }
                        Button {
                            model.insertPending()
                        } label: {
                            Label("Insert", systemImage: "arrow.down.circle.fill")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 12)
                                .frame(height: 38)
                                .glassPill(tint: FlowBrand.accent)
                                // Without this the pill's tap target is the
                                // WORD, not the capsule: padding and glass
                                // aren't hit-testable, so half of it fell
                                // through to the full-row mic underneath and
                                // started a recording instead of inserting.
                                .contentShape(Capsule())
                        }
                        .buttonStyle(KeyStyle())
                    } else {
                        // Text-only language pill: the label IS the icon,
                        // and every point saved here is mic surface.
                        textChip(model.languageLabel, label: "Dictation language") {
                            model.cycleLanguage()
                        }
                        chip(model.tone.shortLabel, icon: "wand.and.stars") {
                            model.cycleTone()
                        }
                        if !model.historyItems.isEmpty {
                            iconChip("clock.arrow.circlepath", label: "History") {
                                model.showingHistory = true
                            }
                        }
                        // A mangled decode is worth re-running before it is
                        // worth re-speaking, and you only find out it was
                        // mangled after reading it — by which point the
                        // dictation has usually inserted itself and the pill
                        // this used to hide behind is long gone. It lives
                        // here for as long as the audio does: until the next
                        // dictation starts or the session ends.
                        if model.canRetranscribe {
                            iconChip("arrow.clockwise", label: "Transcribe again") {
                                model.retranscribeLast()
                            }
                        }
                        // Model, vocabulary, mic mode — the settings worth
                        // reaching mid-dictation without hunting for the app.
                        iconChip("gearshape", label: "Settings") {
                            openURL(Flow.settingsURL)
                        }
                    }
                }
                .padding(.trailing, 8)
            }

        case .recording:
            // Eyes-free stop: the whole red surface stops and transcribes.
            // Discard rides on top — misspeaking shouldn't force an insert
            // followed by a hunt for backspace.
            ZStack(alignment: .trailing) {
                Button {
                    model.micTapped()
                } label: {
                    HStack(spacing: 14) {
                        micVisual(recording: true)
                        VStack(alignment: .leading, spacing: 3) {
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
                                .frame(height: 18)
                            Text("tap anywhere to stop")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 8)
                    // Keep the timer and meter clear of the Discard pill.
                    .padding(.trailing, discardWidth + 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .background(surface(.red))
                }
                .buttonStyle(KeyStyle())
                .accessibilityLabel("Stop and transcribe")

                Button {
                    model.discardRecording()
                } label: {
                    Label("Discard", systemImage: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                        .glassPill()
                        .contentShape(Capsule())
                }
                .buttonStyle(KeyStyle())
                .measuringWidth(into: $discardWidth)
                .padding(.trailing, 8)
            }

        case .transcribing:
            HStack(spacing: 12) {
                ProgressView()
                    .frame(width: 52, height: 52)
                HStack(spacing: 6) {
                    Text("Transcribing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let start = model.transcribingStartedAt {
                        Text(timerInterval: start...Date.distantFuture, countsDown: false)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
        }
    }

    /// The primary surface shared by no-session, ready and recording. The
    /// TAP area is the full row — the thumb never has to aim — but the
    /// drawn shade is inset from it: full-bleed tint ran into the host
    /// app's own UI at the keyboard's top edge and looked like a mistake.
    /// Bounds you can see are honest here in the other direction: the
    /// target is never smaller than what's drawn, only larger.
    private func surface(_ tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(tint.opacity(0.12))
            .padding(.vertical, 5)
            .padding(.horizontal, 2)
    }

    /// Text-only pill (language): narrower than a Label, and the text is
    /// already the icon.
    private func textChip(_ text: String, label: String,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12)
                .frame(minWidth: 44)
                .frame(height: 38)
                .glassPill()
                .contentShape(Capsule())
        }
        .buttonStyle(KeyStyle())
        .accessibilityLabel("\(label): \(text)")
    }

    /// Icon-only chip (Type, History): 44×38, frees width for the mic zone.
    private func iconChip(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.subheadline)
                .frame(width: 44, height: 38)
                .glassPill()
                .contentShape(Capsule())
        }
        .buttonStyle(KeyStyle())
        .accessibilityLabel(label)
    }

    /// Pill control for the ready row (abc, tone, History): 38 pt tall so
    /// the drawn pill is an honest tap target.
    private func chip(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.caption)
                .padding(.horizontal, 11)
                .frame(height: 38)
                .glassPill()
                .contentShape(Capsule())
        }
        .buttonStyle(KeyStyle())
    }

    /// The mic/stop circle — purely visual; its Button wrapper supplies
    /// the (much larger) tap zone.
    private func micVisual(recording: Bool) -> some View {
        ZStack {
            if recording { RecordingPulse().frame(width: 60, height: 60) }
            Circle()
                .fill(recording ? Color.red : FlowBrand.accent)
                .frame(width: 60, height: 60)
                .shadow(color: (recording ? Color.red : FlowBrand.accent).opacity(0.35),
                        radius: recording ? 10 : 6)
            Image(systemName: recording ? "stop.fill" : "mic.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    // MARK: bottom key row

    /// Globe fixed; space/delete/return share the width equally — return
    /// and delete get used at least as often as space here.
    private var keyRow: some View {
        HStack(spacing: 8) {
            if model.showsGlobe {
                GlobeKey(controller: model.globeController)
                    .frame(width: 44, height: 42)
                    .background(keyBackground)
            }
            Button {
                model.setTyping(true)
            } label: {
                Text("abc")
                    .font(.subheadline)
                    .frame(width: 44, height: 42)
                    .background(keyBackground)
                    .contentShape(Rectangle())
            }
            .buttonStyle(KeyStyle())
            .accessibilityLabel("Type instead of dictating")
            key("space", flexible: true) { model.spaceTapped() }
            RepeatKey(systemName: "delete.left") { model.deleteTapped() }
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(keyBackground)
            // A key that says what it will do: mid-dictation this one ends
            // the recording rather than typing a newline.
            key(model.state == .recording ? "stop" : "return",
                flexible: true) { model.returnTapped() }
            if sessionActive { endKey }
        }
        .frame(height: 42)
    }

    private var sessionActive: Bool {
        switch model.state {
        case .ready, .recording, .transcribing, .loading: true
        default: false
        }
    }

    /// End Session, demoted to the bottom corner: rare action, cheap seat —
    /// but it sits next to `return`, and a misfire costs a trip to the app
    /// to start a new session. So it asks first: tap once to arm ("End?"),
    /// again within a few seconds to confirm.
    private var endKey: some View {
        Button {
            if endArmed {
                endArmed = false
                model.endSessionTapped()
            } else {
                withAnimation(.snappy) { endArmed = true }
            }
        } label: {
            Group {
                if endArmed {
                    Text("End?")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                } else {
                    Image(systemName: "xmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: endArmed ? 52 : 40, height: 42)
            .background(keyBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(KeyStyle())
        .accessibilityLabel(endArmed ? "Confirm end session" : "End Session")
        .task(id: endArmed) {
            guard endArmed else { return }
            try? await Task.sleep(for: .seconds(3))
            withAnimation(.snappy) { endArmed = false }
        }
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
                .frame(height: 42)
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

/// The typing half, as a real keyboard rather than a grid of buttons.
/// Everything that makes it feel like one — preview bubbles, slide-to-
/// correct, two-thumb rollover, long-press accents — needs a single view
/// tracking every touch, so the whole pad is UIKit. See KeyPlaneView.
struct TypePad: UIViewRepresentable {
    let model: KeyboardModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> KeyPlaneView {
        let plane = KeyPlaneView(frame: .zero)
        plane.delegate = context.coordinator
        // Shift starts where the sentence does, which only the host knows.
        plane.seedContext(model.documentTail)
        return plane
    }

    func updateUIView(_ uiView: KeyPlaneView, context: Context) {}

    @MainActor
    final class Coordinator: KeyPlaneDelegate {
        private let model: KeyboardModel
        init(model: KeyboardModel) { self.model = model }

        func keyPlane(_ plane: KeyPlaneView, didInsert text: String) {
            model.typeText(text)
        }
        func keyPlaneDidBackspace(_ plane: KeyPlaneView) { model.deleteTapped() }
        func keyPlaneDidTapReturn(_ plane: KeyPlaneView) { model.returnTapped() }
        func keyPlaneDidTapDictation(_ plane: KeyPlaneView) { model.setTyping(false) }
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

/// Measures a view's width so a sibling can reserve space for it.
private struct ClusterWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// Report this view's width into `width` — used so overlaid chips and
    /// the text beneath them never occupy the same points.
    func measuringWidth(into width: Binding<CGFloat>) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: ClusterWidthKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(ClusterWidthKey.self) { measured in
            if abs(width.wrappedValue - measured) > 0.5 { width.wrappedValue = measured }
        }
    }
}
