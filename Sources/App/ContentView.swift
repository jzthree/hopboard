import AVFoundation
import SwiftUI
import WhisperKit

struct ContentView: View {
    @EnvironmentObject private var session: SessionManager
    @State private var copiedResultID: UUID?
    @AppStorage(SessionManager.modelKey) private var modelChoice = "turbo"
    @AppStorage(SessionManager.gemmaThinkingKey) private var gemmaThinking = false
    @AppStorage(SessionManager.gemmaThinkingBudgetKey) private var gemmaThinkingBudget = 48
    @AppStorage(SessionManager.gemmaCustomInstructionKey) private var gemmaCustomInstruction = ""
    @AppStorage(SessionManager.litertVariantKey) private var litertVariant = "e2b"
    @AppStorage(SessionManager.vocabularyKey) private var vocabulary = ""
    @AppStorage("flow.onboarded") private var onboarded = false
    @State private var showOnboarding = false
    @State private var loadingStart: Date?
    @Environment(\.scenePhase) private var scenePhase

    /// Whisper's own language table (name → code), prettified and sorted.
    static let languageChoices: [(name: String, code: String)] =
        Constants.languages
            .map { (name: $0.key.capitalized, code: $0.value) }
            .sorted { $0.name < $1.name }

    private static let settingsAnchor = "dictation-settings"

    /// Don't advertise a mode when the voice-processing unit isn't actually
    /// running — it declines on some routes, and we fall back to plain
    /// capture rather than failing to record.
    private var micModeValue: String {
        if session.state != .idle, !session.voiceProcessingActive {
            return "Unavailable on this route"
        }
        return micModeName
    }

    /// The mode the user picked in Control Center, named as iOS names it.
    private var micModeName: String {
        switch AVCaptureDevice.preferredMicrophoneMode {
        case .voiceIsolation: "Voice Isolation"
        case .wideSpectrum: "Wide Spectrum"
        default: "Standard"
        }
    }

    private var vocabularySummary: String {
        let count = FlowVocabulary.terms(from: vocabulary).count
        return count == 0 ? "None" : "\(count) term\(count == 1 ? "" : "s")"
    }

