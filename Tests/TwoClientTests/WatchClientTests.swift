// Copyright 2026 MajestaNet
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
@testable import TwoClient

final class FixtureURLProtocol: URLProtocol {
    struct Response {
        var status: Int
        var body: Data
        var headers: [String: String] = [:]
        var error: Error?
    }

    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> Response)?
    private static var recorded: [(URLRequest, Data)] = []

    static func reset(_ handler: @escaping (URLRequest) -> Response) {
        lock.lock()
        self.handler = handler
        recorded = []
        lock.unlock()
    }

    static var requests: [(URLRequest, Data)] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.bodyData(request)
        Self.lock.lock()
        Self.recorded.append((request, body))
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = handler(request)
        if let error = response.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let http = HTTPURLResponse(
            url: request.url ?? URL(string: "https://edge.test:8443/")!,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 1024)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class WatchClientTests: XCTestCase {
    private let patchMarker = "PATCH-SHOULD-NOT-RENDER"

    override func tearDown() {
        FixtureURLProtocol.reset { _ in
            FixtureURLProtocol.Response(status: 500, body: Data())
        }
        super.tearDown()
    }

    func testCapabilitiesDecodeProfilesAndPrincipal() async throws {
        let api = try makeAPI { _ in
            self.ok([
                "schema_version": 12,
                "api_versions": ["v1"],
                "principal": "client:watch",
                "scopes": ["approvals:decide", "system:read", "tasks:read"],
                "allowed_harness_profiles": ["chat", "home-action"],
                "auth": [
                    "method": "edge_client",
                    "oidc_available": false,
                    "mobile_ready": false,
                    "edge_available": true,
                ],
                "features": ["idempotency_keys": true, "graph": true],
            ])
        }
        let caps = try await api.capabilities()
        XCTAssertEqual(caps.principal, "client:watch")
        XCTAssertEqual(caps.allowedHarnessProfiles, ["chat", "home-action"])
        XCTAssertEqual(caps.auth.method, "edge_client")
        XCTAssertFalse(caps.auth.oidcAvailable)
        XCTAssertTrue(caps.canDecide)
        XCTAssertTrue(caps.canReadSystem)
        XCTAssertTrue(caps.canReadTasks)
        XCTAssertFalse(caps.scopes.contains("tasks:control"))
        let request = try XCTUnwrap(FixtureURLProtocol.requests.first)
        XCTAssertEqual(request.0.httpMethod, "GET")
        XCTAssertEqual(request.0.url?.path, "/v1/system/capabilities")
        assertCleanHeaders(request.0)
    }

    func testVoiceTurnEncodesOnlyTextAndProfile() async throws {
        let api = try makeAPI { request in
            let path = request.url?.path ?? ""
            if path == "/v1/voice/turns" {
                return self.ok(self.receipt(profile: "chat", status: "queued", reply: "hidden"))
            }
            return self.ok([:])
        }
        let receipt = try await api.submitVoiceTurn(text: "  hello  ", profile: .chat)
        XCTAssertEqual(receipt.status, "queued")
        XCTAssertNil(receipt.replyForDisplay)
        XCTAssertEqual(receipt.statusLine, "Stored.")
        let body = try jsonObject(FixtureURLProtocol.requests[0].1)
        XCTAssertEqual(Set(body.keys), ["profile", "text"])
        XCTAssertEqual(body["text"] as? String, "hello")
        XCTAssertEqual(body["profile"] as? String, "chat")
        XCTAssertFalse(body.keys.contains(["self", "build"].joined(separator: "-")))

        FixtureURLProtocol.reset { _ in self.ok(self.receipt(profile: "home-action", status: "queued")) }
        _ = try await api.submitVoiceTurn(text: "set the living room to 20", profile: nil)
        let omitted = try jsonObject(FixtureURLProtocol.requests[0].1)
        XCTAssertEqual(Set(omitted.keys), ["text"])
    }

    func testUtteranceDefaultsToOmittedProfileUnlessChatPrefix() {
        XCTAssertNil(UtteranceRouting.submission(from: "  "))
        XCTAssertNil(UtteranceRouting.submission(from: "chat"))
        XCTAssertNil(UtteranceRouting.submission(from: "Chat,"))
        XCTAssertEqual(
            UtteranceRouting.submission(from: "turn the living room to 20"),
            VoiceSubmission(text: "turn the living room to 20", profile: nil)
        )
        XCTAssertEqual(
            UtteranceRouting.submission(from: "chat what's the weather"),
            VoiceSubmission(text: "what's the weather", profile: .chat)
        )
        XCTAssertEqual(
            UtteranceRouting.submission(from: "Chat, hello"),
            VoiceSubmission(text: "hello", profile: .chat)
        )
        XCTAssertEqual(
            UtteranceRouting.submission(from: "chapter one"),
            VoiceSubmission(text: "chapter one", profile: nil)
        )
    }

    func testDisplayLinePrefersDeviceReadback() throws {
        let climate = try JSON.decoder.decode(
            VoiceTurnReceipt.self,
            from: jsonData(receipt(
                profile: "home-action",
                status: "complete",
                extra: [
                    "climate": [
                        "zone": "living",
                        "setpoint_celsius": 20,
                        "reachable": true,
                    ],
                ]
            ))
        )
        XCTAssertEqual(climate.displayLine, "living 20°")
        let queued = try JSON.decoder.decode(
            VoiceTurnReceipt.self,
            from: jsonData(receipt(profile: "chat", status: "queued", reply: "hidden"))
        )
        XCTAssertNil(queued.displayLine)
        let waiting = try JSON.decoder.decode(
            VoiceTurnReceipt.self,
            from: jsonData(receipt(profile: "home-action", status: "awaiting_approval"))
        )
        XCTAssertEqual(waiting.displayLine, "Needs a decision on the watch.")
    }

    func testEmptyAndLongTranscriptsDoNotPost() async throws {
        let api = try makeAPI { _ in self.ok([:]) }
        do {
            _ = try await api.submitVoiceTurn(text: "   ", profile: .chat)
            XCTFail("expected validation")
        } catch let failure as WatchFailure {
            guard case .validation = failure else {
                return XCTFail("unexpected \(failure)")
            }
        }
        do {
            _ = try await api.submitVoiceTurn(text: String(repeating: "a", count: 4001), profile: .chat)
            XCTFail("expected validation")
        } catch let failure as WatchFailure {
            guard case .validation = failure else {
                return XCTFail("unexpected \(failure)")
            }
        }
        XCTAssertTrue(FixtureURLProtocol.requests.isEmpty)
    }

    func testErrorStatusesMapToScreenText() async throws {
        let cases: [(Int, String, String, WatchFailure)] = [
            (403, "forbidden", "client cannot submit self-build", .selfBuildRejected(correlationID: "corr-1")),
            (409, "profile_not_executable", "binding off", .profileNotExecutable(correlationID: "corr-1")),
            (401, "unauthorized", "no", .unauthorized(correlationID: "corr-1")),
            (422, "validation_error", "empty", .validation(correlationID: "corr-1")),
        ]
        for item in cases {
            let api = try makeAPI { _ in
                self.error(status: item.0, code: item.1, detail: item.2)
            }
            do {
                _ = try await api.submitVoiceTurn(text: "hello", profile: .chat)
                XCTFail("expected \(item.0)")
            } catch let failure as WatchFailure {
                XCTAssertEqual(failure, item.3)
                XCTAssertFalse(failure.screenText.isEmpty)
            }
        }
    }

    func testDiffDropsPatch() async throws {
        let api = try makeAPI { _ in
            self.ok([
                "task_id": "task-123",
                "summary": [
                    "files_changed": 2,
                    "lines_added": 4,
                    "lines_removed": 1,
                    "paths": ["src/secret.swift"],
                    "placeholder": false,
                ],
                "patch": self.patchMarker,
                "source_included": false,
            ])
        }
        let diff = try await api.taskDiff(id: "task-123")
        XCTAssertFalse(diff.sourceIncluded)
        XCTAssertFalse(diff.rendersPatch)
        XCTAssertEqual(diff.summaryText, "2 files, +4 -1")
        XCTAssertFalse(diff.summaryText.contains(patchMarker))
        XCTAssertFalse(String(describing: diff).contains(patchMarker))
        XCTAssertFalse(mirrorContains(diff, needle: patchMarker))
    }

    func testDecideUsesProjectionDigestUnchanged() async throws {
        let approval = OpenApproval(
            taskID: "task-123",
            approvalID: "appr-1",
            actionClass: "shell",
            actionDigest: "sha256:not-editable",
            paths: ["src/two/api/app.py"]
        )
        let api = try makeAPI { _ in
            self.ok([
                "task_id": "task-123",
                "approval_id": "appr-1",
                "decision": "approve",
                "event_id": 9,
                "ignored": false,
                "action_digest": "sha256:not-editable",
                "principal": "client:watch",
            ])
        }
        let result = try await api.decide(approval: approval, decision: .approve)
        XCTAssertEqual(result.actionDigest, approval.actionDigest)
        XCTAssertEqual(result.principal, "client:watch")
        let recorded = try XCTUnwrap(FixtureURLProtocol.requests.first)
        XCTAssertEqual(recorded.0.httpMethod, "POST")
        XCTAssertEqual(recorded.0.url?.path, "/v1/tasks/task-123/approvals/appr-1/decide")
        XCTAssertNotEqual(recorded.0.url?.path, "/v1/tasks")
        let body = try jsonObject(recorded.1)
        XCTAssertEqual(Set(body.keys), ["action_digest", "decision"])
        XCTAssertEqual(body["action_digest"] as? String, "sha256:not-editable")
        XCTAssertEqual(body["decision"] as? String, "approve")
        XCTAssertNil(body["actor"])
        assertCleanHeaders(recorded.0)
    }

    func testUnreachableURLError() async throws {
        let api = try makeAPI { _ in
            FixtureURLProtocol.Response(status: 0, body: Data(), error: URLError(.notConnectedToInternet))
        }
        do {
            _ = try await api.health()
            XCTFail("expected unreachable")
        } catch WatchFailure.unreachable {
            XCTAssertEqual(WatchFailure.unreachable.screenText, "The mini is unreachable.")
        }
    }

    func testEndpointRefusesLoopbackAndAPIPort() throws {
        XCTAssertThrowsError(try EdgeEndpoint(parsingHost: "127.0.0.1", portField: "8443")) { error in
            XCTAssertEqual(error as? EndpointError, .loopbackRefused)
        }
        XCTAssertThrowsError(try EdgeEndpoint(parsingHost: "localhost", portField: "8443")) { error in
            XCTAssertEqual(error as? EndpointError, .loopbackRefused)
        }
        XCTAssertThrowsError(try EdgeEndpoint(parsingHost: "10.1.1.5", portField: "8741")) { error in
            XCTAssertEqual(error as? EndpointError, .apiPortRefused)
        }
        XCTAssertThrowsError(try EdgeEndpoint(parsingHost: "http://10.1.1.5:8443", portField: "")) { error in
            XCTAssertEqual(error as? EndpointError, .notHTTPS)
        }
        let endpoint = try EdgeEndpoint(parsingHost: "https://10.1.1.5:8443", portField: "")
        XCTAssertEqual(endpoint.host, "10.1.1.5")
        XCTAssertEqual(endpoint.port, 8443)
        XCTAssertEqual(endpoint.baseURL.scheme, "https")
        let roundTrip = EndpointRecord.decode(EndpointRecord.encode(endpoint))
        XCTAssertEqual(roundTrip, endpoint)
    }

    func testChainMustEndAtPinnedCA() {
        let pem = """
        -----BEGIN CERTIFICATE-----
        AQIDBA==
        -----END CERTIFICATE-----
        """
        let pinned = Data(pem.utf8)
        let root = Data([0x01, 0x02, 0x03, 0x04])
        let leaf = Data([0x09])
        XCTAssertEqual(PinnedTrust.der(from: pinned), root)
        XCTAssertTrue(PinnedTrust.chainEnds(at: pinned, chain: [leaf, root]))
        XCTAssertFalse(PinnedTrust.chainEnds(at: pinned, chain: [root, leaf]))
        XCTAssertFalse(PinnedTrust.chainEnds(at: pinned, chain: []))
    }

    private func makeAPI(
        _ handler: @escaping (URLRequest) -> FixtureURLProtocol.Response
    ) throws -> WatchAPI {
        FixtureURLProtocol.reset(handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        return WatchAPI(baseURL: URL(string: "https://edge.test:8443")!, session: session)
    }

    private func ok(_ value: [String: Any]) -> FixtureURLProtocol.Response {
        FixtureURLProtocol.Response(status: 200, body: jsonData(value), headers: ["Content-Type": "application/json"])
    }

    private func error(status: Int, code: String, detail: String) -> FixtureURLProtocol.Response {
        let body: [String: Any] = [
            "error": ["code": code, "message": detail],
            "detail": detail,
            "correlation_id": "corr-1",
        ]
        return FixtureURLProtocol.Response(
            status: status,
            body: jsonData(body),
            headers: ["X-Correlation-ID": "corr-1", "Content-Type": "application/json"]
        )
    }

    private func receipt(
        profile: String,
        status: String,
        reply: String? = nil,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var body: [String: Any] = [
            "turn_id": "turn-1",
            "profile": profile,
            "status": status,
            "cursor": "MQ",
            "revision": 1,
            "fanout": [],
            "route_slots": [],
        ]
        if let reply { body["reply"] = reply }
        extra.forEach { body[$0.key] = $0.value }
        return body
    }

    private func jsonData(_ value: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: value)
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    private func assertCleanHeaders(_ request: URLRequest) {
        let names = Set((request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
        XCTAssertFalse(names.contains("x-two-edge-token"))
        XCTAssertFalse(names.contains("x-two-client-id"))
        XCTAssertFalse(names.contains("authorization"))
    }

    private func mirrorContains(_ value: Any, needle: String) -> Bool {
        if let text = value as? String { return text.contains(needle) }
        let mirror = Mirror(reflecting: value)
        for child in mirror.children {
            if mirrorContains(child.value, needle: needle) { return true }
        }
        return false
    }
}

@MainActor
final class WatchSessionTests: XCTestCase {
    func testAirplaneModeDoesNotQueueDecide() async throws {
        let approval = OpenApproval(
            taskID: "task-1",
            approvalID: "appr-1",
            actionClass: "shell",
            actionDigest: "sha256:abc",
            paths: []
        )
        let api = try makeAPI { request in
            if request.url?.path.hasSuffix("capabilities") == true {
                return self.capabilities()
            }
            return FixtureURLProtocol.Response(
                status: 0,
                body: Data(),
                error: URLError(.notConnectedToInternet)
            )
        }
        let session = WatchSession(api: api)
        await session.checkCapabilities()
        await session.decide(approval, decision: .approve, foreground: true)
        XCTAssertTrue(session.unreachable)
        XCTAssertEqual(session.notice, "The mini is unreachable.")
        XCTAssertEqual(session.queuedDecisionCount, 0)
        let posts = FixtureURLProtocol.requests.filter { $0.0.httpMethod == "POST" }
        XCTAssertEqual(posts.count, 1)
        XCTAssertFalse(session.notice.localizedCaseInsensitiveContains("approve"))
    }

    func testStaleDigestReloadsOnceAndDoesNotResend() async throws {
        let approval = OpenApproval(
            taskID: "task-123",
            approvalID: "appr-1",
            actionClass: "shell",
            actionDigest: "sha256:old",
            paths: ["README.md"]
        )
        let api = try makeAPI { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("capabilities") { return self.capabilities() }
            if request.httpMethod == "POST" {
                return self.error(status: 409, code: "stale_digest", detail: "changed")
            }
            return self.ok([
                "tasks": [[
                    "id": "task-123",
                    "approvals": [[
                        "id": "appr-1",
                        "action_class": "shell",
                        "action_digest": "sha256:new",
                        "paths": ["README.md"],
                        "status": "open",
                    ]],
                ]],
            ])
        }
        let session = WatchSession(api: api)
        await session.checkCapabilities()
        await session.decide(approval, decision: .approve, foreground: true)
        let posts = FixtureURLProtocol.requests.filter { $0.0.httpMethod == "POST" }
        XCTAssertEqual(posts.count, 1)
        let body = try JSONSerialization.jsonObject(with: posts[0].1) as? [String: Any]
        XCTAssertEqual(body?["action_digest"] as? String, "sha256:old")
        XCTAssertEqual(session.approvals.first?.actionDigest, "sha256:new")
        XCTAssertEqual(session.notice, "The action changed. Reloading.")
    }

    func testEmptyHouseAndDigestIsNotEditable() async throws {
        let api = try makeAPI { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("capabilities") { return self.capabilities() }
            if path.hasSuffix("health") {
                return self.ok([
                    "status": "healthy",
                    "stale": false,
                    "observed_at": "2026-10-30T07:50:57Z",
                    "components": [],
                ])
            }
            if path.hasSuffix("queue") {
                return self.ok([
                    "depth": 0,
                    "items": [],
                    "observed_at": "2026-10-30T07:50:57Z",
                ])
            }
            return self.ok(["tasks": []])
        }
        let session = WatchSession(api: api)
        await session.refreshHouse()
        XCTAssertEqual(session.housePicture().healthLine, "Health healthy.")
        XCTAssertEqual(session.housePicture().queueLine, "The queue is empty.")
        let picture = session.approvalPicture()
        XCTAssertFalse(picture.digestEditable)
        if case .empty = picture.body {
        } else {
            XCTFail("expected an empty approval screen")
        }
    }

    func testBackgroundDecideDoesNotPost() async throws {
        let approval = OpenApproval(
            taskID: "task-1",
            approvalID: "appr-1",
            actionClass: "shell",
            actionDigest: "sha256:abc",
            paths: []
        )
        let api = try makeAPI { _ in self.capabilities() }
        let session = WatchSession(api: api)
        await session.checkCapabilities()
        await session.decide(approval, decision: .approve, foreground: false)
        XCTAssertTrue(FixtureURLProtocol.requests.allSatisfy { $0.0.httpMethod != "POST" })
    }

    private func makeAPI(
        _ handler: @escaping (URLRequest) -> FixtureURLProtocol.Response
    ) throws -> WatchAPI {
        FixtureURLProtocol.reset(handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return WatchAPI(baseURL: URL(string: "https://edge.test:8443")!, session: session)
    }

    private func capabilities() -> FixtureURLProtocol.Response {
        ok([
            "principal": "client:watch",
            "scopes": ["approvals:decide", "system:read", "tasks:read"],
            "allowed_harness_profiles": ["chat", "home-action"],
            "auth": [
                "method": "edge_client",
                "oidc_available": false,
                "mobile_ready": false,
                "edge_available": true,
            ],
        ])
    }

    private func ok(_ value: [String: Any]) -> FixtureURLProtocol.Response {
        FixtureURLProtocol.Response(
            status: 200,
            body: try! JSONSerialization.data(withJSONObject: value)
        )
    }

    private func error(status: Int, code: String, detail: String) -> FixtureURLProtocol.Response {
        let body: [String: Any] = [
            "error": ["code": code, "message": detail],
            "detail": detail,
            "correlation_id": "corr-1",
        ]
        return FixtureURLProtocol.Response(
            status: status,
            body: try! JSONSerialization.data(withJSONObject: body),
            headers: ["X-Correlation-ID": "corr-1"]
        )
    }
}
