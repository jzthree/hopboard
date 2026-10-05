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

    /// The word being typed right now: the trailing run of letters, with
    /// apostrophes, so "don't" is one word and not two thirds of one.
    static func currentWord(in tail: String) -> String {
        String(tail.reversed()
            .prefix { $0.isLetter || $0 == "'" || $0 == "\u{2019}" }
            .reversed())
    }

    static func replacingCurrentWord(in tail: String, with word: String) -> String {
        String(tail.dropLast(currentWord(in: tail).count)) + word
    }

    /// Case-insensitive Damerau-Levenshtein: insert, delete, substitute,
    /// and TRANSPOSE, all costing one.
    ///
    /// Plain Levenshtein charges two for a transposition, which rules out
    /// the single most common typo there is — "teh" sits two edits from
    /// "the" and would be refused as a wild guess. Adjacent swaps are what
    /// fingers actually do, so they have to count as one slip.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a.lowercased()), y = Array(b.lowercased())
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var d = [[Int]](repeating: [Int](repeating: 0, count: y.count + 1),
                        count: x.count + 1)
        for i in 0...x.count { d[i][0] = i }
        for j in 0...y.count { d[0][j] = j }
        for i in 1...x.count {
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + cost)
                }
            }
        }
        return d[x.count][y.count]
    }

    /// Whether typing this ends the word — the moment a correction is
    /// either applied or lost.
    static func endsWord(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        return !(first.isLetter || first == "'" || first == "\u{2019}")
    }
}
