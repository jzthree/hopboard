import SwiftUI
import WhisperKit

struct ContentView: View {
    @EnvironmentObject private var session: SessionManager
    @State private var copiedResultID: UUID?
    @AppStorage(SessionManager.promptKey) private var promptText = ""
    @AppStorage(SessionManager.languageKey) private var languageCode = "auto"
    @AppStorage(FlowTone.defaultsKey) private var toneRaw = FlowTone.formal.rawValue

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
                promptSection
                setupSection
                historySection
            }
            .navigationTitle("FlowBoard")
            .tint(FlowBrand.accent)
            .animation(.snappy, value: session.state)
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
                Text("Optimizing for the Neural Engine — the first load takes about a minute, later loads a few seconds.")
                    .font(.callout)
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

    // MARK: custom prompt

    private var promptSection: some View {
        Section {
            Picker("Language", selection: $languageCode) {
                Text("Auto-detect").tag("auto")
                ForEach(Self.languageChoices, id: \.code) { choice in
                    Text(choice.name).tag(choice.code)
                }
            }
            Picker("Tone", selection: $toneRaw) {
                ForEach(FlowTone.allCases) { tone in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tone.label)
                        Text(tone.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(tone.rawValue)
                }
            }
            TextField("Names, jargon, punctuation style…",
                      text: $promptText, axis: .vertical)
                .lineLimit(2...4)
                .autocorrectionDisabled()
        } header: {
            Text("Dictation")
        } footer: {
            Text("Pinning a language is faster and more accurate than auto-detect. The vocabulary field is fed to Whisper as its initial prompt — write names and jargon the way you want them spelled, in the punctuation style you want back. Both apply from your next dictation.")
        }
    }

    // MARK: setup checklist

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
