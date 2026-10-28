import Foundation
import Darwin
import SQLite3

struct PlaintextSave: Codable, Sendable {
    var id = UUID().uuidString
    var path: String
    var contents: String
    var revision: String
    var version: Int
}

struct PlaintextDraft: Codable, Sendable {
    var id = UUID().uuidString
    var target = "host"
    var path = ""
    var contents = ""
    var revision = "missing"
    var version = 0
    var dirty = false
    var conflict = false
    var updated = Date()
    var pending: PlaintextSave?
}

struct PlaintextReply: Sendable {
    var path: String
    var contents: String = ""
    var revision: String
    var dirty = false
    var conflict = false
}

enum PlaintextDocumentError: Error, LocalizedError {
    case message(String)
    case connection
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .connection: return "Waiting for connection"
        }
    }
}

enum PlaintextEnvironment {
    static func encode(_ operation: UInt32, target: String, path: String, destination: String = "", revision: String = "", contents: String = "") throws -> Data {
        let fields = [target, "", path, destination, revision, contents]
        guard !fields.contains(where: { $0.contains("\0") }), contents.utf8.count <= 4 * 1024 * 1024 else {
            throw PlaintextDocumentError.message("Document exceeds the size limit or contains a NUL character")
        }
        let strings = fields.map { Data($0.utf8) }
        let size = 72 + strings.reduce(0) { $0 + $1.count }
        guard size <= 16 * 1024 * 1024 else { throw PlaintextDocumentError.message("Request exceeds size limit") }
        var result = Data(repeating: 0, count: 72)
        func put(_ value: UInt32, at offset: Int) {
            for byte in 0..<4 { result[offset + byte] = UInt8(truncatingIfNeeded: value >> (8 * byte)) }
        }
        put(0x51434c50, at: 0); put(1, at: 4); put(UInt32(size), at: 8); put(operation, at: 12)
        for (index, string) in strings.enumerated() {
            put(UInt32(result.count), at: 24 + index * 8)
            put(UInt32(string.count), at: 28 + index * 8)
            result.append(string)
        }
        return result
    }

    static func decode(_ bytes: Data, operation: UInt32) throws -> PlaintextReply {
        let invalid = PlaintextDocumentError.message("Invalid environment response")
        func u32(_ data: Data, _ offset: Int) throws -> UInt32 {
            guard offset >= 0, offset <= data.count - 4 else { throw invalid }
            return (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << (8 * $1) }
        }
        func field(_ data: Data, _ offset: Int, minimum: Int) throws -> Data {
            let start = Int(try u32(data, offset)), count = Int(try u32(data, offset + 4))
            guard start >= minimum, start <= data.count, count <= data.count - start else { throw invalid }
            return data.subdata(in: start..<(start + count))
        }
        func string(_ data: Data) throws -> String {
            guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw invalid }
            return text
        }
        guard bytes.count >= 48, try u32(bytes, 0) == 0x52434c50, try u32(bytes, 4) == 1,
              try u32(bytes, 8) == bytes.count, try u32(bytes, 12) <= 1,
              try u32(bytes, 40) <= 3, try u32(bytes, 44) == 0 else { throw invalid }
        if try u32(bytes, 12) == 1 { throw PlaintextDocumentError.message(try string(field(bytes, 32, minimum: 48))) }
        let metadata = try field(bytes, 16, minimum: 48), body = try field(bytes, 24, minimum: 48)
        let expected: UInt32 = operation == 10 ? 2 : operation == 9 ? 3 : operation
        guard metadata.count >= 64, try u32(metadata, 0) == 0x53484c50, try u32(metadata, 4) == 2,
              try u32(metadata, 8) == expected, try u32(metadata, 12) == 0,
              try u32(metadata, 16) == metadata.count, try u32(metadata, 20) == 0,
              try u32(metadata, 24) == 0, try u32(metadata, 28) == 64,
              try u32(metadata, 32) == 64, try u32(metadata, 36) == 0,
              try u32(metadata, 40) == body.count, try u32(metadata, 44) == 0,
              expected == 2 || body.isEmpty else { throw invalid }
        return PlaintextReply(path: try string(field(metadata, 48, minimum: 64)),
                              contents: try string(body), revision: try string(field(metadata, 56, minimum: 64)),
                              dirty: try u32(bytes, 40) & 1 != 0, conflict: try u32(bytes, 40) & 2 != 0)
    }

    static func request(session: URLSession, endpoint: URL, operation: UInt32, target: String, path: String,
                        destination: String = "", revision: String = "", contents: String = "") async throws -> PlaintextReply {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-Environment-Request")
        request.httpBody = try encode(operation, target: target, path: path, destination: destination, revision: revision, contents: contents)
        let bytes: Data
        let response: URLResponse
        do { (bytes, response) = try await session.data(for: request) }
        catch { throw PlaintextDocumentError.connection }
        guard let http = response as? HTTPURLResponse else { throw PlaintextDocumentError.connection }
        guard http.statusCode < 500 else { throw PlaintextDocumentError.connection }
        guard http.statusCode == 200 else { throw PlaintextDocumentError.message("File request failed (HTTP \(http.statusCode))") }
        return try decode(bytes, operation: operation)
    }
}

