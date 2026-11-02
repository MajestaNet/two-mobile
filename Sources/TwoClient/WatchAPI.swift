// Copyright 2026 MajestaNet
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Security

/// Empty until ADR 0016 is accepted. Do not invent a token.
enum DeferredBearer {
    static func headerValue() -> String? { nil }
}

private struct VoiceTurnBody: Encodable {
    var text: String
    var profile: VoiceProfile?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(profile, forKey: .profile)
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case profile
    }
}

private struct DecideTaskBody: Encodable {
    var decision: String
    var actionDigest: String

    enum CodingKeys: String, CodingKey {
        case decision
        case actionDigest = "action_digest"
    }
}

private struct DecideVoiceBody: Encodable {
    var actionDigest: String

    enum CodingKeys: String, CodingKey {
        case actionDigest = "action_digest"
    }
}

private struct ErrorEnvelope: Decodable {
    struct Body: Decodable {
        let code: String
        let message: String
    }

    let error: Body?
    let detail: String?
    let correlationID: String?

    enum CodingKeys: String, CodingKey {
        case error
        case detail
        case correlationID = "correlation_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        error = try container.decodeIfPresent(Body.self, forKey: .error)
        correlationID = try container.decodeIfPresent(String.self, forKey: .correlationID)
        if let text = try? container.decode(String.self, forKey: .detail) {
            detail = text
        } else {
            detail = error?.message
        }
    }
}

final class EdgeSessionDelegate: NSObject, URLSessionDelegate {
    let pinnedCertificate: Data
    let accessGroup: String

    init(pinnedCertificate: Data, accessGroup: String) {
        self.pinnedCertificate = pinnedCertificate
        self.accessGroup = accessGroup
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodServerTrust {
            guard let trust = challenge.protectionSpace.serverTrust,
                  PinnedTrust.accept(trust: trust, pinnedCertificate: pinnedCertificate) else {
                return (.cancelAuthenticationChallenge, nil)
            }
            return (.useCredential, URLCredential(trust: trust))
        }
        if method == NSURLAuthenticationMethodClientCertificate {
            guard let identity = try? WatchKeychain.copyIdentity(accessGroup: accessGroup) else {
                return (.cancelAuthenticationChallenge, nil)
            }
            let credential = URLCredential(identity: identity, certificates: nil, persistence: .forSession)
            return (.useCredential, credential)
        }
        return (.cancelAuthenticationChallenge, nil)
    }
}

public final class WatchAPI {
    private var baseURLs: [URL]
    private let session: URLSession
    private let delegateRetainer: EdgeSessionDelegate?

    public init(baseURL: URL, session: URLSession) {
        self.baseURLs = [baseURL]
        self.session = session
        delegateRetainer = nil
    }

    public init(baseURLs: [URL], session: URLSession) {
        self.baseURLs = baseURLs.isEmpty ? [] : baseURLs
        self.session = session
        delegateRetainer = nil
    }