    static func languageDisplayName(_ code: String) -> String {
        if code == "auto" { return "Auto" }
        return languageChoices.first { $0.code == code }?.name ?? code.uppercased()
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroller in
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
                    .id(Self.settingsAnchor)
                if !setupComplete {
                    setupSection
                }
                historySection
            }
            .onChange(of: session.showSettings) { _, wanted in
                // The keyboard's gear key: land on the settings, not the top.
                guard wanted else { return }
                withAnimation { scroller.scrollTo(Self.settingsAnchor, anchor: .top) }
                session.showSettings = false
            }
            }
            .navigationTitle("HopBoard")
            .tint(FlowBrand.accent)
            .animation(.snappy, value: session.state)
            .onAppear {
                if !onboarded { showOnboarding = true }
                session.refreshSetupState()
            }
            .onChange(of: scenePhase) { _, phase in
                // Coming back from Settings: reflect the keyboard toggle
                // immediately so the user sees that it worked.
                if phase == .active { session.refreshSetupState() }
            }
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
            Text("Start a Session, then dictate from the HopBoard keyboard in any app.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await session.startSession() }
            } label: {
                Text("Start Session")
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
                    Text("Downloading \(SessionManager.selectedModelDescription())")
                        .font(.callout)
                }
                .progressViewStyle(.linear)
                Text("\(Int(fraction * 100))%")
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("Keep HopBoard open until the download finishes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .loading:
                ProgressView()
                HStack(spacing: 6) {
                    Text(session.loadingLabel)
                        .font(.callout)
                    if let start = loadingStart {
                        Text(timerInterval: start...Date.distantFuture, countsDown: false)
                            .font(.callout.monospacedDigit())
                    }
                }
                .foregroundStyle(.secondary)
                Text("Keep HopBoard open. The first load after an update takes a few minutes; after that, seconds.")
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

            HStack(spacing: 6) {
                Text(activeCaption)
                    .font(.callout)
                if session.state == .transcribing, let since = session.transcribingSince {
                    Text(timerInterval: since...Date.distantFuture, countsDown: false)
                        .font(.callout.monospacedDigit())
                }
            }
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            if session.state == .ready {
                // Unhurried but unmissable: a static tinted pill, no motion.
                Label("Swipe along the bottom edge to hop back to your app",
                      systemImage: "arrow.backward.to.line")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassPill(tint: FlowBrand.accent)
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
        default: "Session active — switch to any app and dictate from the HopBoard keyboard. The mic indicator stays on until you end the session."
        }
    }

    // MARK: dictation settings

    private var promptSection: some View {
        Section {
            Picker("Language", selection: $session.language) {
                // The Apple engine has no detection — Auto would silently
                // mean "device language", so it isn't offered there.
                if modelChoice != "apple" {
                    Text("Auto-detect").tag("auto")
                }
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
                    Text("large-v3 · adds Chinese punctuation · 950 MB")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag("accurate")
                if #available(iOS 26.0, *) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Apple (iOS 26)")
                        Text("Apple's own · fast · punctuates Chinese · no download")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag("apple")
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gemma 4 (experimental)")
                    Text("audio LLM · styled tone, punctuated Chinese · 4.1 GB")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag("gemma")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gemma 4 LiteRT (experimental)")
                    Text("same model, Google's runtime · QAT quant · 2.6 GB")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag("litert")
            }
            .pickerStyle(.navigationLink)
            .onChange(of: modelChoice) { _, _ in
                // The new model loads on the next session start.
                session.endSession()
                session.syncLanguagePolicy()
            }
            // Only while a session holds the mic: Control Center's mic-mode
            // control exists for the app that is CAPTURING, so with no
            // session this row leads to a picker that can't offer HopBoard.
            if session.state != .idle {
                Button {
                    AVCaptureDevice.showSystemUserInterface(.microphoneModes)
                } label: {
                    LabeledContent("Mic mode", value: micModeValue)
                }
                .foregroundStyle(.primary)
            }
            NavigationLink {
                VocabularyEditor()
            } label: {
                LabeledContent("Vocabulary", value: vocabularySummary)
            }
            NavigationLink {
                KeyboardLanguagesEditor()
            } label: {
                LabeledContent("Keyboard languages",
                               value: session.favoriteLanguages
                                   .map { Self.languageDisplayName($0) }
                                   .joined(separator: " · "))
            }
            if modelChoice == "gemma" || modelChoice == "litert" {
                if modelChoice == "litert" {
                    Picker("Size", selection: $litertVariant) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("E2B")
                            Text("2.6 GB · faster")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag("e2b")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("E4B")
                            Text("3.7 GB · more accurate, slower")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag("e4b")
                    }
                    .pickerStyle(.navigationLink)
                    .onChange(of: litertVariant) { _, _ in
                        // The new size loads on the next session start.
                        session.endSession()
                    }
                }
                // Thinking knobs are llama.cpp-path only: LiteRT's shipped
                // binaries predate the thinking API, so showing the controls
                // there would be showing switches wired to nothing.
                if modelChoice == "gemma" {
                    Toggle("Gemma thinking", isOn: $gemmaThinking)
                    if gemmaThinking {
                        Picker("Thinking budget", selection: $gemmaThinkingBudget) {
                            Text("Brief · 48 tokens").tag(48)
                            Text("Medium · 160 tokens").tag(160)
                            Text("Unlimited").tag(0)
                        }
                    }
                }
                NavigationLink {
                    GemmaPromptEditor(
                        defaultInstruction: GemmaEngine.instruction(
                            language: session.language, tone: session.tone,
                            vocabulary: FlowVocabulary.current()),
                        // LiteRT applies Gemma's template inside the runtime,
                        // so the llama.cpp assembly preview would be a lie.
                        showsAssembledPrompt: modelChoice == "gemma")
                } label: {
                    LabeledContent("Prompt",
                                   value: gemmaCustomInstruction
                                       .trimmingCharacters(in: .whitespacesAndNewlines)
                                       .isEmpty ? "Default" : "Custom")
                }
            }
        } header: {
            Text("Dictation")
        } footer: {
            Text("Pin a language — it beats auto-detect, and the Apple model does one at a time. Language and tone are on the keyboard too.")
        }
    }

    // MARK: setup checklist

    private var setupComplete: Bool {
        session.micPermission == .granted && session.keyboardEnabled && session.keyboardSeen
    }

    private var setupSection: some View {
        Section("Setup") {
            // Microphone: don't show an unactionable to-do before iOS has
            // ever asked — there is nothing the user can do until then.
            switch session.micPermission {
            case .granted:
                checklistRow(state: .done, title: "Microphone access", detail: "")
            case .denied:
                checklistRow(state: .blocked,
                             title: "Microphone access denied",
                             detail: "Open Settings → Microphone and turn it on.")
            default:
                checklistRow(state: .pending,
                             title: "Microphone access",
                             detail: "iOS asks automatically when you start your first session — nothing to do yet.")
            }
            checklistRow(
                state: session.keyboardEnabled ? .done : .todo,
                title: "Enable the HopBoard keyboard",
                detail: "Tap Open Settings below → Keyboards → turn on HopBoard and Allow Full Access.")
            checklistRow(
                state: session.keyboardSeen ? .done : .pending,
                title: "Full Access working",
                detail: session.keyboardEnabled
                    ? "Confirmed automatically the first time you use the HopBoard keyboard."
                    : "Confirmed automatically once the keyboard is enabled and used.")
            Button {
                UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
            } label: {
                Label("Open Settings", systemImage: "gear")
            }
        }
    }

    private enum ChecklistState { case done, todo, pending, blocked }

    private func checklistRow(state: ChecklistState, title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            switch state {
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .todo:
                Image(systemName: "circle").foregroundStyle(.secondary)
            case .pending:
                Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
            case .blocked:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if state != .done, !detail.isEmpty {
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

/// First-run education: why HopBoard works the way it does. iOS's keyboard
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
                        "Start a Session here, and the HopBoard app keeps recording in the background. The keyboard is a remote control: it tells the app when to listen and types out what came back.")
                    row("arrow.uturn.backward",
                        "Start, then swipe back",
                        "After starting a session, swipe back (or use the app switcher) to wherever you were typing. The HopBoard keyboard picks the session up from there.")
                    row("circle.fill",
                        "The orange dot is honest",
                        "iOS shows the mic indicator the whole session, because the mic really is on. End the session from the keyboard (✕) or the app when you're done; it also ends itself after 15 idle minutes.",
                        tint: .orange)
                } footer: {
                    Text("Everything is transcribed on-device by Whisper large-v3-turbo. Audio never leaves your iPhone.")
                }
            }
            .navigationTitle("How HopBoard works")
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

