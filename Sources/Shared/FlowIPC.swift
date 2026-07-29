import Foundation
import Security

// The contract between the FlowBoard app and its keyboard extension.
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
    static let keychainAccessGroup = "5AD7QB9795.io.zhoulab.flowboard.ipc"
    static let keychainService = "io.zhoulab.flowboard.ipc"
    static let startSessionURL = URL(string: "flowboard://session/start")!

    // Darwin notification names are a global namespace — prefix everything.
    static let commandNotification = "io.zhoulab.flowboard.command"
    static let stateNotification = "io.zhoulab.flowboard.state"

    // A session whose heartbeat is older than this is dead (app was killed
    // or suspended); the keyboard falls back to "Start Flow Session".
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
        case startSegment, stopSegment, cancelSegment, endSession
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

/// Minimal key→Data storage the two processes share.
protocol FlowBackend {
    func data(forKey key: String) -> Data?
    func set(_ data: Data, forKey key: String)
    func removeValue(forKey key: String)
}

/// Keychain-backed shared storage. Items live in the team access group with
/// AfterFirstUnlock so the backgrounded app can keep using them.
final class KeychainBackend: FlowBackend {
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
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    func set(_ data: Data, forKey key: String) {
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(for: key) as CFDictionary, update as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var add = baseQuery(for: key)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    func removeValue(forKey key: String) {
        SecItemDelete(baseQuery(for: key) as CFDictionary)
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
        static let micLevel = "flow.micLevel"
        static let keyboardSeen = "flow.keyboardSeen"
        static let modelStatus = "flow.modelStatus"
        static let probe = "flow.probe"
        static let tone = "flow.tone"
    }

    init(backend: FlowBackend = KeychainBackend()) {
        self.backend = backend
    }

    var isAvailable: Bool {
        let nonce = UUID().uuidString.data(using: .utf8)!
        backend.set(nonce, forKey: Key.probe)
        return backend.data(forKey: Key.probe) == nonce
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

    var sessionAlive: Bool {
        state != .idle && Date().timeIntervalSince(heartbeat) < Flow.heartbeatTimeout
    }

    // MARK: commands (keyboard writes, app reads)

    func send(_ action: FlowCommand.Action) {
        let command = FlowCommand(id: UUID(), action: action, sentAt: Date().timeIntervalSince1970)
        if let data = try? encoder.encode(command) {
            backend.set(data, forKey: Key.command)
        }
    }

    /// Reads the pending command exactly once.
    func takeCommand() -> FlowCommand? {
        guard let data = backend.data(forKey: Key.command),
              let command = try? decoder.decode(FlowCommand.self, from: data) else { return nil }
        backend.removeValue(forKey: Key.command)
        return command
    }

    // MARK: results (app writes, keyboard consumes)

    private(set) var results: [FlowResult] {
        get {
            guard let data = backend.data(forKey: Key.results),
                  let results = try? decoder.decode([FlowResult].self, from: data) else { return [] }
            return results
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
    /// convert to full-width when it follows a CJK character.
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
        return String(chars)
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
