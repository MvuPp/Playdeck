import Foundation
import Testing
@testable import PlaydeckCore

@Suite struct CommandRunnerTests {
    @Test func echoStreamsLinesAndExitsZero() async throws {
        let (code, lines) = try await CommandRunner.run(URL(fileURLWithPath: "/bin/echo"), arguments: ["hello world"])
        #expect(code == 0)
        #expect(lines == ["hello world"])
    }

    @Test func nonZeroExitCodeAndStderr() async throws {
        let (code, lines) = try await CommandRunner.run(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo a; echo b >&2; printf c; exit 3"])
        #expect(code == 3)
        #expect(Set(lines) == ["a", "b", "c"])
    }

    @Test func workingDirectoryAndEnvironment() async throws {
        let (_, lines) = try await CommandRunner.run(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "pwd -P; echo $ANSIBLE_NOCOLOR$ANSIBLE_FORCE_COLOR; echo $PATH"],
            workingDirectory: URL(fileURLWithPath: "/private/tmp"))
        #expect(lines[0] == "/private/tmp")
        #expect(lines[1] == "10")
        #expect(lines[2].contains("/opt/homebrew/bin"))
    }

    @Test func cancelTerminatesProcess() async throws {
        let cmd = try CommandRunner.start(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
        let start = Date()
        cmd.cancel()
        let code = await cmd.exitCode()
        for await _ in cmd.lines {}
        #expect(code == SIGTERM)
        #expect(Date().timeIntervalSince(start) < 5)
    }
}

@Suite struct AnsibleLocatorTests {
    @Test func bogusSavedPathFallsBackToSearch() {
        // Must not crash or return the bogus dir.
        #expect(AnsibleLocator.locate(savedPath: "/nonexistent")?.directory.path != "/nonexistent")
    }

    @Test(.enabled(if: AnsibleLocator.locate(savedPath: nil) != nil, "Ansible not installed"))
    func ansibleVersion() async throws {
        let tools = try #require(AnsibleLocator.locate(savedPath: nil))
        let version = try await AnsibleLocator.version(tools)
        #expect(version.hasPrefix("ansible [core "))
    }
}