actor PlaintextDraftStore {
    private let directory: URL?
    private let unavailableReason: String
    private var database: OpaquePointer?
    private var locks: [String: Int32] = [:]
    init(directory: URL?, unavailableReason: String = "This host does not provide persistent storage. Use the updated Outer Loop build.") {
        self.directory = directory
        self.unavailableReason = unavailableReason
    }

    private func open() throws -> OpaquePointer {
        if let database { return database }
        guard let directory else { throw PlaintextDocumentError.message(unavailableReason) }
        var handle: OpaquePointer?
        let code = sqlite3_open_v2(directory.appendingPathComponent("plaintext.sqlite").path, &handle,
                                   SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw PlaintextDocumentError.message("Cannot open local draft storage")
        }
        sqlite3_busy_timeout(handle, 3000)
        guard sqlite3_exec(handle, "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS drafts (id TEXT PRIMARY KEY, record BLOB NOT NULL);", nil, nil, nil) == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(handle)); sqlite3_close(handle)
            throw PlaintextDocumentError.message(error)
        }
        database = handle
        return handle
    }

    func put(_ draft: PlaintextDraft) throws {
        let database = try open()
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let data = try encoder.encode(draft)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT INTO drafts(id, record) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET record=excluded.record", -1, &statement, nil) == SQLITE_OK else {
            throw PlaintextDocumentError.message(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, draft.id, -1, transient) == SQLITE_OK,
              data.withUnsafeBytes({ sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(data.count), transient) }) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw PlaintextDocumentError.message(String(cString: sqlite3_errmsg(database)))
        }
    }

    func all() throws -> [PlaintextDraft] {
        let database = try open()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT record FROM drafts", -1, &statement, nil) == SQLITE_OK else {
            throw PlaintextDocumentError.message(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        var records: [PlaintextDraft] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW, let blob = sqlite3_column_blob(statement, 0) else {
                throw PlaintextDocumentError.message("Cannot read local drafts")
            }
            let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 0)))
            records.append(try PropertyListDecoder().decode(PlaintextDraft.self, from: data))
        }
        return records.sorted { $0.updated > $1.updated }
    }

    func claim(_ id: String) throws -> Bool {
        _ = try open()
        guard UUID(uuidString: id) != nil, let directory else { throw PlaintextDocumentError.message("Invalid draft identifier") }
        if locks[id] != nil { return false }
        let path = directory.appendingPathComponent("draft-\(id).lock").path
        let descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw PlaintextDocumentError.message("Cannot lock draft") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); return false }
        locks[id] = descriptor
        return true
    }

    func release(_ id: String) {
        if let descriptor = locks.removeValue(forKey: id) { close(descriptor) }
    }

    func closeStore() {
        for descriptor in locks.values { close(descriptor) }
        locks.removeAll()
        if let database { sqlite3_close(database) }
        database = nil
    }
}

@MainActor
final class PlaintextDocument {
    typealias API = @Sendable (UInt32, String, String, String, String) async throws -> PlaintextReply
    var draft: PlaintextDraft
    let store: PlaintextDraftStore
    let api: API
    var changed: (() -> Void)?
    private var checkpoint: Task<Bool, Never>?
    private var localTimer: Task<Void, Never>?
    private var draftTimer: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var retryDelay: UInt64 = 1
    private var remoteVersion = -1
    private(set) var localVersion = -1
    private(set) var localError: String?
    private(set) var networkError: String?
    var isSynchronizing: Bool { worker != nil }
    var isSaving: Bool { worker != nil && draft.pending != nil }
    var status: String {
        if let localError { return "Not saved on this device: \(localError) · Copy or export your draft" }
        if localVersion < draft.version { return "Saving draft on this device…" }
        if draft.conflict { return "Saved on this device · File changed elsewhere. Review changes in the file menu." }
        if let networkError { return "Saved on this device · \(draft.pending == nil ? "" : "Save queued · ")\(networkError)" }
        if draft.pending != nil { return "Saved on this device · Save queued" }
        if draft.dirty { return "Draft saved on this device" }
        return draft.path.isEmpty ? "Saved on this device" : "Saved to file"
    }

