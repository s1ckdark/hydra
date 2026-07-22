import Foundation
import CryptoKit

/// Ed25519 SSH 키페어를 생성해 OpenSSH 포맷(openssh-key-v1, 비암호화)으로
/// 직렬화한다. macOS(libssh2)와 iOS(Citadel) 양쪽 백엔드가 읽는 포맷.
enum SSHKeyGenerator {
    struct GeneratedKey {
        /// "-----BEGIN OPENSSH PRIVATE KEY-----" PEM 전체 (끝 개행 포함)
        let privateKeyOpenSSH: String
        /// "ssh-ed25519 <base64> <comment>" — authorized_keys 한 줄
        let publicKeyLine: String
    }

    static func generate(comment: String) -> GeneratedKey {
        let key = Curve25519.Signing.PrivateKey()
        return serialize(seed: key.rawRepresentation,
                         publicKey: key.publicKey.rawRepresentation,
                         comment: comment)
    }

    /// 결정적 입력을 받는 순수 직렬화 — 테스트에서 직접 호출 가능하도록 분리.
    static func serialize(seed: Data, publicKey: Data, comment: String) -> GeneratedKey {
        let keyType = Data("ssh-ed25519".utf8)

        // 공개키 blob: string type || string pub(32B)
        var pubBlob = Data()
        pubBlob.appendSSHString(keyType)
        pubBlob.appendSSHString(publicKey)

        // 개인키 섹션: check쌍, type, pub, seed||pub(64B), comment, 1..n 패딩
        let check = UInt32.random(in: .min ... .max)
        var privSection = Data()
        privSection.appendUInt32(check)
        privSection.appendUInt32(check)
        privSection.appendSSHString(keyType)
        privSection.appendSSHString(publicKey)
        privSection.appendSSHString(seed + publicKey)
        privSection.appendSSHString(Data(comment.utf8))
        var pad: UInt8 = 1
        while privSection.count % 8 != 0 { privSection.append(pad); pad += 1 }

        var blob = Data("openssh-key-v1\0".utf8)
        blob.appendSSHString(Data("none".utf8))   // ciphername
        blob.appendSSHString(Data("none".utf8))   // kdfname
        blob.appendSSHString(Data())              // kdfoptions
        blob.appendUInt32(1)                      // key count
        blob.appendSSHString(pubBlob)
        blob.appendSSHString(privSection)

        let body = blob.base64EncodedString().chunked(into: 70).joined(separator: "\n")
        let pem = "-----BEGIN OPENSSH PRIVATE KEY-----\n\(body)\n-----END OPENSSH PRIVATE KEY-----\n"
        let publicLine = "ssh-ed25519 \(pubBlob.base64EncodedString()) \(comment)"
        return GeneratedKey(privateKeyOpenSSH: pem, publicKeyLine: publicLine)
    }
}

private extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        var be = value.bigEndian
        append(Data(bytes: &be, count: 4))
    }
    /// SSH wire format string: uint32 길이 + 바이트
    mutating func appendSSHString(_ data: Data) {
        appendUInt32(UInt32(data.count))
        append(data)
    }
}

private extension String {
    func chunked(into size: Int) -> [String] {
        var result: [String] = []
        var idx = startIndex
        while idx < endIndex {
            let end = index(idx, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(String(self[idx..<end]))
            idx = end
        }
        return result
    }
}
