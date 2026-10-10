import Foundation
import Security

// The contract between the HopBoard app and its keyboard extension.
// The keyboard can never touch the microphone (iOS forbids it for every
// keyboard extension), so the app owns the mic and the model, and the two
// sides meet in shared storage: payloads in keychain items, wake-ups over
// Darwin notifications.
//
// Why keychain and not an App Group? App Groups need a portal registration
// the App Store Connect API cannot perform (no appGroups resource — probed
// live, 404) and this machine has no signed-in Xcode account. Development
// profiles for this team carry `keychain-access-groups: 5AD7QB9795.*`, so a
// team keychain group is shared storage both processes can use today.

enum Flow {
    static let keychainAccessGroup = "5AD7QB9795.io.zhoulab.hopboard.ipc"
    static let keychainService = "io.zhoulab.hopboard.ipc"
    static let startSessionURL = URL(string: "hopboard://session/start")!
    /// The keyboard's gear: open the app straight to dictation settings.
    static let settingsURL = URL(string: "hopboard://settings")!
    /// Full Access is off. A keyboard extension cannot open Settings — it
    /// has no UIApplication — so it hands off to the app, which can, and
    /// which lands on HopBoard's own page where the Keyboards row lives.
    static let fullAccessURL = URL(string: "hopboard://fullaccess")!

    // Darwin notification names are a global namespace — prefix everything.
    static let commandNotification = "io.zhoulab.hopboard.command"
    static let stateNotification = "io.zhoulab.hopboard.state"

    // A session whose heartbeat is older than this is dead (app was killed
    // or suspended); the keyboard falls back to "Start Session".
    static let heartbeatTimeout: TimeInterval = 8
}

enum SessionState: String {
    case idle          // no session; app may not even be running
    case loading       // model downloading / compiling / audio starting
    case ready         // engine live, waiting for a segment
    case recording     // capturing a dictation segment
    case transcribing  // segment ended, Whisper is running
}

struct FlowCommand: Codable, Equatable {
    enum Action: String, Codable {
        case startSegment, stopSegment, cancelSegment, retranscribe, endSession
    }
    let id: UUID
    let action: Action
    let sentAt: Double
}

struct FlowResult: Codable, Identifiable, Equatable {
    let id: UUID
    let text: String
    let finishedAt: Double
}

/// What reading the host document told us about an insert. Everything but
/// `reverted` comes from `FlowText.insertVerdict`; `reverted` is temporal —
/// only the keyboard, watching across polls, can see a host accept the text
/// and then take it back.
enum InsertVerdict: String, Codable {
    case landed              // the cursor now sits right after our text
    case landedUnverifiable  // a secure field: it has text, we can't read it
    case reverted            // it appeared, then the host's own state won
    case notAtCursor         // the field's text does not end with ours
    case unreadable          // the host reports no document to read at all
    case noField             // nothing focused; insertText went nowhere

    /// Whether the dictation may be retired. Unverifiable counts — refusing
    /// to ever finish in a password field would leave a permanent pill.
    var isDelivered: Bool { self == .landed || self == .landedUnverifiable }

    /// Shown against the dictation in the app's history.
    var summary: String {
        switch self {
        case .landed: "Inserted at the cursor"
        case .landedUnverifiable: "Inserted — the field wouldn't confirm it"
        case .reverted: "The app took it, then removed it"
        case .notAtCursor: "The app didn't accept it"
        case .unreadable: "The app won't say — offered instead of assumed"
        case .noField: "No text field was focused"
        }
    }
}

/// What became of one dictation after the keyboard typed it. Recorded so a
/// delivery that silently went nowhere can be SEEN rather than guessed at.
struct FlowDelivery: Codable, Identifiable, Equatable {
    /// The result this describes.
    let id: UUID
    let verdict: InsertVerdict
    let at: Double
}

/// Minimal key→Data storage the two processes share.
protocol FlowBackend {
    func data(forKey key: String) -> Data?
    func set(_ data: Data, forKey key: String)
    func removeValue(forKey key: String)
    func keys(withPrefix prefix: String) -> [String]
}