/// Advanced mode: see and edit the exact instruction Gemma receives.
/// The "exact prompt" preview renders GemmaEngine.assemblePrompt — the
/// same function transcribe() uses — so it can never drift from reality.
struct GemmaPromptEditor: View {
    /// The built-in instruction for the currently pinned language + tone,
    /// shown and restored by Reset.
    let defaultInstruction: String
    /// The llama.cpp engine assembles the template itself, so the exact
    /// prompt is showable; LiteRT templates inside the runtime, so for it
    /// only the instruction is ours to show.
    var showsAssembledPrompt = true

    @AppStorage(SessionManager.gemmaCustomInstructionKey) private var custom = ""
    @AppStorage(SessionManager.gemmaThinkingKey) private var thinking = false
    @State private var text = ""

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Mirrors SessionManager.gemmaCustomInstruction(): blank means default.
    private var isCustom: Bool { !trimmed.isEmpty && trimmed != defaultInstruction }
    private var effectiveInstruction: String {
        isCustom ? trimmed : defaultInstruction
    }

    var body: some View {
        List {
            Section {
                TextEditor(text: $text)
                    .frame(minHeight: 140)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: text) { _, _ in
                        custom = isCustom ? trimmed : ""
                    }
                Button("Reset to default") {
                    text = defaultInstruction
                    custom = ""
                }
                .disabled(!isCustom)
            } header: {
                Text("Instruction · \(isCustom ? "custom" : "default")")
            } footer: {
                Text("A custom instruction replaces the built-in one for every dictation, so language and tone stop shaping the prompt.")
            }
            if showsAssembledPrompt {
                Section {
                    Text(GemmaEngine.assemblePrompt(instruction: effectiveInstruction,
                                                    thinking: thinking))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } header: {
                    Text("Exact prompt sent to Gemma")
                } footer: {
                    Text("The placeholder is your recording.")
                }
            } else {
                Section {
                    Text("LiteRT applies Gemma's template itself.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Gemma Prompt")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let saved = custom.trimmingCharacters(in: .whitespacesAndNewlines)
            text = saved.isEmpty ? defaultInstruction : saved
        }
    }
}

/// Pick the languages the keyboard's chip cycles through. Order is
/// canonical (Auto first, then A→Z) so the cycle is predictable.
struct KeyboardLanguagesEditor: View {
    @EnvironmentObject private var session: SessionManager

