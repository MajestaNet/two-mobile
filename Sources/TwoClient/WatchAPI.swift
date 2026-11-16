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

final class EdgeSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
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

    /// The client-certificate challenge restarts the request. A POST body
    /// cannot be read twice unless a fresh stream is supplied.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        needNewBodyStreamFrom offset: Int64,
        completionHandler: @escaping @Sendable (InputStream?) -> Void
    ) {
        guard let body = task.originalRequest?.httpBody else {
            completionHandler(nil)
            return
        }
        let stream = InputStream(data: body)
        if offset > 0 {
            stream.open()
            var skipped = 0
            var buffer = [UInt8](repeating: 0, count: 4096)
            while skipped < offset {
                let want = min(buffer.count, Int(offset) - skipped)
                let count = stream.read(&buffer, maxLength: want)
                if count <= 0 { break }
                skipped += count
            }
        }
        completionHandler(stream)
    }
}

public final class WatchAPI {
    private struct Attempt: Sendable {
        var data: Data
        var status: Int
        var headers: [String: String]
        var url: URL
        var base: URL

        var httpResponse: HTTPURLResponse {
            HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ) ?? HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
        }
    }

    private var baseURLs: [URL]
    private let urlsLock = NSLock()
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
        let incoming = endpoints.map(\.baseURL)
        guard !incoming.isEmpty else { return }
        urlsLock.lock()
        defer { urlsLock.unlock() }
        // Keep the host that just answered, even when the new list prefers another address.
        if let preferred = baseURLs.first,
           let kept = incoming.first(where: { Self.sameEndpoint($0, preferred) }) {
            baseURLs = [kept] + incoming.filter { !Self.sameEndpoint($0, kept) }
        } else {
            baseURLs = incoming
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

    public func adapters() async throws -> AdapterMenu {
        try await send("GET", "/v1/system/adapters")
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

    /// Reads ask every saved host together. The first answer is used.
    /// A voice turn tries one host at a time so a command is not sent twice.
    private func perform(_ method: String, _ path: String, json: Data?) async throws -> (Data, URLResponse) {
        try rejectTaskSubmit(method: method, path: path)
        let urls = copyBaseURLs()
        if method == "GET", urls.count > 1 {
            return try await race(method, path, json: json, urls: urls)
        }
        return try await sequence(method, path, json: json, urls: urls)
    }

    private func race(
        _ method: String,
        _ path: String,
        json: Data?,
        urls: [URL]
    ) async throws -> (Data, URLResponse) {
        let session = self.session
        let requests = urls.map { base in
            (base, makeRequest(method, path, json: json, base: base, timeout: 15))
        }
        return try await withThrowingTaskGroup(of: Attempt.self) { group in
            for (base, request) in requests {
                group.addTask {
                    let (data, response) = try await session.data(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw URLError(.badServerResponse)
                    }
                    var headers: [String: String] = [:]
                    for (key, value) in http.allHeaderFields {
                        guard let name = key as? String else { continue }
                        headers[name] = value as? String ?? "\(value)"
                    }
                    return Attempt(
                        data: data,
                        status: http.statusCode,
                        headers: headers,
                        url: http.url ?? request.url ?? base,
                        base: base
                    )
                }
            }
            var lastError: URLError?
            var pending = requests.count
            while pending > 0 {
                pending -= 1
                do {
                    guard let attempt = try await group.next() else { break }
                    group.cancelAll()
                    self.promote(attempt.base)
                    return (attempt.data, attempt.httpResponse)
                } catch let error as URLError {
                    lastError = error
                } catch is CancellationError {
                    group.cancelAll()
                    throw CancellationError()
                } catch {
                    lastError = URLError(.unknown)
                }
            }
            group.cancelAll()
            if let lastError {
                throw self.failure(for: lastError)
            }
            throw WatchFailure.transport(correlationID: nil)
        }
    }

    private func sequence(
        _ method: String,
        _ path: String,
        json: Data?,
        urls: [URL]
    ) async throws -> (Data, URLResponse) {
        var lastError: URLError?
        for (index, base) in urls.enumerated() {
            let request = makeRequest(
                method,
                path,
                json: json,
                base: base,
                timeout: urls.count > 1 ? 6 : 15
            )
            do {
                let result = try await session.data(for: request)
                promote(base)
                return result
            } catch let error as URLError {
                lastError = error
                if index == urls.count - 1 {
                    throw failure(for: error)
                }
            } catch let error as WatchFailure {
                throw error
            } catch {
                if index == urls.count - 1 {
                    throw WatchFailure.transport(correlationID: nil)
                }
            }
        }
        if let lastError {
            throw failure(for: lastError)
        }
        throw WatchFailure.transport(correlationID: nil)
    }

    private func makeRequest(
        _ method: String,
        _ path: String,
        json: Data?,
        base: URL,
        timeout: TimeInterval
    ) -> URLRequest {
        var request = URLRequest(url: url(base, path))
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            request.httpBody = json
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let bearer = DeferredBearer.headerValue(), !bearer.isEmpty {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func copyBaseURLs() -> [URL] {
        urlsLock.lock()
        defer { urlsLock.unlock() }
        return baseURLs
    }

    private func promote(_ url: URL) {
        urlsLock.lock()
        defer { urlsLock.unlock() }
        guard let index = baseURLs.firstIndex(where: { Self.sameEndpoint($0, url) }), index > 0 else { return }
        let preferred = baseURLs.remove(at: index)
        baseURLs.insert(preferred, at: 0)
    }

    private static func sameEndpoint(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme == rhs.scheme && lhs.host == rhs.host && lhs.port == rhs.port
    }

    private func failure(for error: URLError) -> WatchFailure {
        if Reachability.isUnreachable(error) {
            return .unreachable
        }
        return .transport(correlationID: nil)
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
