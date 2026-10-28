import Foundation

actor FileServer {
    var contents = "original"
    var revision = "r0"
    var offline = false
    var loseResponse = false
    var pauseSave = false
    var waiting: CheckedContinuation<Void, Never>?
    var saves: [String] = []
    func setOffline(_ value: Bool) { offline = value }
    func setLoseResponse() { loseResponse = true }
    func setPause() { pauseSave = true }
    func external(_ value: String) { contents = value; revision += "x" }
    func release() { pauseSave = false; waiting?.resume(); waiting = nil }
    func request(_ op: UInt32, _ target: String, _ path: String, _ expected: String, _ text: String) async throws -> PlaintextReply {
        if offline { throw PlaintextDocumentError.connection }
        if op == 3 {
            if pauseSave { await withCheckedContinuation { waiting = $0 } }
            guard expected == revision else { throw PlaintextDocumentError.message("File changed") }
            contents = text; revision += "s"; saves.append(text)
            if loseResponse { loseResponse = false; throw PlaintextDocumentError.connection }
        }
        return PlaintextReply(path: path, contents: contents, revision: revision)
    }
}

@main
struct NativeDocumentTests {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-drafts-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlaintextDraftStore(directory: root)
        let server = FileServer()
        func make(_ value: PlaintextDraft = PlaintextDraft()) -> PlaintextDocument {
            PlaintextDocument(draft: value, store: store) { try await server.request($0, $1, $2, $3, $4) }
        }
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw PlaintextDocumentError.message("TEST FAILED: " + message) }
        }
        func until(_ predicate: @MainActor () async -> Bool) async throws {
            for _ in 0..<500 {
                if await predicate() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw PlaintextDocumentError.message("Timed out")
        }
        let untitled = make()
        untitled.edit("Untitled ☃\n")
        try await until { untitled.localVersion == 1 }
        var records = try await store.all()
        try check(records.first?.contents == "Untitled ☃\n", "untitled checkpoint")
        try check(try await store.claim(untitled.draft.id), "first owner")
        let otherStore = PlaintextDraftStore(directory: root)
        try check(!(try await otherStore.claim(untitled.draft.id)), "second owner rejected")
        await store.release(untitled.draft.id)
        try check(try await otherStore.claim(untitled.draft.id), "ownership recovers")
        await otherStore.closeStore()
        await untitled.stop()

        var initial = PlaintextDraft(); initial.path = "/note.txt"; initial.revision = "r0"
        let doc = make(initial)
        await server.setOffline(true)
        doc.edit("queued")
        await doc.save()
        try await until { doc.networkError != nil }
        await doc.stop()
        records = try await store.all()
        guard let saved = records.first(where: { $0.id == doc.draft.id }) else { fatalError("Missing queue") }
        try check(saved.pending?.contents == "queued", "durable queue")
        await server.setOffline(false)
        let recovered = make(saved)
        recovered.resume()
        try await until { recovered.draft.pending == nil }
        try check(await server.contents == "queued", "reconnect save")
        await recovered.stop()

        var later = PlaintextDraft(); later.path = "/note.txt"; later.revision = await server.revision
        let changing = make(later)
        await server.setPause()
        changing.edit("first save")
        await changing.save()
        try await until { await server.waiting != nil }
        changing.edit("newer typing")
        await server.release()
        try await until { changing.draft.pending == nil }
        try check(changing.draft.dirty && changing.draft.contents == "newer typing", "ack preserves later edits")
        try check(await server.contents == "first save", "Save snapshot remains exact")
        await changing.stop()

        later.revision = await server.revision
        let serialized = make(later)
        await server.setPause()
        serialized.edit("one"); await serialized.save()
        try await until { await server.waiting != nil }
        serialized.edit("two"); await serialized.save()
        await server.release()
        try await until { serialized.draft.pending == nil }
        try check(await server.contents == "two" && !serialized.draft.conflict, "second save rebased")
        await serialized.stop()

        later.revision = await server.revision
        let lost = make(later)
        await server.setLoseResponse()
        lost.edit("lost response"); await lost.save()
        try await until { lost.draft.pending == nil }
        try check(!lost.draft.dirty && !lost.draft.conflict, "lost response reconciled")
        await lost.stop()

        later.revision = await server.revision
        let conflict = make(later)
        await server.external("changed elsewhere")
        conflict.edit("my draft"); await conflict.save()
        try await until { conflict.draft.conflict }
        try check(await server.contents == "changed elsewhere", "conflict never overwrites")
        let disk = try await conflict.disk()
        await conflict.replaceReviewedFile(revision: disk.revision)
        try await until { conflict.draft.pending == nil }
        try check(await server.contents == "my draft", "explicit resolution")
        await conflict.stop()

        let unavailable = PlaintextDocument(draft: initial, store: PlaintextDraftStore(directory: nil)) { _,_,_,_,_ in
            throw PlaintextDocumentError.message("Network must not run without durable queue")
        }
        unavailable.edit("keep in memory"); await unavailable.save()
        try check(unavailable.localError != nil && unavailable.draft.contents == "keep in memory" && unavailable.networkError == nil, "storage failure")
        await unavailable.stop()
        await store.closeStore()
        print("PASS native drafts: recovery, locks, queue, reconnect, snapshots, serialized saves, lost response, conflicts, storage errors")
    }
}
