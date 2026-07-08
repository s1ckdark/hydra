import Foundation

/// Reads SSH credentials from ~/.clusterctl/config.yaml — the SAME source the
/// Go server uses (ssh.user / ssh.private_key_path / ssh.port), so a node the
/// server can reach, the terminal can reach with identical creds. Minimal
/// line-scan of the `ssh:` block (no YAML dependency).
struct ClusterSSHConfig {
    struct Resolved {
        let user: String
        let privateKeyPath: String
        let port: Int
    }

    static func load() -> Resolved? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clusterctl/config.yaml")
        guard let yaml = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return load(from: yaml)
    }

    static func load(from yaml: String) -> Resolved? {
        // Find the `ssh:` block and scan its indented children until dedent.
        let lines = yaml.components(separatedBy: "\n")
        var inSSH = false
        var user: String?
        var keyPath: String?
        var port = 22
        for line in lines {
            if !inSSH {
                if line.trimmingCharacters(in: .whitespaces) == "ssh:" { inSSH = true }
                continue
            }
            // Dedent (a non-indented, non-empty line) ends the ssh block.
            if !line.isEmpty && !line.hasPrefix(" ") && !line.hasPrefix("\t") { break }
            let t = line.trimmingCharacters(in: .whitespaces)
            if let v = value(t, key: "user") { user = v }
            else if let v = value(t, key: "private_key_path") { keyPath = expand(v) }
            else if let v = value(t, key: "port"), let p = Int(v) { port = p }
        }
        guard let u = user, let k = keyPath else { return nil }
        return Resolved(user: u, privateKeyPath: k, port: port)
    }

    private static func value(_ line: String, key: String) -> String? {
        guard line.hasPrefix("\(key):") else { return nil }
        return String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
    }

    private static func expand(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }
}
