import Foundation

/// The small decisions a keyboard makes between the key and the document.
/// All of them read only the text before the cursor, so all of them are
/// pure — which matters here because the pad keeps its OWN running tail
/// rather than asking the host. documentContextBeforeInput is delivered
/// asynchronously (the same fact that made insert verification wrong twice),
/// and a shift key that waits for the host to answer flickers a beat after
/// every period.
enum TypingEngine {
    /// Sentence terminators worth capitalising after, Latin and CJK.
    private static let terminators: Set<Character> = [".", "!", "?", "。", "！", "？"]

    /// Should the next letter be a capital?
    static func shouldCapitalize(after text: String) -> Bool {
        guard let last = text.last else { return true }  // empty field
        if last.isNewline { return true }
        guard last == " " else { return false }
        // Walk back over the spaces; a terminator behind them starts a
        // sentence. "Hi.  " capitalises, "Hi " does not.
        let beforeSpaces = text.reversed().drop(while: { $0 == " " })
        guard let previous = beforeSpaces.first else { return true }
        return terminators.contains(previous)
    }

    /// Does a space typed here mean ". " instead? The system's double-space
    /// shortcut: exactly one space, sitting on a word, not already a
    /// sentence end.
    static func doubleSpacePeriod(after text: String) -> Bool {
        guard text.hasSuffix(" ") else { return false }
        let body = text.dropLast()
        guard let previous = body.last else { return false }
        if previous == " " { return false }
        if terminators.contains(previous) { return false }
        return previous.isLetter || previous.isNumber
    }

    /// The running tail the pad keeps, capped — only the end is ever read,
    /// and an unbounded string would grow for as long as the pad is open.
    static let tailLimit = 48

    static func appending(_ text: String, to tail: String) -> String {
        String((tail + text).suffix(tailLimit))
    }

    static func deletingLast(from tail: String) -> String {
        String(tail.dropLast())
    }
}
