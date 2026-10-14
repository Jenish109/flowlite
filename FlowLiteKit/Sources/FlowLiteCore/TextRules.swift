import Foundation

public struct ReplacementRule: Codable, Equatable, Sendable {
    public var id: Int64?
    public var pattern: String
    public var replacement: String
    public var caseSensitive: Bool
    public var wholeWord: Bool

    public init(id: Int64? = nil, pattern: String, replacement: String,
                caseSensitive: Bool = false, wholeWord: Bool = true) {
        self.id = id
        self.pattern = pattern
        self.replacement = replacement
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
    }
}

/// Deterministic find-and-replace applied after cleanup. Patterns are literal, not regexes.
public enum ReplacementEngine {
    public static func apply(_ rules: [ReplacementRule], to text: String) -> String {
        rules.reduce(text) { apply($1, to: $0) }
    }

    static func apply(_ rule: ReplacementRule, to text: String) -> String {
        guard !rule.pattern.isEmpty else { return text }
        guard rule.wholeWord else {
            return text.replacingOccurrences(of: rule.pattern, with: rule.replacement,
                                             options: rule.caseSensitive ? [] : [.caseInsensitive])
        }
        let wordChar = "[\\p{L}\\p{M}\\p{N}_]"
        let pattern = "(?<!\(wordChar))" + NSRegularExpression.escapedPattern(for: rule.pattern) + "(?!\(wordChar))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: rule.caseSensitive ? [] : [.caseInsensitive]) else {
            return text
        }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: rule.replacement))
    }
}

/// Decides whether inserted text needs a leading space, given the text before the cursor.
public enum Spacing {
    static let noSpaceBefore: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "…", "%"]
    static let noSpaceAfter: Set<Character> = ["(", "[", "{", "“", "‘", "/"]
    /// Straight quotes are ambiguous: they only suppress the space when they open (start of text or after whitespace).
    static let straightQuotes: Set<Character> = ["\"", "'"]

    public static func join(before: String, insertion: String) -> String {
        guard let first = insertion.first, let last = before.last else { return insertion }
        if last.isWhitespace || first.isWhitespace { return insertion }
        if noSpaceBefore.contains(first) || noSpaceAfter.contains(last) { return insertion }
        if straightQuotes.contains(last), before.dropLast().last?.isWhitespace ?? true { return insertion }
        return " " + insertion
    }
}
