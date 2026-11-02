// Copyright 2026 MajestaNet
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Security

public struct PhoneEnrollment: Equatable, Sendable {
    public let endpoint: EdgeEndpoint
    public let hosts: [EdgeEndpoint]
    public let certificatePEM: Data
    public let pinnedCertificate: Data
}

public enum EnrollFailure: Error, Equatable {
    case unreachable
    case rejected(String)
    case certificateMismatch
    case identity

    public var screenText: String {
        switch self {
        case .unreachable:
            return "The mini is unreachable."
        case .rejected(let detail):
            return detail.isEmpty ? "Enrollment was refused." : detail
        case .certificateMismatch:
            return "The signed certificate did not match the enrollment listener."
        case .identity:
            return "The keychain could not store the identity."
        }
    }
}

struct EnrollResponse: Decodable {
    let certificate: String
    let ca: String
    let host: String
    let port: Int
    let hosts: [String]?
}

final class EnrollTrust: NSObject, URLSessionDelegate {
    var leaf: Data?

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodServerTrust {
            guard let trust = challenge.protectionSpace.serverTrust else {
                return (.cancelAuthenticationChallenge, nil)
            }
            if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
               let first = chain.first {
                leaf = SecCertificateCopyData(first) as Data
            }
            return (.useCredential, URLCredential(trust: trust))
        }
        return (.cancelAuthenticationChallenge, nil)
    }
}

public enum EnrollClient {
    public static let defaultEnrollPort = 8444

    public static func submit(
        username: String,
        csrPEM: String,
        host: String,
        enrollPort: Int = defaultEnrollPort
    ) async throws -> PhoneEnrollment {
        let name = try EdgeUsername.parse(username)
        let endpoint = try EdgeEndpoint(parsingHost: host, portField: String(enrollPort))
        let trust = EnrollTrust()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration, delegate: trust, delegateQueue: nil)
        var components = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/v1/edge/enroll"
        guard let url = components?.url else { throw EnrollFailure.unreachable }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSON.encoder.encode(EnrollBody(username: name, csr: csrPEM))
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw EnrollFailure.unreachable
        }
        guard let http = response as? HTTPURLResponse else {
            throw EnrollFailure.unreachable
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSON.decoder.decode(EnrollErrorBody.self, from: data))?.detail ?? ""
            throw EnrollFailure.rejected(detail)
        }
        let body = try JSON.decoder.decode(EnrollResponse.self, from: data)
        let ca = Data(body.ca.utf8)
        if let leaf = trust.leaf, !PinnedTrust.leaf(leaf, signedBy: ca) {
            throw EnrollFailure.certificateMismatch
        }
        let names = EdgeReach.ordered(body.hosts ?? [body.host])
        let reach = names.compactMap { try? EdgeEndpoint(host: $0, port: body.port) }
        let apiEndpoint = try EdgeEndpoint(host: body.host, port: body.port)
        let primary = reach.first ?? apiEndpoint
        return PhoneEnrollment(
            endpoint: primary,
            hosts: reach.isEmpty ? [apiEndpoint] : reach,
            certificatePEM: Data(body.certificate.utf8),
            pinnedCertificate: ca
        )
    }
}

private struct EnrollBody: Encodable {
    let username: String
    let csr: String
}

private struct EnrollErrorBody: Decodable {
    let detail: String?
}

public enum EnrollDiscovery {
    public static func firstHost(timeoutSeconds: TimeInterval = 2) async -> String? {
#if os(watchOS)
        _ = timeoutSeconds
        return nil
#else
        await BonjourEnrollFinder.find(timeoutSeconds: timeoutSeconds)
#endif
    }
}

#if !os(watchOS)
private final class BonjourEnrollFinder: NSObject, NetServiceBrowserDelegate, NetServiceDelegate, @unchecked Sendable {
    private let browser = NetServiceBrowser()
    private var service: NetService?
    private var continuation: CheckedContinuation<String?, Never>?
    private var finished = false

    static func find(timeoutSeconds: TimeInterval) async -> String? {
        let finder = BonjourEnrollFinder()
        return await withCheckedContinuation { continuation in
            finder.continuation = continuation
            finder.browser.delegate = finder
            finder.browser.searchForServices(ofType: "_two-enroll._tcp.", inDomain: "local.")
            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) {
                finder.finish(nil)
            }
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard self.service == nil else { return }
        self.service = service
        service.delegate = self
        service.resolve(withTimeout: 1.5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        finish(sender.hostName)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        finish(nil)
    }

    private func finish(_ host: String?) {
        guard !finished else { return }
        finished = true
        browser.stop()
        service?.stop()
        let trimmed = host?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        continuation?.resume(returning: trimmed?.isEmpty == false ? trimmed : nil)
        continuation = nil
    }
}
#endif
