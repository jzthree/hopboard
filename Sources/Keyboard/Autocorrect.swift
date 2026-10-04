import UIKit

/// Autocorrect on UITextChecker — the only spell-checking a third-party
/// keyboard gets. Apple's QuickType is not withheld behind an entitlement,
/// it is simply not exposed, so this is dictionary-based and per-word where
/// QuickType is contextual and learns from everything you write. It fixes
/// typos. It will not finish your sentences, and pretending otherwise in
/// the UI would be the wrong kind of ambitious.
final class Autocorrect {
    struct Suggestion: Equatable {
        let text: String
        /// Exactly what was typed. Always offered, so a correction can be
        /// refused — and refusing it teaches.
        let isLiteral: Bool
        /// What a word break applies if nothing is tapped.
        let isDefault: Bool
    }

    private let checker = UITextChecker()
    private let keptKey: String
    private var kept: Set<String>
    let language: String

    init(language: String = Autocorrect.preferredLanguage(),
         keptKey: String = "kb.keptWords") {
        self.language = language
        self.keptKey = keptKey
        kept = Set(UserDefaults.standard.stringArray(forKey: keptKey) ?? [])
    }

    /// The pad is a Latin QWERTY, so the checker should speak whatever
    /// Latin language the phone is set to, falling back to English rather
    /// than to whatever happens to be first in the list.
    static func preferredLanguage() -> String {
        let available = Set(UITextChecker.availableLanguages)
        let identifier = Locale.current.identifier.replacingOccurrences(of: "-", with: "_")
        if available.contains(identifier) { return identifier }
        if let code = Locale.current.language.languageCode?.identifier,
           let match = available.sorted().first(where: { $0.hasPrefix(code) }) {
            return match
        }
        return available.contains("en_US") ? "en_US" : (available.sorted().first ?? "en_US")
    }

    // MARK: the user's own words

    /// A word the user insisted on. Correcting someone's surname twice is
    /// how a keyboard loses an argument it should not have started.
    func keep(_ word: String) {
        let folded = word.lowercased()
        guard !folded.isEmpty, !kept.contains(folded) else { return }
        kept.insert(folded)
        UserDefaults.standard.set(Array(kept), forKey: keptKey)
    }

    func isKept(_ word: String) -> Bool { kept.contains(word.lowercased()) }

    // MARK: judgement

    /// Only ordinary words are candidates. Anything with a digit, a symbol
    /// or an uppercase letter mid-word is far more likely to be a password,
    /// a path or an identifier than a typo.
    func isCorrectable(_ word: String) -> Bool {
        guard word.count >= 3, !isKept(word) else { return false }
        guard word.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "\u{2019}" }) else { return false }
        return word.dropFirst().allSatisfy { !$0.isUppercase }
    }

    func isMisspelled(_ word: String) -> Bool {
        let text = word as NSString
        let found = checker.rangeOfMisspelledWord(
            in: word, range: NSRange(location: 0, length: text.length),
            startingAt: 0, wrap: false, language: language)
        return found.location != NSNotFound
    }

    private func guesses(for word: String) -> [String] {
        let text = word as NSString
        let all = checker.guesses(forWordRange: NSRange(location: 0, length: text.length),
                                  in: word, language: language) ?? []
        // Case follows what was typed: correcting "teh" inside a sentence
        // should not hand back "Teh".
        let capitalised = word.first?.isUppercase ?? false
        return all.map { capitalised ? $0.capitalized : $0 }
    }

    /// What a word break should apply, or nil to leave the word alone.
    func correction(for word: String) -> String? {
        guard isCorrectable(word), isMisspelled(word) else { return nil }
        guard let best = guesses(for: word).first else { return nil }
        // A "correction" that only adds or drops an accent is usually
        // right; one that rewrites the word wholesale usually is not.
        return best.lowercased() == word.lowercased() ? nil : best
    }

    /// The bar's three slots: what you typed, what it will become, and one
    /// more way out. Empty while there is nothing useful to say.
    func suggestions(for word: String) -> [Suggestion] {
        guard !word.isEmpty, isCorrectable(word) else { return [] }
        let misspelled = isMisspelled(word)
        guard misspelled else { return [] }
        let options = guesses(for: word).filter { $0.lowercased() != word.lowercased() }
        guard !options.isEmpty else { return [] }
        var result = [Suggestion(text: word, isLiteral: true, isDefault: false)]
        for (index, option) in options.prefix(2).enumerated() {
            result.append(Suggestion(text: option, isLiteral: false, isDefault: index == 0))
        }
        return result
    }
}