/// Keychain-backed shared storage. Items live in the team access group with
/// AfterFirstUnlock so the backgrounded app can keep using them.
final class KeychainBackend: FlowBackend {
    /// Why the last write failed. Security silently swallows OSStatus
    /// everywhere else in here, which is fine until the day IPC stops
    /// working and the only thing anyone can say is "it doesn't work".
    private(set) var lastStatus: OSStatus = errSecSuccess
    /// And why the last READ failed. "Write ok, read back wrong" was true
    /// but useless: it could not tell an item that was not there from one
    /// that was there with different bytes, and those are different bugs.
    private(set) var lastReadStatus: OSStatus = errSecSuccess
    private(set) var lastReadCount = 0

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Flow.keychainService,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: Flow.keychainAccessGroup,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    func data(forKey key: String) -> Data? {
        // All matches, not the first one. A duplicate left behind by a
        // previous install answers to the same service and account, and
        // kSecMatchLimitOne hands back whichever the keychain feels like —
        // which is how a write can succeed and the read come back stale.
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        lastReadStatus = status
        guard status == errSecSuccess else {
            lastReadCount = 0
            return nil
        }
        if let items = out as? [Data] {
            lastReadCount = items.count
            return items.last
        }
        lastReadCount = 1
        return out as? Data
    }

    func set(_ data: Data, forKey key: String) {
        let update: [String: Any] = [kSecValueData as String: data]
        let updated = SecItemUpdate(baseQuery(for: key) as CFDictionary,
                                    update as CFDictionary)
        if updated == errSecSuccess {
            lastStatus = updated
            return
        }
        // ANY other outcome gets the same treatment: clear the slot and
        // write it fresh. The old code only fell through on
        // errSecItemNotFound and returned on everything else, so a single
        // un-updatable item meant this key could never be written again —
        // and deleting an app is exactly how you get one, since items in a
        // shared access group outlive the install that made them and come
        // back owned by an ACL the new install cannot touch.
        SecItemDelete(baseQuery(for: key) as CFDictionary)
        var add = baseQuery(for: key)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        lastStatus = SecItemAdd(add as CFDictionary, nil)
    }

    func removeValue(forKey key: String) {
        SecItemDelete(baseQuery(for: key) as CFDictionary)
    }

    func keys(withPrefix prefix: String) -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Flow.keychainService,
            kSecAttrAccessGroup as String: Flow.keychainAccessGroup,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
            .filter { $0.hasPrefix(prefix) }
    }
}

/// Both processes construct their own instance. `isAvailable` probes the
/// backend with a real round-trip, because the only failure that matters is
/// "the other process won't see my writes".
final class FlowStore {
    private let backend: FlowBackend
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private enum Key {
        static let state = "flow.sessionState"
        static let heartbeat = "flow.heartbeat"
        static let command = "flow.command"
        static let results = "flow.results"
        static let consumed = "flow.lastConsumedResult"
        static let deliveries = "flow.deliveries"
        static let micLevel = "flow.micLevel"
        static let keyboardSeen = "flow.keyboardSeen"
        static let modelStatus = "flow.modelStatus"
        static let probe = "flow.probe"
        static let tone = "flow.tone"
        static let language = "flow.sharedLanguage"
        static let favoriteLanguages = "flow.favLanguages"
        static let favoriteLanguagesCustomized = "flow.favLangCustom"
        static let autoLanguageAllowed = "flow.autoLangAllowed"
        static let canRetranscribe = "flow.canRetranscribe"
        static let keyboardBuild = "flow.keyboardBuild"
    }

    init(backend: FlowBackend = KeychainBackend()) {
        self.backend = backend
    }

