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

    static func defaultPublicKey() throws -> Located {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        let candidates = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "pub" } ?? []

        guard !candidates.isEmpty else { throw LocateError.noKeysFound }

        let chosen = preferred(among: candidates) ?? candidates.sorted { $0.lastPathComponent < $1.lastPathComponent }[0]
        do {
            let raw = try String(contentsOf: chosen, encoding: .utf8)
            return Located(url: chosen, contents: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            throw LocateError.readFailed(error.localizedDescription)
        }
    }

    private static func preferred(among urls: [URL]) -> URL? {
        for name in preferenceOrder {
            if let match = urls.first(where: { $0.deletingPathExtension().lastPathComponent == name }) {
                return match
            }
        }
        return nil
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
