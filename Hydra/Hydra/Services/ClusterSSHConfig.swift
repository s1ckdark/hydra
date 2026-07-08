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
        // Find the top-level `ssh:` block and scan its indented children until dedent.
        let lines = yaml.components(separatedBy: "\n")
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
        var v = String(line.dropFirst(key.count + 1))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        v = stripInlineComment(v)
        v = stripQuotes(v)
        return v
    }

    /// Strips a trailing ` # comment` when the value itself isn't quoted.
    /// (Quoted values are stripped of quotes separately, so a `#` inside
    /// quotes never reaches here as an unquoted value.)
    private static func stripInlineComment(_ value: String) -> String {
        let isQuoted = (value.hasPrefix("\"") || value.hasPrefix("'"))
        guard !isQuoted else { return value }
        if let range = value.range(of: " #") {
            return String(value[value.startIndex..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    /// Strips one surrounding pair of matching `"` or `'` quotes.
    private static func stripQuotes(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        let first = value.first!
        let last = value.last!
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func expand(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }
}
