import Foundation
#if canImport(AppKit)
import AppKit
#endif

enum SSHKeyLocator {
    enum LocateError: LocalizedError {
        case noKeysFound
        case readFailed(String)

        var errorDescription: String? {
            switch self {
            case .noKeysFound:
                return "~/.ssh 에 공개키(.pub)가 없어요. 먼저 `ssh-keygen -t ed25519`로 키를 만들어주세요."
            case .readFailed(let detail):
                return "공개키 읽기 실패: \(detail)"
            }
        }
    }

    struct Located {
        let url: URL
        let contents: String
        var filename: String { url.lastPathComponent }
    }

    private static let preferenceOrder = ["id_ed25519", "id_ecdsa", "id_rsa", "id_dsa"]

    struct KeyPair: Equatable {
        let privatePath: String
        let publicURL: URL
        let algorithmName: String
    }

    private static func defaultSSHDir() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
    }

    /// All `~/.ssh` keypairs that have BOTH a `.pub` and a matching private key,
    /// ordered like OpenSSH would offer identities: preferenceOrder first, then
    /// any other keys by filename. Empty dir throws `.noKeysFound`.
    static func orderedKeyPairs(in sshDir: URL = defaultSSHDir()) throws -> [KeyPair] {
        let pubs = (try? FileManager.default.contentsOfDirectory(at: sshDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "pub" } ?? []

        var pairs: [KeyPair] = []
        for pub in pubs {
            let priv = pub.deletingPathExtension()
            guard FileManager.default.fileExists(atPath: priv.path) else { continue }
            let base = priv.lastPathComponent
            pairs.append(KeyPair(privatePath: priv.path,
                                 publicURL: pub,
                                 algorithmName: algorithmName(forBasename: base)))
        }
        guard !pairs.isEmpty else { throw LocateError.noKeysFound }

        return pairs.sorted { a, b in
            let ra = rank(a.publicURL.deletingPathExtension().lastPathComponent)
            let rb = rank(b.publicURL.deletingPathExtension().lastPathComponent)
            if ra != rb { return ra < rb }
            return a.privatePath < b.privatePath
        }
    }

    private static func rank(_ basename: String) -> Int {
        preferenceOrder.firstIndex(of: basename) ?? preferenceOrder.count
    }

    static func algorithmName(forBasename base: String) -> String {
        base.hasPrefix("id_") ? String(base.dropFirst(3)) : base
    }

    static func defaultPublicKey() throws -> Located {
        guard let first = try orderedKeyPairs().first else { throw LocateError.noKeysFound }
        do {
            let raw = try String(contentsOf: first.publicURL, encoding: .utf8)
            return Located(url: first.publicURL, contents: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            throw LocateError.readFailed(error.localizedDescription)
        }
    }

    static func defaultPrivateKeyPath() throws -> String {
        guard let first = try orderedKeyPairs().first else { throw LocateError.noKeysFound }
        return first.privatePath
    }

    @MainActor
    static func copyToClipboard(_ key: Located) {
        #if canImport(AppKit)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(key.contents, forType: .string)
        #endif
    }
}
