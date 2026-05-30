import Foundation
import OSLog

private let log = Logger(subsystem: "app.dropitdown.mac", category: "PythonRunner")

struct ProcessResult: Codable {
    let ok: Bool
    let src: String
    let recordID: Int?
    let archivedPath: String?
    let mdPath: String?
    let category: String?
    let summary: String?
    let error: String?
    let skippedReason: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case src
        case recordID = "record_id"
        case archivedPath = "archived_path"
        case mdPath = "md_path"
        case category
        case summary
        case error
        case skippedReason = "skipped_reason"
    }
}

/// Wraps the bundled `dropitdown` CLI: locates the binary inside the .app's
/// Resources/python/bin/ at runtime and spawns it as a subprocess.
///
/// Not @MainActor — subprocess waits and pipe reads must not block the UI.
final class PythonRunner: Sendable {
    /// Locate the embedded CLI binary inside the .app bundle.
    /// Falls back to whatever `dropitdown` is on PATH for unsigned/dev builds.
    private func cliPath() -> String {
        if let resourceURL = Bundle.main.resourceURL {
            let embedded = resourceURL
                .appendingPathComponent("python")
                .appendingPathComponent("bin")
                .appendingPathComponent("dropitdown")
            if FileManager.default.isExecutableFile(atPath: embedded.path) {
                return embedded.path
            }
        }
        // Dev fallback: assume `dropitdown` is on PATH (e.g. brew install).
        return "/usr/bin/env"
    }

    private func makeProcess(args: [String]) -> Process {
        let p = Process()
        // Drop-launched .app processes inherit a low QoS that throttles the
        // async pollers inside Azure SDK clients (CU long-polls a job ID).
        // Force user-interactive so timer/IO scheduling stays responsive.
        p.qualityOfService = .userInitiated
        let cli = cliPath()
        if cli.hasSuffix("/env") {
            p.executableURL = URL(fileURLWithPath: cli)
            p.arguments = ["dropitdown"] + args
        } else {
            p.executableURL = URL(fileURLWithPath: cli)
            p.arguments = args
        }
        // Forward an explicit, clean environment to the subprocess. When
        // launched via Dock, Process() inherits a stripped environment that
        // can wedge the Python CLI (network/keychain access misbehaves).
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = NSHomeDirectory()
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["PATH"] = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        // Force unbuffered stdio so we see output line-by-line.
        env["PYTHONUNBUFFERED"] = "1"
        p.environment = env
        return p
    }

    /// Process the given absolute file paths serially. Returns one result
    /// per file. Runs on a detached task so MainActor stays free for the UI.
    func process(files: [String]) async -> [ProcessResult] {
        let callID = UUID().uuidString.prefix(8)
        log.info("process(files:) called id=\(callID, privacy: .public) files=\(files, privacy: .public)")
        return await Task.detached { [files] () -> [ProcessResult] in
            let runner = PythonRunner()
            let cli = runner.cliPath()
            log.info("process(files:) detached run id=\(callID, privacy: .public) cli=\(cli, privacy: .public)")
            let args = ["process", "--json", "--no-notify"] + files
            let (stdout, stderr, exitCode) = runner.runBlocking(args: args)
            log.info("subprocess id=\(callID, privacy: .public) exited code=\(exitCode), stdout_len=\(stdout.count)")
            if !stderr.isEmpty {
                log.info("stderr=\(stderr, privacy: .public)")
            }
            var results: [ProcessResult] = []
            for line in stdout.split(separator: "\n") {
                guard let lineData = line.data(using: .utf8) else { continue }
                if let r = try? JSONDecoder().decode(ProcessResult.self, from: lineData) {
                    results.append(r)
                }
            }
            if results.isEmpty {
                return [Self.errorResultStatic(forFiles: files, reason: stderr.isEmpty ? "no output (exit \(exitCode))" : stderr)]
            }
            return results
        }.value
    }

    /// Blocking subprocess invocation. Writes stdout/stderr to temp files
    /// instead of pipes — this is the most robust IO path when the .app is
    /// unsandboxed/unsigned and the subprocess inherits weird XPC state.
    func runBlocking(args: [String]) -> (stdout: String, stderr: String, exitCode: Int32) {
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropitdown-out-\(UUID().uuidString).log")
        let errURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropitdown-err-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        guard let outHandle = try? FileHandle(forWritingTo: outURL),
              let errHandle = try? FileHandle(forWritingTo: errURL) else {
            return ("", "could not open temp log files", -1)
        }
        let p = makeProcess(args: args)
        p.standardOutput = outHandle
        p.standardError = errHandle
        // Detach stdin so the child doesn't wait on terminal input.
        p.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        do {
            try p.run()
        } catch {
            try? outHandle.close()
            try? errHandle.close()
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
            return ("", "spawn failed: \(error.localizedDescription)", -1)
        }
        log.info("runBlocking spawned pid=\(p.processIdentifier), out=\(outURL.path), err=\(errURL.path)")
        p.waitUntilExit()
        try? outHandle.close()
        try? errHandle.close()
        let stdoutText = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        let stderrText = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: outURL)
        try? FileManager.default.removeItem(at: errURL)
        return (stdoutText, stderrText, p.terminationStatus)
    }

    private static func errorResultStatic(forFiles files: [String], reason: String) -> ProcessResult {
        return ProcessResult(
            ok: false,
            src: files.first ?? "",
            recordID: nil,
            archivedPath: nil,
            mdPath: nil,
            category: nil,
            summary: nil,
            error: reason,
            skippedReason: nil
        )
    }

    /// Reveal the archived file for a record in Finder.
    func show(recordID: Int) {
        let p = makeProcess(args: ["show", String(recordID)])
        try? p.run()
    }

    /// Generic blocking CLI invocation. Returns (stdout, exit code).
    @discardableResult
    func runCLI(_ args: [String]) async -> (String, Int32) {
        return await Task.detached { [args] () -> (String, Int32) in
            let runner = PythonRunner()
            let (stdout, _, code) = runner.runBlocking(args: args)
            return (stdout, code)
        }.value
    }

    /// Fetch the recent journal entries (latest first) as decoded models.
    func fetchHistory(limit: Int = 100) async -> [HistoryEntry] {
        return await Task.detached { [limit] () -> [HistoryEntry] in
            let runner = PythonRunner()
            let (stdout, _, _) = runner.runBlocking(args: ["history", "-n", String(limit), "--json"])
            guard let data = stdout.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
        }.value
    }
}