    /// Can this process actually exchange data with the other one?
    ///
    /// Retried, because a single failed round trip is not evidence of a
    /// broken channel — and declaring it broken is expensive, since the
    /// keyboard then refuses to do anything that needs the app. The first
    /// attempt also CLEARS the slot, which is the fix for a duplicate left
    /// behind by a previous install: those answer the same query, and a
    /// read could return the stale one however well the write went.
    var isAvailable: Bool {
        // A FRESH account name per attempt. The probe used to reuse one
        // key, so a single item stuck in a state this process can neither
        // read, update nor delete defeated it permanently — which is
        // exactly what "write ok, read ok, 0 items" describes: the write
        // reports success and the read finds nothing, for one particular
        // name, for ever. A name nothing has used before cannot collide
        // with a ghost. Each attempt cleans up after itself.
        for _ in 0..<3 {
            let key = Key.probe + "." + UUID().uuidString
            let nonce = UUID().uuidString.data(using: .utf8)!
            backend.set(nonce, forKey: key)
            let readBack = backend.data(forKey: key)
            backend.removeValue(forKey: key)
            if readBack == nonce { return true }
        }
        return false
    }

    /// Evidence beats proxies. The probe asks whether a synthetic write
    /// survives a round trip; the heartbeat is the app's own writing,
    /// arriving here, which is the only thing the probe was ever standing
    /// in for. If that is readable and fresh then IPC demonstrably works,
    /// whatever a test key does.
    var ipcProven: Bool {
        isAvailable || Date().timeIntervalSince(heartbeat) < Flow.heartbeatTimeout
    }

    /// Sweep up probe keys from older builds, which reused one name and
    /// may have left it jammed.
    func clearStaleProbes() {
        backend.removeValue(forKey: Key.probe)
        for key in backend.keys(withPrefix: Key.probe + ".") {
            backend.removeValue(forKey: key)
        }
    }

    /// What the last probe's write returned, named where there is a name
    /// for it. -34018 is the one that matters: the entitlement is missing,
    /// which is a signing problem and not something a user can fix by
    /// toggling anything.
    var probeDiagnosis: String {
        guard let keychain = backend as? KeychainBackend else { return "no keychain" }
        if keychain.lastStatus != errSecSuccess {
            switch keychain.lastStatus {
            case errSecMissingEntitlement: return "write -34018 entitlement"
            case errSecInteractionNotAllowed: return "write -25308 locked"
            default: return "write \(keychain.lastStatus)"
            }
        }
        if keychain.lastReadStatus != errSecSuccess {
            return "read \(keychain.lastReadStatus)"
        }
        return "read ok, \(keychain.lastReadCount) items, bytes differ"
    }

    // MARK: primitives