    private var selection: Set<String> { Set(session.favoriteLanguages) }

    var body: some View {
        List {
            Section {
                row(code: "auto", name: "Auto-detect")
                ForEach(ContentView.languageChoices, id: \.code) { choice in
                    row(code: choice.code, name: choice.name)
                }
            } header: {
                Text(session.favoriteLanguagesAreCustom ? "Custom" : "From your iOS languages & keyboards")
            } footer: {
                Text("The keyboard's language chip cycles these. Follows your iOS languages until you change them here.")
            }
            if session.favoriteLanguagesAreCustom {
                Section {
                    Button("Follow iOS languages & keyboards") {
                        session.resetFavoriteLanguagesToSystem()
                    }
                }
            }
        }
        .navigationTitle("Keyboard Languages")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(code: String, name: String) -> some View {
        Button {
            var updated = selection
            if updated.contains(code) {
                // Never empty: the chip needs something to cycle to.
                guard updated.count > 1 else { return }
                updated.remove(code)
            } else {
                updated.insert(code)
            }
            let ordered = ["auto"] + ContentView.languageChoices.map(\.code)
            session.setFavoriteLanguages(ordered.filter { updated.contains($0) })
        } label: {
            HStack {
                Text(name)
                    .foregroundStyle(.primary)
                Spacer()
                if selection.contains(code) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
    }
}

/// Names and jargon, spelled the way you want them. Deliberately NOT a
/// replacement list: you can't predict what a model will hear, so you
/// write only the correct term and matching handles the rest — sound-alike
/// spellings in English, homophones by pinyin in Chinese.
struct VocabularyEditor: View {
    @AppStorage(SessionManager.vocabularyKey) private var vocabulary = ""
    @State private var draft = ""
    @State private var probe = ""

    private var terms: [String] { FlowVocabulary.terms(from: draft) }

    var body: some View {
        List {
            Section {
                TextEditor(text: $draft)
                    .frame(minHeight: 160)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: draft) { _, new in vocabulary = new }
            } header: {
                Text("One per line · \(terms.count) term\(terms.count == 1 ? "" : "s")")
            } footer: {
                Text("Write each name as it should appear. Matching is by sound: \u{201C}hop board\u{201D} becomes HopBoard, and a Chinese homophone is corrected by pinyin.")
            }

            Section {
                TextField("Paste a dictation to check", text: $probe, axis: .vertical)
                    .lineLimit(1...4)
                    .autocorrectionDisabled()
                if !probe.isEmpty {
                    let corrected = FlowVocabulary.apply(probe, terms: terms)
                    Text(corrected)
                        .font(.callout)
                        .foregroundStyle(corrected == probe ? .secondary : .primary)
                    if corrected == probe {
                        Text("No change — nothing matched closely enough.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            } header: {
                Text("Try it")
            }
        }
        .navigationTitle("Vocabulary")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { draft = vocabulary }
    }
}