    public static func makeLive(
        endpoint: EdgeEndpoint,
        pinnedCertificate: Data,
        accessGroup: String,
        also: [EdgeEndpoint] = []
    ) -> WatchAPI {
        let delegate = EdgeSessionDelegate(
            pinnedCertificate: pinnedCertificate,
            accessGroup: accessGroup
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let urls = EdgeReach.ordered([endpoint.host] + also.map(\.host)).compactMap { host in
            try? EdgeEndpoint(host: host, port: endpoint.port).baseURL
        }
        return WatchAPI(baseURLs: urls.isEmpty ? [endpoint.baseURL] : urls, session: session, delegate: delegate)
    }

    public func replace(endpoints: [EdgeEndpoint]) {
        let urls = endpoints.map(\.baseURL)
        if !urls.isEmpty {
            baseURLs = urls
        }
    }

    private init(baseURLs: [URL], session: URLSession, delegate: EdgeSessionDelegate) {
        self.baseURLs = baseURLs
        self.session = session
        delegateRetainer = delegate
    }

    public func capabilities() async throws -> Capabilities {
        try await send("GET", "/v1/system/capabilities")
    }

    public func submitVoiceTurn(text: String, profile: VoiceProfile?) async throws -> VoiceTurnReceipt {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4_000 else {
            throw WatchFailure.validation(correlationID: nil)
        }
        let body = try JSON.encoder.encode(VoiceTurnBody(text: trimmed, profile: profile))
        return try await send("POST", "/v1/voice/turns", json: body)
    }

    public func voiceTurn(id: String) async throws -> VoiceTurnReceipt {
        try await send("GET", "/v1/voice/turns/\(component(id))")
    }

    public func decideVoiceTurn(
        id: String,
        decision: ApprovalDecision,
        digest: String
    ) async throws -> VoiceTurnReceipt {
        let body = try JSON.encoder.encode(DecideVoiceBody(actionDigest: digest))
        let path = "/v1/voice/turns/\(component(id))/\(decision.rawValue)"
        return try await send("POST", path, json: body)
    }

    public func health() async throws -> SystemHealth {
        try await send("GET", "/v1/system/health")
    }

    public func queue() async throws -> SystemQueue {
        try await send("GET", "/v1/system/queue")
    }

    public func openApprovals() async throws -> [OpenApproval] {
        let page: TaskPage = try await send("GET", "/v1/tasks")
        return listedOpenApprovals(in: page)
    }

    public func taskDiff(id: String) async throws -> TaskDiff {
        try await send("GET", "/v1/tasks/\(component(id))/diff")
    }

    public func decide(approval: OpenApproval, decision: ApprovalDecision) async throws -> DecideResult {
        let body = try JSON.encoder.encode(
            DecideTaskBody(decision: decision.rawValue, actionDigest: approval.actionDigest)
        )
        let path = "/v1/tasks/\(component(approval.taskID))/approvals/\(component(approval.approvalID))/decide"
        return try await send("POST", path, json: body)
    }

    private func send<T: Decodable>(_ method: String, _ path: String, json: Data? = nil) async throws -> T {
        let (data, response) = try await perform(method, path, json: json)
        let http = try httpResponse(response)
        let correlation = correlationID(from: http, body: data)
        guard (200..<300).contains(http.statusCode) else {
            throw failure(status: http.statusCode, data: data, correlation: correlation)
        }
        do {
            return try JSON.decoder.decode(T.self, from: data)
        } catch {
            throw WatchFailure.undecodable(status: http.statusCode, correlationID: correlation)
        }
    }

    private func perform(_ method: String, _ path: String, json: Data?) async throws -> (Data, URLResponse) {
        try rejectTaskSubmit(method: method, path: path)
        let urls = baseURLs
        var sawUnreachable = false
        for (index, base) in urls.enumerated() {
            var request = URLRequest(url: url(base, path))
            request.httpMethod = method
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = urls.count > 1 ? 6 : 15
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let json {
                request.httpBody = json
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            if let bearer = DeferredBearer.headerValue(), !bearer.isEmpty {
                request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            }
            do {
                return try await session.data(for: request)
            } catch let error as URLError where Reachability.isUnreachable(error) {
                sawUnreachable = true
                if index == urls.count - 1 {
                    throw WatchFailure.unreachable
                }
            } catch let error as WatchFailure {
                throw error
            } catch {
                throw WatchFailure.transport(correlationID: nil)
            }
        }
        if sawUnreachable {
            throw WatchFailure.unreachable
        }
        throw WatchFailure.transport(correlationID: nil)
    }

    private func rejectTaskSubmit(method: String, path: String) throws {
        if method == "POST" && (path == "/v1/tasks" || path == "/v1/tasks/") {
            throw WatchFailure.selfBuildRejected(correlationID: nil)
        }
    }

    private func url(_ base: URL, _ path: String) -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return base
        }
        components.path = path
        return components.url ?? base
    }

    private func component(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func httpResponse(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw WatchFailure.transport(correlationID: nil)
        }
        return http
    }

    private func failure(status: Int, data: Data, correlation: String?) -> WatchFailure {
        let envelope = try? JSON.decoder.decode(ErrorEnvelope.self, from: data)
        let code = envelope?.error?.code ?? ""
        let detail = envelope?.detail ?? envelope?.error?.message ?? ""
        let id = correlation ?? envelope?.correlationID
        switch status {
        case 401:
            return .unauthorized(correlationID: id)
        case 403 where detail == "client cannot submit self-build":
            return .selfBuildRejected(correlationID: id)
        case 403:
            return .forbidden(detail: detail, correlationID: id)
        case 409 where code == "profile_not_executable":
            return .profileNotExecutable(correlationID: id)
        case 409 where code == "stale_digest":
            return .staleDigest(correlationID: id)
        case 422:
            return .validation(correlationID: id)
        default:
            return .http(status: status, code: code.isEmpty ? "http" : code, correlationID: id)
        }
    }

    private func correlationID(from response: HTTPURLResponse, body: Data) -> String? {
        if let header = response.value(forHTTPHeaderField: "X-Correlation-ID"),
           !header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return header
        }
        return (try? JSON.decoder.decode(ErrorEnvelope.self, from: body))?.correlationID
    }
}
