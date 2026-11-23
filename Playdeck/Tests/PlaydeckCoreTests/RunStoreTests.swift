import Foundation
import Testing
@testable import PlaydeckCore

private func tempDir(_ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func sampleRun(_ date: Date, check: Bool = false) -> Run {
    var failed = HostResult(host: "beta"); failed.failed = 1; failed.ok = 2
    var ok = HostResult(host: "alpha"); ok.ok = 3; ok.changed = 1
    return Run(date: date, projectPath: "/p/debian", playbook: "playbooks/site.yml", version: "abc123-dirty",
               hosts: ["alpha", "beta"], checkMode: check, exitCode: 2, cancelled: false,
               results: [ok, failed], log: ["PLAY [all] ***", "é \"quoted\""], ledgerError: check ? nil : "boom")
}

@Suite struct RunStoreTests {
    @Test func roundTripAndNewestFirst() throws {
        let store = RunStore(directory: try tempDir("RunStoreTests").appendingPathComponent("runs"))
        let old = sampleRun(Date(timeIntervalSince1970: 1_700_000_000))
        let new = sampleRun(Date(timeIntervalSince1970: 1_800_000_000), check: true)
        let mid = sampleRun(Date(timeIntervalSince1970: 1_750_000_000))
        for r in [old, new, mid] { try store.save(r) }
        try "not json".write(to: store.directory.appendingPathComponent("junk.json"), atomically: true, encoding: .utf8)

        let loaded = store.load()
        #expect(loaded == [new, mid, old])
        #expect(loaded[2].results.map(\.status) == [.success, .failed])
        #expect(loaded[2].ledgerError == "boom" && loaded[0].ledgerError == nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
        #expect(names.contains("2023-11-14T22-13-20Z-\(old.id.uuidString).json"))
    }

    @Test func missingDirectoryIsEmpty() {
        #expect(RunStore(directory: URL(fileURLWithPath: "/nonexistent-\(UUID())")).load().isEmpty)
    }
}