    private func string(_ key: String) -> String? {
        backend.data(forKey: key).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func setString(_ value: String, _ key: String) {
        backend.set(Data(value.utf8), forKey: key)
    }

    private func double(_ key: String) -> Double {
        string(key).flatMap(Double.init) ?? 0
    }

    // MARK: session state (app writes, keyboard reads)

    var state: SessionState {
        get { string(Key.state).flatMap(SessionState.init(rawValue:)) ?? .idle }
        set { setString(newValue.rawValue, Key.state) }
    }

    var heartbeat: Date {
        get { Date(timeIntervalSince1970: double(Key.heartbeat)) }
        set { setString(String(newValue.timeIntervalSince1970), Key.heartbeat) }
    }

    /// One line of human-readable model progress ("Downloading 42%…").
    var modelStatus: String {
        get { string(Key.modelStatus) ?? "" }
        set { setString(newValue, Key.modelStatus) }
    }

    /// Coarse 0–1 mic level, written at ~5 Hz only while recording.
    var micLevel: Float {
        get { Float(double(Key.micLevel)) }
        set { setString(String(newValue), Key.micLevel) }
    }

    /// Which build of the KEYBOARD last ran, written by the extension
    /// itself. iOS keeps a keyboard extension's old binary alive long
    /// after the containing app has been replaced, so "I installed it and
    /// nothing changed" has two very different causes — a stale extension,
    /// or a change that was never visible — and no way to tell them apart
    /// by looking. This tells them apart.
    var keyboardBuild: String {
        get { string(Key.keyboardBuild) ?? "" }
        set { setString(newValue, Key.keyboardBuild) }
    }

    /// Whether the app still holds the last dictation's audio, so the
    /// keyboard only offers a re-run it can actually honour.
    var canRetranscribe: Bool {
        get { string(Key.canRetranscribe) == "true" }
        set { setString(newValue ? "true" : "false", Key.canRetranscribe) }
    }

    var sessionAlive: Bool {
        state != .idle && Date().timeIntervalSince(heartbeat) < Flow.heartbeatTimeout
    }

    // MARK: commands (keyboard writes, app reads)
    //
    // A QUEUE, not a slot: each command is its own item under a sortable
    // key. A single shared slot lost the start command whenever start and
    // stop landed inside one poll interval — the app then ignored the
    // orphan stop and the keyboard spun on "Transcribing…" forever.

    /// Tiebreaker for commands enqueued within the same millisecond — a
    /// random suffix let a same-ms start+stop pair drain out of order.
    /// Single writer (the keyboard), so a process-local counter suffices.
    private var commandSequence = 0

    func send(_ action: FlowCommand.Action) {
        let command = FlowCommand(id: UUID(), action: action, sentAt: Date().timeIntervalSince1970)
        guard let data = try? encoder.encode(command) else { return }
        commandSequence += 1
        let key = Key.command + String(format: ".%013.0f.%04d",
                                       command.sentAt * 1000,
                                       commandSequence % 10000)
        backend.set(data, forKey: key)
    }

    /// Drains every pending command, oldest first.
    func takeCommands() -> [FlowCommand] {
        let keys = backend.keys(withPrefix: Key.command + ".").sorted()
        var commands: [FlowCommand] = []
        for key in keys {
            if let data = backend.data(forKey: key),
               let command = try? decoder.decode(FlowCommand.self, from: data) {
                commands.append(command)
            }
            backend.removeValue(forKey: key)
        }
        return commands
    }

    // MARK: results (app writes, keyboard consumes)

    /// Dictations are ephemeral: at most 20 kept, nothing older than 24 h.
    static let resultMaxAge: TimeInterval = 24 * 3600

    private(set) var results: [FlowResult] {
        get {
            guard let data = backend.data(forKey: Key.results),
                  let results = try? decoder.decode([FlowResult].self, from: data) else { return [] }
            let cutoff = Date().timeIntervalSince1970 - Self.resultMaxAge
            return results.filter { $0.finishedAt > cutoff }
        }
        set {
            if let data = try? encoder.encode(newValue.suffix(20)) {
                backend.set(data, forKey: Key.results)
            }
        }
    }

    func append(_ result: FlowResult) {
        results.append(result)
    }

    func clearResults() {
        backend.removeValue(forKey: Key.results)
        backend.removeValue(forKey: Key.consumed)
        backend.removeValue(forKey: Key.deliveries)
    }

    /// The keyboard's verdict on each dictation it typed (newest last),
    /// capped like results — a breadcrumb trail, not a log. The app reads
    /// them so "it said it inserted and nothing appeared" stops being a
    /// story and becomes a record.
    private(set) var deliveries: [FlowDelivery] {
        get {
            guard let data = backend.data(forKey: Key.deliveries),
                  let stored = try? decoder.decode([FlowDelivery].self, from: data)
            else { return [] }
            return stored
        }
        set {
            if let data = try? encoder.encode(newValue.suffix(20)) {
                backend.set(data, forKey: Key.deliveries)
            }
        }
    }

    /// One record per dictation: a re-insert from the pill replaces the
    /// earlier verdict rather than stacking a second one.
    func record(_ delivery: FlowDelivery) {
        deliveries = deliveries.filter { $0.id != delivery.id } + [delivery]
    }

    var lastConsumedResultID: UUID? {
        get { string(Key.consumed).flatMap(UUID.init(uuidString:)) }
        set {
            if let id = newValue {
                setString(id.uuidString, Key.consumed)
            } else {
                backend.removeValue(forKey: Key.consumed)
            }
        }
    }

    /// The newest result the keyboard has not yet inserted.
    func nextUnconsumedResult() -> FlowResult? {
        guard let last = results.last else { return nil }
        if last.id == lastConsumedResultID { return nil }
        return last
    }

    // MARK: settings both sides can change (tone chip on the keyboard)

    var tone: FlowTone {
        get { string(Key.tone).flatMap(FlowTone.init(rawValue:)) ?? .formal }
        set { setString(newValue.rawValue, Key.tone) }
    }

    /// Dictation language: whisper code or "auto". The keyboard's language
    /// chip changes it too — critical for single-locale engines (Apple),
    /// where dictating English through the Chinese model produces garbage.
    /// "" = never set; the app seeds it from its old UserDefaults value.
    var language: String {
        get { string(Key.language) ?? "" }
        set { setString(newValue, Key.language) }
    }

    /// The languages the keyboard's chip cycles through — user-pinned in
    /// the app's config, stored comma-joined.
    var favoriteLanguages: [String] {
        get {
            let stored = string(Key.favoriteLanguages) ?? ""
            return stored.isEmpty ? ["auto", "en", "zh"]
                                  : stored.split(separator: ",").map(String.init)
        }
        set { setString(newValue.joined(separator: ","), Key.favoriteLanguages) }
    }

    /// False while a no-detection engine (Apple) is selected: "auto" would
    /// silently mean "device language", so the chip must skip it.
    var autoLanguageAllowed: Bool {
        get { string(Key.autoLanguageAllowed) != "false" }
        set { setString(newValue ? "true" : "false", Key.autoLanguageAllowed) }
    }

    /// True once the user edits the Keyboard Languages checklist. Until
    /// then the app re-derives the list from iOS's languages & keyboards
    /// on every launch, so system changes keep flowing through.
    var favoriteLanguagesCustomized: Bool {
        get { string(Key.favoriteLanguagesCustomized) == "true" }
        set { setString(newValue ? "true" : "false", Key.favoriteLanguagesCustomized) }
    }

    // MARK: onboarding breadcrumbs (keyboard writes, app reads)

    var keyboardSeen: Bool {
        get { string(Key.keyboardSeen) == "true" }
        set { setString(newValue ? "true" : "false", Key.keyboardSeen) }
    }
}

/// Cross-process wake-ups. Darwin notifications carry no payload — the
/// payload always lives in FlowStore; the notification just says "look".
final class DarwinBus {
    private var handlers: [String: () -> Void] = [:]

