// Copyright 2026 MajestaNet
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum WatchFailure: Error, Equatable {
    case unreachable
    case selfBuildRejected(correlationID: String?)
    case profileNotExecutable(correlationID: String?)
    case unauthorized(correlationID: String?)
    case validation(correlationID: String?)
    case forbidden(detail: String, correlationID: String?)
    case staleDigest(correlationID: String?)
    case http(status: Int, code: String, correlationID: String?)
    case undecodable(status: Int, correlationID: String?)
    case transport(correlationID: String?)

    public var isUnreachable: Bool {
        if case .unreachable = self { return true }
        return false
    }

    public var correlationID: String? {
        switch self {
        case .unreachable:
            return nil
        case .selfBuildRejected(let id),
             .profileNotExecutable(let id),
             .unauthorized(let id),
             .validation(let id),
             .staleDigest(let id),
             .transport(let id):
            return id
        case .forbidden(_, let id),
             .http(_, _, let id),
             .undecodable(_, let id):
            return id
        }
    }

    public var screenText: String {
        switch self {
        case .unreachable:
            return "The mini is unreachable."
        case .selfBuildRejected:
            return "This app tried the coding path. That is a bug. It will not retry."
        case .profileNotExecutable:
            return "The pipe works and the binding is off."
        case .unauthorized:
            return "Enrollment or the edge on the mini is wrong. Enroll again."
        case .validation:
            return "The transcript was empty or the request was rejected."
        case .forbidden:
            return "That action is not allowed."
        case .staleDigest:
            return "The action changed. Reloading."
        case .http(_, let code, _):
            return "The mini returned \(code)."
        case .undecodable:
            return "The response could not be read."
        case .transport:
            return "The request failed."
        }
    }
}

enum Reachability {
    static func isUnreachable(_ error: URLError) -> Bool {
        switch error.code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .dataNotAllowed,
             .cannotConnectToHost,
             .cannotFindHost,
             .timedOut,
             .dnsLookupFailed,
             .internationalRoamingOff,
             .callIsActive,
             .cancelled:
            return true
        default:
            return false
        }
    }
}
