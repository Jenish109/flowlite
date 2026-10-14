import Testing
@testable import FlowLiteCore

@Suite struct ReplacementEngineTests {
    @Test func wholeWordCaseInsensitive() {
        let rule = ReplacementRule(pattern: "flow lite", replacement: "FlowLite")
        #expect(ReplacementEngine.apply([rule], to: "I use Flow Lite daily") == "I use FlowLite daily")
        #expect(ReplacementEngine.apply([rule], to: "flow liter") == "flow liter")
    }

    @Test func caseSensitiveRule() {
        let rule = ReplacementRule(pattern: "API", replacement: "api", caseSensitive: true)
        #expect(ReplacementEngine.apply([rule], to: "API and Api") == "api and Api")
    }

    @Test func substringRule() {
        let rule = ReplacementRule(pattern: "teh", replacement: "the", wholeWord: false)
        #expect(ReplacementEngine.apply([rule], to: "tehre") == "there")
    }

    @Test func replacementIsLiteral() {
        let rule = ReplacementRule(pattern: "price", replacement: "$5 \\o/")
        #expect(ReplacementEngine.apply([rule], to: "the price") == "the $5 \\o/")
    }

    @Test func rulesApplyInOrder() {
        let rules = [ReplacementRule(pattern: "a", replacement: "b"), ReplacementRule(pattern: "b", replacement: "c")]
        #expect(ReplacementEngine.apply(rules, to: "a") == "c")
    }

    @Test func combiningMarksCountAsWordCharacters() {
        // "e" + U+0301 (combining acute): the rule for "cafe" must not match inside "café" written decomposed.
        let rule = ReplacementRule(pattern: "cafe", replacement: "X")
        #expect(ReplacementEngine.apply([rule], to: "cafe\u{301}") == "cafe\u{301}")
        let mark = ReplacementRule(pattern: "a", replacement: "X")
        #expect(ReplacementEngine.apply([mark], to: "\u{301}a") == "\u{301}a")
    }

    @Test func emptyPatternIsIgnored() {
        #expect(ReplacementEngine.apply([ReplacementRule(pattern: "", replacement: "x")], to: "abc") == "abc")
    }
}

@Suite struct SpacingTests {
    @Test func noSpaceAtStartOfField() { #expect(Spacing.join(before: "", insertion: "Hello") == "Hello") }
    @Test func spaceAfterWord() { #expect(Spacing.join(before: "Hello", insertion: "world") == " world") }
    @Test func noDoubleSpace() { #expect(Spacing.join(before: "Hello ", insertion: "world") == "world") }
    @Test func noSpaceBeforePunctuation() { #expect(Spacing.join(before: "Hello", insertion: ", world") == ", world") }
    @Test func noSpaceAfterOpeningBracket() { #expect(Spacing.join(before: "(", insertion: "aside") == "aside") }
    @Test func noSpaceAfterNewline() { #expect(Spacing.join(before: "Hi\n", insertion: "there") == "there") }
    @Test func spaceAfterClosingStraightQuote() {
        #expect(Spacing.join(before: "She said \"yes\"", insertion: "and left") == " and left")
    }
    @Test func spaceAfterApostrophe() { #expect(Spacing.join(before: "students'", insertion: "books") == " books") }
    @Test func noSpaceAfterOpeningStraightQuote() {
        #expect(Spacing.join(before: "He said \"", insertion: "hi") == "hi")
        #expect(Spacing.join(before: "'", insertion: "hi") == "hi")
    }
    @Test func noSpaceAfterCurlyOpeningQuote() { #expect(Spacing.join(before: "He said“", insertion: "hi") == "hi") }
    @Test func emptyInsertion() { #expect(Spacing.join(before: "Hi", insertion: "") == "") }
}
