import Foundation

@main
struct NativeCodecTests {
    @MainActor
    static func main() async throws {
        let driver = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-codec-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt")
        try Data("original ☃".utf8).write(to: file)
        @Sendable func request(_ op: UInt32, revision: String = "", draftRevision: String = "missing", contents: String = "") throws -> PlaintextReply {
            let process = Process(), input = Pipe(), output = Pipe()
            process.executableURL = driver
            process.standardInput = input; process.standardOutput = output
            process.environment = ProcessInfo.processInfo.environment.merging(["XDG_STATE_HOME": root.appendingPathComponent("state").path]) { _, v in v }
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: PlaintextEnvironment.encode(op, target: "host", path: file.path, destination: draftRevision, revision: revision, contents: contents))
            try input.fileHandleForWriting.close()
            let response = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { fatalError("Driver failed") }
            return try PlaintextEnvironment.decode(response, operation: op)
        }
        let recent = try request(16)
        let recentList = try JSONDecoder().decode([[String: String]].self, from: Data(recent.contents.utf8))
        precondition(recentList == [["path": file.path, "target": "host"]])
        let reopenedRecents = try request(15)
        precondition(reopenedRecents.contents == recent.contents)
        let removedRecent = try request(17)
        precondition(removedRecent.contents == "[]")
        let read = try request(2)
        precondition(read.contents == "original ☃")
        _ = try request(9, revision: read.revision, contents: read.contents)
        let identical = try request(2)
        precondition(!identical.dirty && !identical.conflict && identical.contents == read.contents)
        _ = try request(9, revision: read.revision, contents: "draft")
        let restored = try request(2)
        precondition(restored.dirty && restored.contents == "draft")
        let disk = try request(10)
        precondition(disk.contents == "original ☃" && disk.revision == read.revision)
        let saved = try request(3, revision: read.revision, contents: "saved 🚀")
        precondition(saved.revision != read.revision)
        do {
            _ = try request(3, revision: read.revision, contents: "stale")
            fatalError("Stale revision accepted")
        } catch {}
        let written = try String(contentsOf: file, encoding: .utf8)
        precondition(written == "saved 🚀")
        let state = try request(11)
        let published = try request(12, revision: state.revision, draftRevision: state.draftRevision, contents: "shared draft")
        precondition(published.draftRevision != state.draftRevision)
        let shared = try request(11)
        precondition(shared.dirty && shared.contents == "shared draft")
        do {
            _ = try request(12, revision: state.revision, draftRevision: state.draftRevision, contents: "stale draft")
            fatalError("Stale draft token accepted")
        } catch PlaintextDocumentError.conflict {}
        let store = PlaintextDraftStore(directory: root)
        var initial = PlaintextDraft(); initial.path = file.path; initial.contents = shared.contents
        initial.revision = shared.revision; initial.draftRevision = shared.draftRevision; initial.dirty = true; initial.remoteVersion = 0
        let document = PlaintextDocument(draft: initial, store: store) { operation, _, _, revision, token, contents in
            try request(operation, revision: revision, draftRevision: token, contents: contents)
        }
        let updated = try request(12, revision: shared.revision, draftRevision: shared.draftRevision, contents: "other client typed")
        await document.refresh()
        precondition(document.draft.contents == "other client typed" && document.draft.dirty)
        let committed = try request(13, revision: updated.revision, draftRevision: updated.draftRevision, contents: "other client saved")
        await document.refresh()
        precondition(document.draft.contents == "other client saved" && !document.draft.dirty)
        document.composing = true
        let next = try request(12, revision: committed.revision, draftRevision: committed.draftRevision, contents: "later shared draft")
        await document.refresh()
        precondition(document.draft.contents == "other client saved")
        document.composing = false
        document.edit("local pending input")
        await document.refresh()
        precondition(document.draft.contents == "local pending input")
        await document.stop()
        let diskNow = try request(10)
        try await document.discardReviewedFile(diskNow, draftRevision: next.draftRevision)
        precondition(document.draft.contents == "other client saved" && !document.draft.dirty)
        let discarded = try request(11)
        precondition(discarded.draftRevision == "missing")
        let unchanged = try String(contentsOf: file, encoding: .utf8)
        precondition(unchanged == "other client saved")
        await document.stop()
        await store.closeStore()
        for count in [0, 4, 47, 48, 100] {
            do {
                _ = try PlaintextEnvironment.decode(Data(repeating: 0, count: count), operation: 2)
                fatalError("Invalid packet accepted")
            } catch {}
        }
        print("PASS native binary codec against real backend: read, server draft, raw disk, save, stale revision, malformed packets, shared refresh, guarded drafts, composition, discard")
    }
}