    init(draft: PlaintextDraft, store: PlaintextDraftStore, api: @escaping API) {
        self.draft = draft; self.store = store; self.api = api
    }

    func edit(_ contents: String) {
        draft.contents = contents; draft.version += 1; draft.dirty = true; draft.updated = Date()
        if localTimer == nil {
            localTimer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled, let self else { return }
                self.localTimer = nil; _ = await self.persist()
            }
        }
        draftTimer?.cancel()
        draftTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.resume()
        }
        changed?()
    }

    func persist() async -> Bool {
        localTimer?.cancel(); localTimer = nil
        let value = draft, previous = checkpoint, store = store
        let task = Task { [weak self] in
            _ = await previous?.value
            do {
                try await store.put(value)
                self?.localVersion = max(self?.localVersion ?? -1, value.version)
                self?.localError = nil; self?.changed?(); return true
            } catch {
                self?.localError = error.localizedDescription; self?.changed?(); return false
            }
        }
        checkpoint = task
        return await task.value
    }

    func save(path: String? = nil) async {
        guard !draft.conflict else { changed?(); return }
        if let path, path != draft.path { draft.path = path; draft.revision = "missing" }
        guard !draft.path.isEmpty else { return }
        draft.pending = PlaintextSave(path: draft.path, contents: draft.contents, revision: draft.revision, version: draft.version)
        guard await persist() else { return }
        resume()
    }

    func resume() {
        retry?.cancel(); retry = nil
        guard worker == nil, !draft.conflict, !draft.path.isEmpty else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            await self.synchronize()
            self.worker = nil; self.changed?()
        }
    }

    private func synchronize() async {
        while !draft.conflict && !Task.isCancelled {
            guard await persist() else { return }
            let saved = draft.pending, version = draft.version
            guard saved != nil || (draft.dirty && remoteVersion < version) else { return }
            do {
                if let saved {
                    let result: PlaintextReply
                    do { result = try await api(3, draft.target, saved.path, saved.revision, saved.contents) }
                    catch {
                        let original = error
                        let disk: PlaintextReply
                        do { disk = try await api(10, draft.target, saved.path, "", "") }
                        catch { throw original }
                        if disk.contents == saved.contents { result = disk }
                        else if disk.revision != saved.revision {
                            draft.conflict = true; networkError = nil; _ = await persist(); return
                        } else { throw original }
                    }
                    if draft.path == saved.path { draft.path = result.path }
                    draft.revision = result.revision
                    if draft.pending?.id == saved.id { draft.pending = nil }
                    else if draft.pending?.revision == saved.revision { draft.pending?.revision = result.revision }
                    if draft.version == saved.version { draft.dirty = false }
                    remoteVersion = saved.version
                    guard await persist() else { return }
                } else {
                    _ = try await api(9, draft.target, draft.path, draft.revision, draft.contents)
                    remoteVersion = version
                }
                networkError = nil; retryDelay = 1; changed?()
            } catch {
                networkError = error.localizedDescription; changed?()
                if !Task.isCancelled, case PlaintextDocumentError.connection = error {
                    let delay = retryDelay; retryDelay = min(30, retryDelay * 2)
                    retry = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                        guard !Task.isCancelled else { return }
                        self?.resume()
                    }
                }
                return
            }
        }
    }

    func stop() async {
        localTimer?.cancel(); draftTimer?.cancel(); retry?.cancel()
        worker?.cancel()
        await worker?.value
        _ = await persist()
    }

    func disk() async throws -> PlaintextReply { try await api(10, draft.target, draft.path, "", "") }

    func replaceReviewedFile(revision: String) async {
        guard worker == nil else { return }
        draft.revision = revision; draft.conflict = false; draft.pending = nil
        await save()
    }

    func saveCopy(path: String) async {
        guard worker == nil, path != draft.path else { return }
        draft.conflict = false; draft.pending = nil
        await save(path: path)
    }
}
