#if os(macOS)
import Foundation

/// Manages the bundled `hydra-server` Go binary as a child process whose
/// lifecycle is tied to the GUI app. If another server is already listening
/// on :8080 (e.g. the dev `make run-server` flow), we leave it alone — the
/// app just attaches to it like before. Otherwise we spawn the embedded
/// binary and SIGTERM it on `applicationWillTerminate`.
@MainActor
final class EmbeddedServer {
    static let shared = EmbeddedServer()

    private var process: Process?
    private var logHandle: FileHandle?
    private var didSpawn = false

    private init() {}

    /// Probes :8080. If something is already there, returns without spawning.
    /// Otherwise launches `Contents/Resources/hydra-server` and routes its
    /// stdout/stderr into `~/Library/Logs/Hydra/server.log` (append).
    func start() async {
        if await isPortAlive() {
            NSLog("[EmbeddedServer] external server detected on :8080 — skipping spawn")
            return
        }

        guard let serverURL = locateBinary() else {
            NSLog("[EmbeddedServer] hydra-server not found in app bundle Resources/")
            return
        }

        let logURL: URL
        do {
            logURL = try prepareLogFile()
        } catch {
            NSLog("[EmbeddedServer] failed to prepare log file: \(error)")
            return
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: logURL)
            handle.seekToEndOfFile()
        } catch {
            NSLog("[EmbeddedServer] failed to open log file: \(error)")
            return
        }

        let proc = Process()
        proc.executableURL = serverURL
        proc.standardOutput = handle
        proc.standardError = handle
        proc.terminationHandler = { p in
            NSLog("[EmbeddedServer] hydra-server exited (status=\(p.terminationStatus))")
        }

        do {
            try proc.run()
            self.process = proc
            self.logHandle = handle
            self.didSpawn = true
            NSLog("[EmbeddedServer] spawned hydra-server pid=\(proc.processIdentifier), log=\(logURL.path)")
        } catch {
            NSLog("[EmbeddedServer] failed to spawn hydra-server: \(error)")
            try? handle.close()
        }
    }

    /// Sends SIGTERM, waits up to 3s for graceful shutdown, then SIGKILL.
    /// Only acts on the process we spawned — external servers are not touched.
    func stop() {
        guard didSpawn, let proc = process, proc.isRunning else { return }
        proc.terminate()

        let deadline = Date().addingTimeInterval(3.0)
        while proc.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
            NSLog("[EmbeddedServer] hydra-server did not exit on SIGTERM — sent SIGKILL")
        } else {
            NSLog("[EmbeddedServer] hydra-server stopped cleanly")
        }
        try? logHandle?.close()
        logHandle = nil
    }

    // MARK: - Helpers

    private func locateBinary() -> URL? {
        if let url = Bundle.main.url(forResource: "hydra-server", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        return nil
    }

    private func prepareLogFile() throws -> URL {
        let dir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Hydra", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("server.log")
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        return file
    }

    private func isPortAlive() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:8080/health") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 0.3
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
#endif