    func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString), nil, nil, true)
    }

    /// Register on a thread with a run loop (main). Handler hops to main.
    func observe(_ name: String, handler: @escaping () -> Void) {
        handlers[name] = handler
        let observer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            { _, observer, name, _, _ in
                guard let observer, let name else { return }
                let bus = Unmanaged<DarwinBus>.fromOpaque(observer).takeUnretainedValue()
                let key = name.rawValue as String
                DispatchQueue.main.async { bus.handlers[key]?() }
            },
            name as CFString, nil, .deliverImmediately)
    }

    deinit {
        let observer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), observer)
    }
}

enum FlowText {
    /// Whisper emits half-width punctuation ("," "!") inside Chinese text;
    /// convert to full-width when it follows a CJK character. Apple's
    /// transcriber pads full-width marks with a stray ASCII space
    /// ("呢 ，") — drop whitespace that directly precedes one.
    static func normalizeCJKPunctuation(_ text: String) -> String {
        let map: [Character: Character] = [",": "，", ";": "；", "?": "？",
                                           "!": "！", ":": "：", ".": "。"]
        var chars = Array(text)
        for i in chars.indices where map.keys.contains(chars[i]) {
            guard i > 0, let scalar = chars[i - 1].unicodeScalars.first,
                  (0x2E80...0x9FFF).contains(Int(scalar.value)) ||
                  (0x3040...0x30FF).contains(Int(scalar.value)) else { continue }
            // "3.5" style decimals are safe: the guard requires a CJK
            // character immediately before the mark.
            chars[i] = map[chars[i]]!
        }
        let fullWidth: Set<Character> = ["，", "。", "！", "？", "；", "：", "、"]
        var result: [Character] = []
        for ch in chars {
            if fullWidth.contains(ch) {
                while result.last == " " { result.removeLast() }
            }
            result.append(ch)
        }
        return String(result)
    }

