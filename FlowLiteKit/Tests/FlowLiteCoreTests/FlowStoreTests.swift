import Foundation
import Testing
@testable import FlowLiteCore

@Suite struct FlowStoreTests {
    func record(_ text: String, at seconds: TimeInterval, app: String = "Notes") -> DictationRecord {
        DictationRecord(createdAt: Date(timeIntervalSince1970: seconds), mode: "dictation",
                        appName: app, bundleID: "com.apple.Notes", rawText: text, finalText: text.capitalized)
    }

    @Test func savesAndListsNewestFirst() throws {
        let store = try FlowStore.inMemory()
        let saved = try store.save(record("first", at: 1_700_000_000))
        #expect(saved.id != nil)
        try store.save(record("second", at: 1_700_000_100))
        #expect(try store.recent().map(\.rawText) == ["second", "first"])
    }

    @Test func searchMatchesRawFinalAndApp() throws {
        let store = try FlowStore.inMemory()
        try store.save(record("deploy the app", at: 1, app: "Slack"))
        try store.save(record("buy milk", at: 2, app: "Notes"))
        #expect(try store.recent(search: "deploy").map(\.rawText) == ["deploy the app"])
        #expect(try store.recent(search: "slack").map(\.rawText) == ["deploy the app"])
        #expect(try store.recent(search: "Milk").map(\.rawText) == ["buy milk"])
    }

    @Test func searchTreatsWildcardsLiterally() throws {
        let store = try FlowStore.inMemory()
        try store.save(record("costs 1000 dollars", at: 1))
        try store.save(record("100% done", at: 2))
        try store.save(record("snake_case name", at: 3))
        try store.save(record("snakeXcase name", at: 4))
        try store.save(record("path a\\b", at: 5))
        #expect(try store.recent(search: "100%").map(\.rawText) == ["100% done"])
        #expect(try store.recent(search: "snake_case").map(\.rawText) == ["snake_case name"])
        #expect(try store.recent(search: "a\\b").map(\.rawText) == ["path a\\b"])
    }

    @Test func deleteAndDeleteAll() throws {
        let store = try FlowStore.inMemory()
        let a = try store.save(record("a", at: 1))
        try store.save(record("b", at: 2))
        try store.delete(id: a.id!)
        #expect(try store.recent().map(\.rawText) == ["b"])
        try store.deleteAllHistory()
        #expect(try store.recent().isEmpty)
    }

    @Test func vocabularyIsTrimmedAndDeduplicated() throws {
        let store = try FlowStore.inMemory()
        try store.setVocabulary(["  Vercel ", "", "vercel", "FlowLite", "\n"])
        #expect(try store.vocabulary() == ["Vercel", "FlowLite"])
        try store.setVocabulary(["Claude"])
        #expect(try store.vocabulary() == ["Claude"])
    }

    @Test func replacementRulesRoundTrip() throws {
        let store = try FlowStore.inMemory()
        try store.setReplacementRules([
            ReplacementRule(pattern: "my email", replacement: "me@example.com"),
            ReplacementRule(pattern: "", replacement: "dropped"),
            ReplacementRule(pattern: "API", replacement: "api", caseSensitive: true, wholeWord: false),
        ])
        let rules = try store.replacementRules()
        #expect(rules.count == 2)
        #expect(rules.allSatisfy { $0.id != nil })
        #expect(rules.map(\.pattern) == ["my email", "API"])
        #expect(rules[1].caseSensitive && !rules[1].wholeWord)
    }
}
