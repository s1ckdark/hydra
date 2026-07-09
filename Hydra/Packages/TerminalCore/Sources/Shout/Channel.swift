// vendored from jakeheis/Shout @ fbcae228 (0.5.7) — LOCALLY PATCHED: made
// Channel public and added requestPty(type:cols:rows:), requestShell(), and
// requestPtySize(width:height:) for interactive PTY shells. Mirrors the
// patch iWorks/terminal applies in-place to its local SPM checkout
// (.build/checkouts/Shout, not git-tracked there — see the "shell" case
// added below and the three new public methods). Vendored here as
// first-class source so the patch survives a clean checkout.
//
//  Channel.swift
//  Shout
//
//  Created by Jake Heiser on 3/4/18.
//

import CSSH
import struct Foundation.Data
import struct Foundation.URL

/// Direct bindings to libssh2_channel
public class Channel {

    private static let session = "session"
    private static let exec = "exec"
    private static let shell = "shell"

    static let windowDefault: UInt32 = 2 * 1024 * 1024
    static let packetDefaultSize: UInt32 = 32768
    static let readBufferSize = 0x4000

    private let cSession: OpaquePointer
    private let cChannel: OpaquePointer
    private var readBuffer = [Int8](repeating: 0, count: Channel.readBufferSize)

    public static func createForCommand(cSession: OpaquePointer) throws -> Channel {
        guard let cChannel = libssh2_channel_open_ex(cSession,
                                                     Channel.session,
                                                     UInt32(Channel.session.count),
                                                     Channel.windowDefault,
                                                     Channel.packetDefaultSize, nil, 0) else {
            throw SSHError.mostRecentError(session: cSession, backupMessage: "libssh2_channel_open_ex failed")
        }
        return Channel(cSession: cSession, cChannel: cChannel)
    }

    static func createForSCP(cSession: OpaquePointer, fileSize: Int64, remotePath: String, permissions: FilePermissions) throws -> Channel {
        guard let cChannel = libssh2_scp_send64(cSession, remotePath, permissions.rawValue, fileSize, 0, 0) else {
            throw SSHError.mostRecentError(session: cSession, backupMessage: "libssh2_scp_send64 failed")
        }
        return Channel(cSession: cSession, cChannel: cChannel)
    }

    private init(cSession: OpaquePointer, cChannel: OpaquePointer) {
        self.cSession = cSession
        self.cChannel = cChannel
    }

    public func requestPty(type: String) throws {
        let code = libssh2_channel_request_pty_ex(cChannel,
                                                  type, UInt32(type.utf8.count),
                                                  nil, 0,
                                                  LIBSSH2_TERM_WIDTH, LIBSSH2_TERM_HEIGHT,
                                                  LIBSSH2_TERM_WIDTH_PX, LIBSSH2_TERM_WIDTH_PX)
        try SSHError.check(code: code, session: cSession)
    }

    // LOCAL PATCH: sized PTY request (upstream only offers the fixed default above).
    public func requestPty(type: String, cols: Int32, rows: Int32) throws {
        let code = libssh2_channel_request_pty_ex(cChannel,
                                                  type, UInt32(type.utf8.count),
                                                  nil, 0,
                                                  cols, rows,
                                                  LIBSSH2_TERM_WIDTH_PX, LIBSSH2_TERM_HEIGHT_PX)
        try SSHError.check(code: code, session: cSession)
    }

    // LOCAL PATCH: interactive shell startup (upstream only exposes exec(command:)).
    public func requestShell() throws {
        let code = libssh2_channel_process_startup(cChannel,
                                                   Channel.shell,
                                                   UInt32(Channel.shell.count),
                                                   nil, 0)
        try SSHError.check(code: code, session: cSession)
    }

    func exec(command: String) throws {
        let code = libssh2_channel_process_startup(cChannel,
                                                   Channel.exec,
                                                   UInt32(Channel.exec.count),
                                                   command,
                                                   UInt32(command.count))
        try SSHError.check(code: code, session: cSession)
    }

    public func readData() -> ReadWriteProcessor.ReadResult {
        let result = libssh2_channel_read_ex(cChannel, 0, &readBuffer, Channel.readBufferSize)
        return ReadWriteProcessor.processRead(result: result, buffer: &readBuffer, session: cSession)
    }

    public func write(data: Data, length: Int, to stream: Int32 = 0) -> ReadWriteProcessor.WriteResult {
        let result: Result<Int, SSHError> = data.withUnsafeBytes {
            guard let unsafePointer = $0.bindMemory(to: Int8.self).baseAddress else {
                return .failure(SSHError.genericError("Channel write failed to bind memory"))
            }
            return .success(libssh2_channel_write_ex(cChannel, stream, unsafePointer, length))
        }
        switch result {
        case .failure(let error):
            return .error(error)
        case .success(let value):
            return ReadWriteProcessor.processWrite(result: value, session: cSession)
        }
    }

    func sendEOF() throws {
        let code = libssh2_channel_send_eof(cChannel)
        try SSHError.check(code: code, session: cSession)
    }

    func waitEOF() throws {
        let code = libssh2_channel_wait_eof(cChannel)
        try SSHError.check(code: code, session: cSession)
    }

    // LOCAL PATCH: live PTY resize (SIGWINCH-equivalent) for terminal resizing.
    public func requestPtySize(width: Int32, height: Int32) throws {
        let code = libssh2_channel_request_pty_size_ex(cChannel, width, height, 0, 0)
        try SSHError.check(code: code, session: cSession)
    }

    public func close() throws {
        let code = libssh2_channel_close(cChannel)
        try SSHError.check(code: code, session: cSession)
    }

    func waitClosed() throws {
        let code = libssh2_channel_wait_closed(cChannel)
        try SSHError.check(code: code, session: cSession)
    }

    func exitStatus() -> Int32 {
        return libssh2_channel_get_exit_status(cChannel)
    }

    deinit {
        libssh2_channel_free(cChannel)
    }

}