    /// Whisper language code from a BCP-47 tag or an AppleKeyboards entry
    /// ("en-US", "zh_Hans-Pinyin@sw=Pinyin10", "yue-CN") — nil for
    /// non-language entries ("emoji", keyboard bundle ids). Primary
    /// subtags are 2–3 letters; anything longer wasn't a language tag.
    static func whisperCode(fromLanguageTag tag: String) -> String? {
        let base = tag.split(separator: "@").first.map(String.init) ?? tag
        let letters = base.prefix { $0.isLetter }
        guard (2...3).contains(letters.count) else { return nil }
        return letters.lowercased()
    }

    /// Case- and punctuation-insensitive tail of a string, for confirming
    /// an insert against the host's document context. Short so it survives
    /// context truncation, folded so a host's own autocapitalization or
    /// spacing tweak doesn't read as a failure.
    static func foldTail(_ text: String) -> String {
        let folded = text.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
        return String(folded.suffix(12))
    }

    /// Did OUR text land in the host document?
    ///
    /// Comparing the context before and after the insert was WRONG: the
    /// host delivers documentContextBeforeInput asynchronously — routinely
    /// nil just after the keyboard appears, then filling in by itself — so
    /// "it changed" reported success for inserts that never happened. The
    /// only honest evidence is that the context now ENDS with what we
    /// inserted, and even that has to be qualified:
    ///
    /// - a field that ALREADY ended with our folded tail confirms itself
    ///   (dictate "yes" twice, the second one never lands, both read as
    ///   delivered), so there the only evidence left is that it grew;
    /// - a secure field withholds context but cannot hide that it now
    ///   holds text — trusting it unconditionally made every swallowed
    ///   insert into a password field read as a success.
    ///
    /// Returns the reason, not a Bool: the reason is recorded per dictation
    /// so a delivery that goes nowhere can be READ AFTERWARDS instead of
    /// guessed at. This decision has been wrong twice; the third fix ships
    /// with the evidence attached.
    static func insertVerdict(contextBefore: String?, contextAfter: String?,
                              insertedTail: String, isSecure: Bool,
                              hasText: Bool) -> InsertVerdict {
        if isSecure { return hasText ? .landedUnverifiable : .noField }
        // Nothing alphanumeric to look for (a lone "。"): the only reading
        // left is whether the document holds any text at all.
        guard !insertedTail.isEmpty else {
            return hasText ? .landedUnverifiable : .noField
        }
        // Nothing to read is not the same as reading something that isn't
        // ours. A terminal is the clear case: SwiftTerm backs the keyboard's
        // document context with an IME composition buffer it clears, so the
        // text can be on screen while the context reads empty — and hop-ios
        // forces hasText true, which used to turn "I can't tell" into the
        // confident "there's text and it isn't yours". Still not delivered,
        // so the pill is still offered; it just no longer blames the host
        // for something we simply could not check.
        guard let after = contextAfter, !after.isEmpty else {
            return hasText ? .unreadable : .noField
        }
        guard foldTail(after).hasSuffix(insertedTail) else { return .notAtCursor }
        if let before = contextBefore, foldTail(before).hasSuffix(insertedTail),
           after.count <= before.count {
            return .notAtCursor
        }
        return .landed
    }

    /// Joins dictated text onto what precedes the cursor: a leading space
    /// unless we're at a start, after whitespace, or after an opening
    /// bracket/quote.
    static func smartJoin(before: String?, insertion: String) -> String {
        let text = insertion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        guard let before, let last = before.unicodeScalars.last else { return text }
        if CharacterSet.whitespacesAndNewlines.contains(last) { return text }
        if "([{\"'“‘¿¡".unicodeScalars.contains(last) { return text }
        return " " + text
    }
}
