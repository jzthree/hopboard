import Foundation

/// Your names and jargon, spelled the way you want them — applied to a
/// finished transcript by matching what the model ACTUALLY produced.
///
/// A replacement list would be the wrong shape: nobody can predict that
/// "HopBoard" comes back as "hop board", "hopboard", or "hop bored". So
/// the user supplies only correct terms, and matching is done on sound:
/// letters compared after stripping case and punctuation with a fuzzy
/// tolerance, Han characters compared by PINYIN — which is exactly how
/// Chinese recognition fails (张伟 → 章伟, same sound, different glyph).
enum FlowVocabulary {
    static let defaultsKey = "flow.vocabulary"

    /// Readable from any isolation — the engines run off the main actor.
    static func current() -> [String] {
        terms(from: UserDefaults.standard.string(forKey: defaultsKey) ?? "")
    }

    /// One term per line (commas also accepted for quick entry).
    static func terms(from raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
    }

    static func apply(_ text: String, terms: [String]) -> String {
        guard !terms.isEmpty, !text.isEmpty else { return text }
        var result = text
        // Longest first: a two-word term should win over its own first word.
        for term in terms.sorted(by: { $0.count > $1.count }) {
            result = isCJK(term) ? applyCJK(result, term: term)
                                 : applyLatin(result, term: term)
        }
        return result
    }

    static func isCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3400...0x9FFF).contains(Int($0.value)) }
    }

    // MARK: latin

    /// Letters and digits only, lowercased — "Hop-Board's" and "hop board"
    /// both reduce to "hopboards"/"hopboard" for comparison.
    private static func fold(_ text: String) -> String {
        text.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    private static func applyLatin(_ text: String, term: String) -> String {
        let target = fold(term)
        guard target.count >= 3 else { return text }
        let tokens = wordTokens(in: text)
        guard !tokens.isEmpty else { return text }
        // The model may split one written term across several spoken words,
        // so test spans a little longer than the term itself.
        let maxSpan = min(4, term.split(separator: " ").count + 1)

        var replacements: [(Range<String.Index>, String)] = []
        var index = 0
        while index < tokens.count {
            var matched = false
            for span in stride(from: min(maxSpan, tokens.count - index), through: 1, by: -1) {
                let slice = tokens[index..<(index + span)]
                let candidate = fold(slice.map(\.text).joined())
                guard !candidate.isEmpty, similar(candidate, target) else { continue }
                let range = slice.first!.range.lowerBound..<slice.last!.range.upperBound
                if String(text[range]) != term {
                    replacements.append((range, term))
                }
                index += span
                matched = true
                break
            }
            if !matched { index += 1 }
        }
        return applying(replacements, to: text)
    }

    /// Same spelling, or close enough that only a mishearing explains it.
    /// Guards against wild rewrites: the first letter must survive and the
    /// lengths must be comparable.
    private static func similar(_ candidate: String, _ target: String) -> Bool {
        if candidate == target { return true }
        guard candidate.count >= 4, target.count >= 4,
              abs(candidate.count - target.count) <= 3,
              candidate.first == target.first else { return false }
        let distance = editDistance(Array(candidate), Array(target))
        let ratio = 1 - Double(distance) / Double(max(candidate.count, target.count))
        if ratio >= 0.82 { return true }
        // Spelling distance alone misses the most common failure: a
        // homophone. "hop bored" is two letters from "hopboard" but sounds
        // identical, so also compare consonant skeletons.
        let code = consonantCode(candidate)
        return code.count >= 3 && code == consonantCode(target)
    }

    /// Soundex-style consonant skeleton, untruncated: vowels dropped,
    /// same-sounding consonants share a digit, runs collapsed.
    /// "hopboard" and "hopbored" both reduce to "h163".
    static func consonantCode(_ text: String) -> String {
        let groups: [Character: Character] = [
            "b": "1", "f": "1", "p": "1", "v": "1",
            "c": "2", "g": "2", "j": "2", "k": "2", "q": "2", "s": "2", "x": "2", "z": "2",
            "d": "3", "t": "3",
            "l": "4",
            "m": "5", "n": "5",
            "r": "6",
        ]
        var code = ""
        var previous: Character?
        for (index, character) in text.lowercased().enumerated() {
            guard let digit = groups[character] else {
                // Vowels (and h/w/y) don't just vanish: they break runs, so
                // "aa" in "kubernetes" can't merge unrelated consonants.
                if index == 0 { code.append(character) }
                previous = nil
                continue
            }
            if index == 0 {
                code.append(character)
            } else if digit != previous {
                code.append(digit)
            }
            previous = digit
        }
        return code
    }

    // MARK: chinese

    /// Tone-stripped pinyin, spaces removed: 张伟 → "zhangwei".
    static func pinyin(_ text: String) -> String {
        let mutable = NSMutableString(string: text) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        return (mutable as String).lowercased()
            .filter { !$0.isWhitespace }
    }

    private static func applyCJK(_ text: String, term: String) -> String {
        let target = pinyin(term)
        guard !target.isEmpty else { return text }
        let characters = Array(text)
        let indices = Array(text.indices)
        let length = term.count
        guard characters.count >= length else { return text }

        var replacements: [(Range<String.Index>, String)] = []
        var start = 0
        while start + length <= characters.count {
            let window = String(characters[start..<(start + length)])
            // Only slide across Han runs — Latin spans are the other path's
            // business, and mixing the two produces nonsense matches.
            guard isCJK(window) else { start += 1; continue }
            if window != term, pinyin(window) == target {
                let range = indices[start]..<indices[start + length]
                replacements.append((range, term))
                start += length
            } else {
                start += 1
            }
        }
        return applying(replacements, to: text)
    }

    // MARK: helpers

    private static func applying(_ replacements: [(Range<String.Index>, String)],
                                 to text: String) -> String {
        guard !replacements.isEmpty else { return text }
        var result = text
        // Back to front so earlier ranges stay valid.
        for (range, replacement) in replacements.reversed() {
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    private struct Token {
        let range: Range<String.Index>
        let text: String
    }

    private static func wordTokens(in text: String) -> [Token] {
        var tokens: [Token] = []
        var start: String.Index?
        for index in text.indices {
            let isWord = text[index].isLetter || text[index].isNumber
            if isWord, start == nil { start = index }
            if !isWord, let begin = start {
                tokens.append(Token(range: begin..<index, text: String(text[begin..<index])))
                start = nil
            }
        }
        if let begin = start {
            tokens.append(Token(range: begin..<text.endIndex,
                                text: String(text[begin..<text.endIndex])))
        }
        return tokens
    }

    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1]
                    ? previous[j - 1]
                    : min(previous[j - 1], previous[j], current[j - 1]) + 1
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
