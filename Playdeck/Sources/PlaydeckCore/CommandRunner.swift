import Foundation

/// A launched process: merged stdout/stderr lines, exit code, cancellation.
public final class RunningCommand: @unchecked Sendable {
    /// stdout and stderr lines (interleaved), finished when both pipes reach EOF.
    public let lines: AsyncStream<String>
    private let process: Process
    private let exitTask: Task<Int32, Never>

    init(process: Process, lines: AsyncStream<String>, exitTask: Task<Int32, Never>) {
        self.process = process
        self.lines = lines
        self.exitTask = exitTask
    }

    /// Waits for the process to end. After `cancel()` this is the signal number (SIGTERM = 15).
    public func exitCode() async -> Int32 { await exitTask.value }

    /// Sends SIGTERM to the process and its whole process group (e.g. ssh children holding the pipe open).
    public func cancel() {
        // Foundation's Process starts each child as its own process-group leader (pgid == pid).
        if process.isRunning { kill(-process.processIdentifier, SIGTERM) }
    }
}

public enum CommandRunner {
    /// Dirs added in front of PATH: a GUI app does not inherit the terminal's PATH.
    public static let extraPath = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"]

    public static func environment(adding extra: [String: String] = [:], executableDir: String? = nil) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let path = ([executableDir].compactMap { $0 } + extraPath + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"])
        env["PATH"] = path.joined(separator: ":")
        env["ANSIBLE_NOCOLOR"] = "1"
        env["ANSIBLE_FORCE_COLOR"] = "0"
        env.merge(extra) { _, new in new }
        return env
    }

    public static func start(
        _ executable: URL,
        arguments: [String] = [],
        workingDirectory: URL? = nil,
        environment extra: [String: String] = [:]
    ) throws -> RunningCommand {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        process.environment = environment(adding: extra, executableDir: executable.deletingLastPathComponent().path)
        process.standardInput = FileHandle.nullDevice

        let (lines, linesCont) = AsyncStream<String>.makeStream()
        let (exits, exitCont) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { p in
            exitCont.yield(p.terminationStatus)
            exitCont.finish()
        }

        let splitter = LineSplitter(openPipes: 2, continuation: linesCont)
        for (id, pipe) in [Pipe(), Pipe()].enumerated() {
            if id == 0 { process.standardOutput = pipe } else { process.standardError = pipe }
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil }
                splitter.feed(id, data)
            }
        }

        do {
            try process.run()
        } catch {
            linesCont.finish()
            throw error
        }
        let exitTask = Task { () -> Int32 in
            for await code in exits { return code }
            return -1
        }
        return RunningCommand(process: process, lines: lines, exitTask: exitTask)
    }

    /// Runs to completion and returns (exit code, all lines).
    public static func run(
        _ executable: URL,
        arguments: [String] = [],
        workingDirectory: URL? = nil
    ) async throws -> (code: Int32, lines: [String]) {
        let cmd = try start(executable, arguments: arguments, workingDirectory: workingDirectory)
        var out: [String] = []
        for await line in cmd.lines { out.append(line) }
        return (await cmd.exitCode(), out)
    }
}

/// Splits raw pipe chunks into lines, one buffer per pipe; finishes the stream when every pipe hit EOF.
private final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [Int: Data] = [:]
    private var openPipes: Int
    private let continuation: AsyncStream<String>.Continuation

    init(openPipes: Int, continuation: AsyncStream<String>.Continuation) {
        self.openPipes = openPipes
        self.continuation = continuation
    }

    func feed(_ id: Int, _ data: Data) {
        lock.lock(); defer { lock.unlock() }
        if data.isEmpty {
            if let rest = buffers.removeValue(forKey: id), !rest.isEmpty { emit(rest) }
            openPipes -= 1
            if openPipes == 0 { continuation.finish() }
            return
        }
        var buf = buffers[id, default: Data()] + data
        while let nl = buf.firstIndex(of: 0x0A) {
            emit(buf[buf.startIndex..<nl])
            buf = Data(buf[buf.index(after: nl)...])
        }
        buffers[id] = buf
    }

    private func emit(_ bytes: Data) {
        var line = String(decoding: bytes, as: UTF8.self)
        if line.hasSuffix("\r") { line.removeLast() }
        continuation.yield(line)
    }
}
