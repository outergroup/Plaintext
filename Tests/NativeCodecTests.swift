import Foundation

@main
struct NativeCodecTests {
    static func main() throws {
        let driver = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-codec-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt")
        try Data("original ☃".utf8).write(to: file)
        func request(_ op: UInt32, revision: String = "", contents: String = "") throws -> PlaintextReply {
            let process = Process(), input = Pipe(), output = Pipe()
            process.executableURL = driver
            process.standardInput = input; process.standardOutput = output
            process.environment = ProcessInfo.processInfo.environment.merging(["XDG_STATE_HOME": root.appendingPathComponent("state").path]) { _, v in v }
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: PlaintextEnvironment.encode(op, target: "host", path: file.path, revision: revision, contents: contents))
            try input.fileHandleForWriting.close()
            let response = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { fatalError("Driver failed") }
            return try PlaintextEnvironment.decode(response, operation: op)
        }
        let read = try request(2)
        precondition(read.contents == "original ☃")
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
        for count in [0, 4, 47, 48, 100] {
            do {
                _ = try PlaintextEnvironment.decode(Data(repeating: 0, count: count), operation: 2)
                fatalError("Invalid packet accepted")
            } catch {}
        }
        print("PASS native binary codec against real backend: read, server draft, raw disk, save, stale revision, malformed packets")
    }
}
