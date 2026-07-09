// vendored from jakeheis/Shout @ fbcae228 (0.5.7) — LOCALLY PATCHED to make
// ReadResult/WriteResult public, mirroring the patch iWorks/terminal applies
// in-place to its local SPM checkout (.build/checkouts/Shout, not
// git-tracked there). Vendored here as first-class source so the patch
// survives a clean checkout.
//
//  ReadWrite.swift
//  Shout
//
//  Created by Jake Heiser on 3/15/19.
//

import CSSH
import struct Foundation.Data

public enum ReadWriteProcessor {

    public enum ReadResult {
        case data(Data)
        case eagain
        case done
        case error(SSHError)
    }

    static func processRead(result: Int, buffer: inout [Int8], session: OpaquePointer) -> ReadResult {
        if result > 0 {
            let data = Data(bytes: &buffer, count: result)
            return .data(data)
        } else if result == 0 {
            return .done
        } else if result == LIBSSH2_ERROR_EAGAIN {
            return .eagain
        } else {
            return .error(SSHError.codeError(code: Int32(result), session: session))
        }
    }

    public enum WriteResult {
        case written(Int)
        case eagain
        case error(SSHError)
    }

    static func processWrite(result: Int, session: OpaquePointer) -> WriteResult {
        if result >= 0 {
            return .written(result)
        } else if result == LIBSSH2_ERROR_EAGAIN {
            return .eagain
        } else {
            return .error(SSHError.codeError(code: Int32(result), session: session))
        }
    }

}
