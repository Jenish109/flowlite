import Foundation
import GRDB

public struct DictationRecord: Codable, Equatable, Sendable {
    public var id: Int64?
    public var createdAt: Date
    public var mode: String            // "dictation" | "command"
    public var appName: String
    public var bundleID: String
    public var rawText: String
    public var finalText: String
    public var cleanupFailed: Bool
    public var insertMethod: String    // InsertMethod.rawValue
    public var audioMs: Int
    public var transcribeMs: Int
    public var cleanMs: Int
    public var error: String?

    public init(id: Int64? = nil, createdAt: Date = Date(), mode: String = "dictation",
                appName: String = "", bundleID: String = "", rawText: String = "", finalText: String = "",
                cleanupFailed: Bool = false, insertMethod: String = "none",
                audioMs: Int = 0, transcribeMs: Int = 0, cleanMs: Int = 0, error: String? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.mode = mode
        self.appName = appName
        self.bundleID = bundleID
        self.rawText = rawText
        self.finalText = finalText
        self.cleanupFailed = cleanupFailed
        self.insertMethod = insertMethod
        self.audioMs = audioMs
        self.transcribeMs = transcribeMs
        self.cleanMs = cleanMs
        self.error = error
    }
}

extension DictationRecord: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "dictation"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension ReplacementRule: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "replacement"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// SQLite storage for dictation history, vocabulary and replacement rules.
public final class FlowStore: Sendable {
    private let db: DatabaseQueue

    public convenience init(path: String) throws {
        try self.init(queue: DatabaseQueue(path: path))
    }

    public static func inMemory() throws -> FlowStore {
        try FlowStore(queue: DatabaseQueue())
    }

    private init(queue: DatabaseQueue) throws {
        db = queue
        try Self.migrator.migrate(db)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "dictation") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("createdAt", .datetime).notNull().indexed()
                t.column("mode", .text).notNull()
                t.column("appName", .text).notNull()
                t.column("bundleID", .text).notNull()
                t.column("rawText", .text).notNull()
                t.column("finalText", .text).notNull()
                t.column("cleanupFailed", .boolean).notNull()
                t.column("insertMethod", .text).notNull()
                t.column("audioMs", .integer).notNull()
                t.column("transcribeMs", .integer).notNull()
                t.column("cleanMs", .integer).notNull()
                t.column("error", .text)
            }
            try db.create(table: "vocabulary") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("word", .text).notNull().unique()
            }
            try db.create(table: "replacement") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("pattern", .text).notNull()
                t.column("replacement", .text).notNull()
                t.column("caseSensitive", .boolean).notNull()
                t.column("wholeWord", .boolean).notNull()
            }
        }
        return migrator
    }

    // MARK: History

    @discardableResult
    public func save(_ record: DictationRecord) throws -> DictationRecord {
        try db.write { db in
            var copy = record
            try copy.insert(db)
            return copy
        }
    }

    public func recent(search: String = "", limit: Int = 200) throws -> [DictationRecord] {
        try db.read { db in
            var request = DictationRecord.all()
            let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty {
                let escaped = query.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                let like = "%\(escaped)%"
                request = request.filter(Column("rawText").like(like, escape: "\\")
                                         || Column("finalText").like(like, escape: "\\")
                                         || Column("appName").like(like, escape: "\\"))
            }
            return try request.order(Column("createdAt").desc).limit(limit).fetchAll(db)
        }
    }

    public func delete(id: Int64) throws {
        _ = try db.write { try DictationRecord.deleteOne($0, key: id) }
    }

    public func deleteAllHistory() throws {
        _ = try db.write { try DictationRecord.deleteAll($0) }
    }

    // MARK: Vocabulary

    public func vocabulary() throws -> [String] {
        try db.read { try String.fetchAll($0, sql: "SELECT word FROM vocabulary ORDER BY id") }
    }

    public func setVocabulary(_ words: [String]) throws {
        let cleaned = Self.dedupe(words)
        try db.write { db in
            try db.execute(sql: "DELETE FROM vocabulary")
            for word in cleaned {
                try db.execute(sql: "INSERT INTO vocabulary (word) VALUES (?)", arguments: [word])
            }
        }
    }

    static func dedupe(_ words: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for word in words.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        where !word.isEmpty && seen.insert(word.lowercased()).inserted {
            out.append(word)
        }
        return out
    }

    // MARK: Replacement rules

    public func replacementRules() throws -> [ReplacementRule] {
        try db.read { try ReplacementRule.order(Column("id")).fetchAll($0) }
    }

    public func setReplacementRules(_ rules: [ReplacementRule]) throws {
        try db.write { db in
            try ReplacementRule.deleteAll(db)
            for rule in rules where !rule.pattern.isEmpty {
                var copy = rule
                copy.id = nil
                try copy.insert(db)
            }
        }
    }
}
