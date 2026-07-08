import Foundation

/// Builds the executable script from a user snippet by prepending a preamble
/// that injects a preconfigured `client`, `sim`, `TaskSpec`, etc., and rewrites
/// tracebacks so line numbers refer to the user's code (not the preamble).
enum PreambleBuilder {
    /// The injected preamble. Its last line is the "user code below" marker so
    /// the user's first line lands immediately after. Keep this in sync with
    /// preambleLineCount semantics: assemble() counts these lines.
    static let preambleSource = """
    import os
    from hydra_client import HydraClient, TaskSpec, ResourceRequirements, Worker, sim
    from hydra_client.errors import *
    client = HydraClient(os.environ.get("HYDRA_SERVER", "http://localhost:8080"))
    # --- user code below ---
    """

    /// Returns the full script (preamble + "\n" + userCode) and the number of
    /// lines the preamble occupies (so the user's first line is line
    /// preambleLineCount+1, 1-based, in the assembled script).
    static func assemble(userCode: String) -> (script: String, preambleLineCount: Int) {
        let preambleLineCount = preambleSource.components(separatedBy: "\n").count
        let script = preambleSource + "\n" + userCode
        return (script, preambleLineCount)
    }

    /// Rewrites `File "<scriptBasename>", line N` frames to `line (N - offset)`
    /// so user-facing line numbers match what they typed. Frames pointing at
    /// other files (library code) are left untouched.
    static func adjustTraceback(_ stderr: String, scriptBasename: String, preambleLineCount: Int) -> String {
        let lines = stderr.components(separatedBy: "\n")
        let adjusted = lines.map { line -> String in
            guard line.contains(scriptBasename), let range = line.range(of: #"line (\d+)"#, options: .regularExpression) else {
                return line
            }
            let matched = String(line[range])                 // "line 9"
            let numStr = matched.replacingOccurrences(of: "line ", with: "")
            guard let n = Int(numStr) else { return line }
            let userLine = max(1, n - preambleLineCount)
            return line.replacingOccurrences(of: matched, with: "line \(userLine)")
        }
        return adjusted.joined(separator: "\n")
    }
}
