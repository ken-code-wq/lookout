import Foundation
import SQLite3

/// Minimal read-only SQLite access for agents that keep history in a database.
/// Opens with `mode=ro` so a live writer's WAL is still visible, and fails fast when busy.
final class AgentSQLiteDatabase {
    private var handle: OpaquePointer?

    init?(path: String) {
        let uri = URL(fileURLWithPath: path).absoluteString + "?mode=ro"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(uri, &handle, flags, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        sqlite3_busy_timeout(handle, 150)
    }

    deinit {
        sqlite3_close(handle)
    }

    func tables() -> Set<String> {
        var names: Set<String> = []
        query("SELECT name FROM sqlite_master WHERE type = 'table'") { row in
            if let name = row.text(0) { names.insert(name) }
        }
        return names
    }

    func columns(of table: String) -> Set<String> {
        var names: Set<String> = []
        query("PRAGMA table_info(\(table))") { row in
            if let name = row.text(1) { names.insert(name) }
        }
        return names
    }

    enum Binding {
        case int(Int64)
        case text(String)
    }

    /// Runs `sql`, calling `row` per result. Returns false when the statement failed.
    @discardableResult
    func query(_ sql: String, _ bindings: [Binding] = [], row: (Row) -> Void) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, binding) in bindings.enumerated() {
            switch binding {
            case .int(let value): sqlite3_bind_int64(statement, Int32(index + 1), value)
            case .text(let value): sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
            }
        }
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_ROW {
                row(Row(statement: statement))
            } else {
                return status == SQLITE_DONE
            }
        }
    }

    struct Row {
        fileprivate let statement: OpaquePointer

        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }

        func int64(_ column: Int32) -> Int64? {
            isNull(column) ? nil : sqlite3_column_int64(statement, column)
        }

        func double(_ column: Int32) -> Double? {
            isNull(column) ? nil : sqlite3_column_double(statement, column)
        }

        func text(_ column: Int32) -> String? {
            guard let pointer = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: pointer)
        }

        func blob(_ column: Int32) -> Data? {
            guard let pointer = sqlite3_column_blob(statement, column) else { return nil }
            return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, column)))
        }
    }
}
