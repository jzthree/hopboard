import SwiftUI
import WhisperKit

struct ContentView: View {
    @EnvironmentObject private var session: SessionManager
    @State private var copiedResultID: UUID?
    @AppStorage(SessionManager.languageKey) private var languageCode = "auto"
    @AppStorage(SessionManager.modelKey) private var modelChoice = "turbo"
    @AppStorage("flow.onboarded") private var onboarded = false
    @State private var showOnboarding = false
    @State private var loadingStart: Date?

    /// Whisper's own language table (name → code), prettified and sorted.
    private static let languageChoices: [(name: String, code: String)] =
        Constants.languages
            .map { (name: $0.key.capitalized, code: $0.value) }
            .sorted { $0.name < $1.name }

    var body: some View {
        NavigationStack {
            List {
                sessionSection
                if let error = session.lastError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                }
                // History grows long, so it goes LAST — anything below it
                // would be unreachable. Settings stay compact above it, and
                // Setup disappears once both checks are green.
                promptSection
                if !setupComplete {
                    setupSection
                }
                historySection
            }
            .navigationTitle("FlowBoard")
            .tint(FlowBrand.accent)
            .animation(.snappy, value: session.state)
            .onAppear { if !onboarded { showOnboarding = true } }
            .onChange(of: session.modelState) { _, new in
                if case .loading = new {
                    if loadingStart == nil { loadingStart = Date() }
                } else {
                    loadingStart = nil
                }
            }
            .sheet(isPresented: $showOnboarding, onDismiss: { onboarded = true }) {
                OnboardingSheet()
            }
            .toolbar {
                Button {
                    showOnboarding = true
                } label: {
                    Image(systemName: "questionmark.circle")
                }
            }
        }
    }

    // MARK: session card

    private var sessionSection: some View {
        Section {
            VStack(spacing: 16) {
                switch session.state {
                case .idle:
                    idleCard
                case .loading:
                    loadingCard
                case .ready, .recording, .transcribing:
                    activeCard
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    private var idleCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Start a Flow Session, then dictate from the FlowBoard keyboard in any app.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await session.startSession() }
            } label: {
                Text("Start Flow Session")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var loadingCard: some View {
        VStack(spacing: 14) {
            switch session.modelState {
            case .downloading(let fraction):
                ProgressView(value: fraction) {
                    Text("Downloading large-v3-turbo (626 MB, one time)")
                        .font(.callout)
                }
                .progressViewStyle(.linear)
                Text("\(Int(fraction * 100))%")
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("Keep FlowBoard open until the download finishes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .loading:
                ProgressView()
                HStack(spacing: 6) {
                    Text("Optimizing for the Neural Engine")
                        .font(.callout)
                    if let start = loadingStart {
                        Text(timerInterval: start...Date.distantFuture, countsDown: false)
                            .font(.callout.monospacedDigit())
                    }
                }
                .foregroundStyle(.secondary)
                Text("One time only — takes a minute or two. Later sessions start in seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            default:
                ProgressView()
                Text("Preparing…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var activeCard: some View {
        VStack(spacing: 16) {
            LevelMeter(level: session.micLevel, active: session.state == .recording)
                .frame(height: 44)

            Text(activeCaption)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if session.state == .ready {
                // Calm, ambient hint — the bottom-edge swipe is a universal
                // iOS gesture; users just need to be reminded it applies.
                Label("Swipe along the bottom edge to hop back to your app",
                      systemImage: "arrow.backward.to.line")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 12) {
                // In-app dictation test — same path the keyboard drives.
                Button {
                    if session.state == .recording {
                        session.finishSegment()
                    } else {
                        session.beginSegment()
                    }
                } label: {
                    Label(session.state == .recording ? "Stop & Transcribe" : "Test Dictation",
                          systemImage: session.state == .recording ? "stop.circle.fill" : "mic.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(session.state == .transcribing)

                Button(role: .destructive) {
                    session.endSession()
                } label: {
                    Text("End")
                        .frame(minWidth: 64)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }

    private var activeCaption: String {
        switch session.state {
        case .recording: "Listening…"
        case .transcribing: "Transcribing…"
        default: "Session active — switch to any app and dictate from the FlowBoard keyboard. The mic indicator stays on until you end the session."
        }
    }

    // MARK: dictation settings

    private var promptSection: some View {
        Section {
            Picker("Language", selection: $languageCode) {
                Text("Auto-detect").tag("auto")
                ForEach(Self.languageChoices, id: \.code) { choice in
                    Text(choice.name).tag(choice.code)
                }
            }
            Picker("Tone", selection: $session.tone) {
                ForEach(FlowTone.allCases) { tone in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tone.label)
                        Text(tone.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("“\(tone.example)”")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .tag(tone)
                }
            }
            .pickerStyle(.navigationLink)
            Picker("Model", selection: $modelChoice) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fast")
                    Text("large-v3-turbo · recommended")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag("turbo")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Accurate")
                    Text("large-v3 · adds Chinese punctuation · extra 950 MB download, slower")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag("accurate")
            }
            .pickerStyle(.navigationLink)
            .onChange(of: modelChoice) { _, _ in
                // The new model loads on the next session start.
                session.endSession()
            }
        } header: {
            Text("Dictation")
        } footer: {
            Text("Pinning a language is faster and more accurate than auto-detect. Tone can also be switched right on the keyboard. For punctuated Chinese, pick the Accurate model AND pin the language to Chinese. Changes apply from your next session.")
        }
    }

    // MARK: setup checklist

    private var setupComplete: Bool {
        session.micPermission == .granted && session.keyboardSeen
    }

    private var setupSection: some View {
        Section("Setup") {
            checklistRow(
                done: session.micPermission == .granted,
                title: "Allow microphone access",
                detail: "Asked when you start your first session.")
            checklistRow(
                done: session.keyboardSeen,
                title: "Enable the keyboard",
                detail: "Settings → General → Keyboard → Keyboards → Add New Keyboard → FlowBoard, then turn on Allow Full Access.")
            Button {
                UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
            } label: {
                Label("Open Settings", systemImage: "gear")
            }
        }
    }

    private func checklistRow(done: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if !done {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: history

    private var historySection: some View {
        Section {
            if session.transcripts.isEmpty {
                Text("Dictations appear here.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(session.transcripts.reversed()) { result in
                    Button {
                        guard !result.text.isEmpty else { return }
                        UIPasteboard.general.string = result.text
                        copiedResultID = result.id
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            if copiedResultID == result.id { copiedResultID = nil }
                        }
                    } label: {
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(result.text.isEmpty ? "(no speech detected)" : result.text)
                                    .foregroundStyle(result.text.isEmpty ? .secondary : .primary)
                                Text(Date(timeIntervalSince1970: result.finishedAt),
                                     format: .dateTime.hour().minute())
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 0)
                            if !result.text.isEmpty {
                                if copiedResultID == result.id {
                                    Label("Copied", systemImage: "checkmark")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.green)
                                } else {
                                    Image(systemName: "doc.on.doc")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .animation(.snappy, value: copiedResultID)
                }
            }
        } header: {
            HStack {
                Text("History")
                Spacer()
                if !session.transcripts.isEmpty {
                    Button("Clear") { session.clearHistory() }
                        .font(.caption)
                }
            }
        } footer: {
            Text("Tap a dictation to copy it. Everything is transcribed on-device; audio never leaves your iPhone.")
        }
    }
}

/// First-run education: why FlowBoard works the way it does. iOS's keyboard
/// mic ban is the single fact that explains every quirk of the app.
struct OnboardingSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("keyboard.badge.ellipsis",
                        "Keyboards can't hear you",
                        "iOS never lets any keyboard extension use the microphone — an Apple privacy rule, with no exception. Every dictation keyboard, including Wispr Flow, has to work around it.")
                    row("waveform",
                        "So the app listens instead",
                        "Start a Flow Session here, and the FlowBoard app keeps recording in the background. The keyboard is a remote control: it tells the app when to listen and types out what came back.")
                    row("arrow.uturn.backward",
                        "Start, then swipe back",
                        "After starting a session, swipe back (or use the app switcher) to wherever you were typing. The FlowBoard keyboard picks the session up from there.")
                    row("circle.fill",
                        "The orange dot is honest",
                        "iOS shows the mic indicator the whole session, because the mic really is on. End the session from the keyboard (✕) or the app when you're done; it also ends itself after 15 idle minutes.",
                        tint: .orange)
                } footer: {
                    Text("Everything is transcribed on-device by Whisper large-v3-turbo. Audio never leaves your iPhone.")
                }
            }
            .navigationTitle("How FlowBoard works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Got it") { dismiss() }
                    .bold()
            }
        }
    }

    private func row(_ icon: String, _ title: String, _ body: String, tint: Color = FlowBrand.accent) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(body).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// A row of bars that breathes with the mic level.
struct LevelMeter: View {
    let level: Float
    let active: Bool

    private static let profile: [CGFloat] = [0.35, 0.6, 0.85, 1.0, 0.85, 0.6, 0.35, 0.5, 0.75, 0.95, 0.75, 0.5]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(Self.profile.enumerated()), id: \.offset) { _, weight in
                Capsule()
                    .fill(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .frame(width: 5)
                    .scaleEffect(y: barScale(weight), anchor: .center)
            }
        }
        .animation(.easeOut(duration: 0.15), value: level)
        .animation(.easeInOut(duration: 0.3), value: active)
    }

    private func barScale(_ weight: CGFloat) -> CGFloat {
        guard active else { return 0.25 }
        return max(0.15, min(1, 0.2 + CGFloat(level) * weight))
    }
}
