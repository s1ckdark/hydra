// vendored from jakeheis/Shout @ fbcae228 (0.5.7) — LOCALLY PATCHED: added
// rawHostKey() (Hydra-specific addition, not part of iWorks/terminal's
// patch) which wraps libssh2_session_hostkey + libssh2_hostkey_hash so
// SSHTransportMac's LibSSH2Session can populate HostKeyFingerprint for the
// app-layer TOFU gate (HostKeyGate). Vendored here as first-class source —
// see Channel.swift/ReadWrite.swift for the shell/PTY half of the patch
// that mirrors iWorks/terminal's local (non-git-tracked) checkout patch.
//
//  Session.swift
//  Shout
//
//  Created by Jake Heiser on 3/4/18.
//

import Foundation
import CSSH
import Socket

/// Direct bindings to libssh2_session
class Session {

    private static let initResult = libssh2_init(0)

    private let cSession: OpaquePointer
    private var agent: Agent?

    var blocking: Int32 {
        get {
            return libssh2_session_get_blocking(cSession)
        }
        set(newValue) {
            libssh2_session_set_blocking(cSession, newValue)
        }
    }

    init() throws {
        guard Session.initResult == 0 else {
            throw SSHError.genericError("libssh2_init failed")
        }

        guard let cSession = libssh2_session_init_ex(nil, nil, nil, nil) else {
            throw SSHError.genericError("libssh2_session_init failed")
        }

        self.cSession = cSession
    }

    func handshake(over socket: Socket) throws {
        let code = libssh2_session_handshake(cSession, socket.socketfd)
        try SSHError.check(code: code, session: cSession)
    }

    func authenticate(username: String, privateKey: String, publicKey: String, passphrase: String?) throws {
        let code = libssh2_userauth_publickey_fromfile_ex(cSession,
                                                          username,
                                                          UInt32(username.count),
                                                          publicKey,
                                                          privateKey,
                                                          passphrase)
        try SSHError.check(code: code, session: cSession)
    }

    func authenticate(username: String, password: String) throws {
        let code = libssh2_userauth_password_ex(cSession,
                                                username,
                                                UInt32(username.count),
                                                password,
                                                UInt32(password.count),
                                                nil)
        try SSHError.check(code: code, session: cSession)
    }

    func openSftp() throws -> SFTP  {
        return try SFTP(session: self, cSession: cSession)
    }

    func openCommandChannel() throws -> Channel {
        return try Channel.createForCommand(cSession: cSession)
    }

    func openSCPChannel(fileSize: Int64, remotePath: String, permissions: FilePermissions) throws -> Channel {
        return try Channel.createForSCP(cSession: cSession, fileSize: fileSize, remotePath: remotePath, permissions: permissions)
    }

    func openAgent() throws -> Agent {
        if let agent = agent {
            return agent
        }
        let newAgent = try Agent(cSession: cSession)
        agent = newAgent
        return newAgent
    }

    // LOCAL ADDITION (Hydra): raw host-key material for app-layer TOFU.
    // libssh2_session_hostkey returns the server's public key blob (wire
    // format, not base64) plus its libssh2 key-type constant;
    // libssh2_hostkey_hash(..., SHA256) returns the fixed 32-byte SHA256
    // digest of that key. Both pointers are owned by libssh2 and valid only
    // for the lifetime of the session — copied into Data immediately.
    func rawHostKey() -> (type: Int32, keyBytes: Data, sha256: Data)? {
        var len: Int = 0
        var type: Int32 = 0
        guard let keyPtr = libssh2_session_hostkey(cSession, &len, &type), len > 0 else {
            return nil
        }
        let keyBytes = Data(bytes: keyPtr, count: len)

        guard let hashPtr = libssh2_hostkey_hash(cSession, LIBSSH2_HOSTKEY_HASH_SHA256) else {
            return nil
        }
        let sha256 = Data(bytes: hashPtr, count: 32)

        return (type, keyBytes, sha256)
    }

    deinit {
        libssh2_session_free(cSession)
    }

}
