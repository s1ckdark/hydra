import Foundation

/// Reads SSH credentials from `~/.hydra/config.yaml` (overridable via
/// HYDRA_CONFIG_DIR / NAGA_CONFIG_DIR env vars) — the SAME source the Go
/// server uses (ssh.user / ssh.private_key_path / ssh.port), so a node the
/// server can reach, the terminal can reach with identical creds. Minimal
/// line-scan of the `ssh:` block (no YAML dependency).
struct ClusterSSHConfig {
    struct Resolved {
        let user: String
        let privateKeyPath: String
        let port: Int
    }

    /// Mirrors the Go server's `getConfigDir()` (config/config.go):
    /// $HYDRA_CONFIG_DIR -> $NAGA_CONFIG_DIR -> ~/.hydra
    static func configDir(env: [String: String]) -> String {
        if let d = env["HYDRA_CONFIG_DIR"], !d.isEmpty { return d }
        if let d = env["NAGA_CONFIG_DIR"], !d.isEmpty { return d }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hydra").path
    }

    static func configFileURL() -> URL {
        let dir = configDir(env: ProcessInfo.processInfo.environment)
        return URL(fileURLWithPath: dir).appendingPathComponent("config.yaml")
    }

    static func load() -> Resolved? {
        let url = configFileURL()
        guard let yaml = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return load(from: yaml)
    }

    static func load(from yaml: String) -> Resolved? {
        // Normalize CRLF/CR line endings once up front so the raw (untrimmed)
        // header/dedent comparisons below never see a trailing `\r`.
        let normalized = yaml.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        // Find the top-level `ssh:` block and scan its indented children until dedent.
        let lines = normalized.components(separatedBy: "\n")
        var inSSH = false
        var user: String?
        var keyPath: String?
        var port = 22
        for line in lines {
            if !inSSH {
                // Only a column-0 (non-indented) `ssh:` starts the block, so a
                // nested `ssh:` key elsewhere in the document is not mistaken
                // for the top-level block.
                if line == "ssh:" || line.hasPrefix("ssh: #") || line.hasPrefix("ssh:#") { inSSH = true }
                continue
            }
            // Dedent (a non-indented, non-empty line) ends the ssh block.
            if !line.isEmpty && !line.hasPrefix(" ") && !line.hasPrefix("\t") { break }
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let v = value(t, key: "user") { user = v }
            else if let v = value(t, key: "private_key_path") { keyPath = expand(v) }
            else if let v = value(t, key: "port"), let p = Int(v) { port = p }
        }
        guard let u = user, !u.isEmpty, let k = keyPath, !k.isEmpty else { return nil }
        return Resolved(user: u, privateKeyPath: k, port: port)
    }

    private static func value(_ line: String, key: String) -> String? {
        guard line.hasPrefix("\(key):") else { return nil }
        let raw = String(line.dropFirst(key.count + 1))
        return parseScalar(raw)
    }

    /// Parses a YAML scalar value, correctly handling quoted strings (whose
    /// contents may contain `#`/spaces) and unquoted values with a trailing
    /// inline `# comment`.
    private static func parseScalar(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let quote = trimmed.first, quote == "\"" || quote == "'" else {
            // Unquoted: strip a trailing inline comment (from the first
            // " #" onward), then trim again.
            if let range = trimmed.range(of: " #") {
                return String(trimmed[trimmed.startIndex..<range.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return trimmed
        }
        // Quoted: find the matching closing quote after index 0 and return
        // only the content between the quotes; anything after the closing
        // quote (whitespace/comment) is ignored.
        let afterOpen = trimmed.index(after: trimmed.startIndex)
        if let closeRange = trimmed.range(of: String(quote), range: afterOpen..<trimmed.endIndex) {
            return String(trimmed[afterOpen..<closeRange.lowerBound])
        }
        // No closing quote found: fall back to treating it as unquoted.
        if let range = trimmed.range(of: " #") {
            return String(trimmed[trimmed.startIndex..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private static func expand(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }
}
