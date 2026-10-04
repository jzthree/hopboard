import CoreGraphics
import Foundation

/// What a key does once it commits. Keys commit on touch-UP, over whichever
/// key the finger is on at that moment — see KeyPlaneView.
enum KeyAction: Equatable {
    case text(String)
    case shift
    case backspace
    case layer(KeyLayer)
    case space
    case newline
    /// Back to the mic: this pad is a detour from dictation, not a home.
    case dictation
}

enum KeyLayer: String, Equatable {
    case letters, numbers, symbols
}

/// One key: what it does, how wide it is relative to a letter key, and what
/// a long press offers.
struct KeyCap: Equatable {
    var action: KeyAction
    /// Relative width. 1 = one key in a ten-key row.
    var width: CGFloat = 1
    var label: String?
    var symbolName: String?
    /// Long-press alternates. Empty means the key has no second meaning.
    var alternates: [String] = []
    /// Darker chrome, the way the system shades everything that isn't a
    /// letter, so the eye finds shift and delete without reading them.
    var isControl: Bool = false

    static func letter(_ character: String) -> KeyCap {
        KeyCap(action: .text(character), label: character,
               alternates: KeyLayout.alternates[character] ?? [])
    }

    static func control(_ action: KeyAction, label: String? = nil,
                        symbolName: String? = nil, width: CGFloat) -> KeyCap {
        KeyCap(action: action, width: width, label: label,
               symbolName: symbolName, isControl: true)
    }

    /// What this key shows right now. Only letters follow shift.
    func title(shifted: Bool) -> String? {
        guard case .text(let character) = action else { return label }
        return shifted ? character.uppercased() : character
    }

    /// Whether a press should raise a preview bubble. The system shows them
    /// for characters only — a bubble over `space` would be noise.
    var showsPreview: Bool {
        if case .text = action { return true }
        return false
    }
}

struct KeyRow: Equatable {
    var keys: [KeyCap]
    /// Relative width of the gutters, used by the home row's half-key inset.
    var leadingPad: CGFloat = 0
    var trailingPad: CGFloat = 0
}

enum KeyLayout {
    /// Long-press alternates, in the order the system offers them. Without
    /// these the pad cannot type a single accented word, which rules out
    /// most of the languages the dictation half already handles.
    static let alternates: [String: [String]] = [
        "a": ["à", "á", "â", "ä", "æ", "ã", "å", "ā"],
        "c": ["ç", "ć", "č"],
        "e": ["è", "é", "ê", "ë", "ē", "ė", "ę"],
        "i": ["î", "ï", "í", "ī", "į", "ì"],
        "l": ["ł"],
        "n": ["ñ", "ń"],
        "o": ["ô", "ö", "ò", "ó", "œ", "ø", "ō", "õ"],
        "s": ["ß", "ś", "š"],
        "u": ["û", "ü", "ù", "ú", "ū"],
        "y": ["ÿ"],
        "z": ["ž", "ź", "ż"],
        "-": ["–", "—", "•"],
        "/": ["\\"],
        "$": ["¢", "€", "£", "¥", "₩"],
        "&": ["§"],
        "\"": ["“", "”", "„", "»", "«"],
        "'": ["‘", "’", "`"],
        "?": ["¿"],
        "!": ["¡"],
        ".": ["…"],
        "%": ["‰"],
    ]

    static func rows(for layer: KeyLayer) -> [KeyRow] {
        switch layer {
        case .letters:
            return [
                KeyRow(keys: "qwertyuiop".map { KeyCap.letter(String($0)) }),
                KeyRow(keys: "asdfghjkl".map { KeyCap.letter(String($0)) },
                       leadingPad: 0.5, trailingPad: 0.5),
                KeyRow(keys: [.control(.shift, symbolName: "shift", width: 1.4)]
                       + "zxcvbnm".map { KeyCap.letter(String($0)) }
                       + [.control(.backspace, symbolName: "delete.left", width: 1.4)]),
                bottomRow(switchLabel: "123", switchTo: .numbers),
            ]
        case .numbers:
            return [
                KeyRow(keys: "1234567890".map { KeyCap.letter(String($0)) }),
                KeyRow(keys: ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""]
                    .map { KeyCap.letter($0) }),
                KeyRow(keys: [.control(.layer(.symbols), label: "#+=", width: 1.4)]
                       + [".", ",", "?", "!", "'"].map { KeyCap.letter($0) }
                       + [.control(.backspace, symbolName: "delete.left", width: 1.4)],
                       leadingPad: 0, trailingPad: 0),
                bottomRow(switchLabel: "ABC", switchTo: .letters),
            ]
        case .symbols:
            return [
                KeyRow(keys: ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="]
                    .map { KeyCap.letter($0) }),
                KeyRow(keys: ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"]
                    .map { KeyCap.letter($0) }),
                KeyRow(keys: [.control(.layer(.numbers), label: "123", width: 1.4)]
                       + [".", ",", "?", "!", "'"].map { KeyCap.letter($0) }
                       + [.control(.backspace, symbolName: "delete.left", width: 1.4)]),
                bottomRow(switchLabel: "ABC", switchTo: .letters),
            ]
        }
    }

    private static func bottomRow(switchLabel: String, switchTo: KeyLayer) -> KeyRow {
        KeyRow(keys: [
            .control(.layer(switchTo), label: switchLabel, width: 1.3),
            .control(.dictation, symbolName: "mic.fill", width: 1.3),
            KeyCap(action: .space, width: 4.4, label: "space"),
            .control(.newline, label: "return", width: 2.0),
        ])
    }
}

/// Where every key sits. Pure arithmetic, so the invariants that matter —
/// keys fill the width, nothing overlaps, nothing escapes the bounds — are
/// checkable without a device.
enum KeyGeometry {
    static func frames(rows: [KeyRow], in size: CGSize, topInset: CGFloat,
                       sideInset: CGFloat = 3, bottomInset: CGFloat = 5,
                       rowSpacing: CGFloat = 10,
                       keySpacing: CGFloat = 6) -> [[CGRect]] {
        guard !rows.isEmpty, size.width > 0,
              size.height > topInset + bottomInset else { return [] }
        // The bottom row never sits flush against the edge; the system
        // leaves a margin there and a keyboard without one reads as cropped.
        let usableHeight = size.height - topInset - bottomInset
        let rowHeight = (usableHeight - rowSpacing * CGFloat(rows.count - 1))
            / CGFloat(rows.count)
        guard rowHeight > 0 else { return [] }

        return rows.enumerated().map { rowIndex, row in
            let gaps = keySpacing * CGFloat(max(row.keys.count - 1, 0))
            let available = size.width - sideInset * 2 - gaps
            let units = row.keys.reduce(row.leadingPad + row.trailingPad) { $0 + $1.width }
            guard units > 0, available > 0 else { return [] }
            let unit = available / units
            var x = sideInset + row.leadingPad * unit
            let y = topInset + CGFloat(rowIndex) * (rowHeight + rowSpacing)
            return row.keys.map { key in
                let width = key.width * unit
                defer { x += width + keySpacing }
                return CGRect(x: x, y: y, width: width, height: rowHeight)
            }
        }
    }
}
