// Copyright 2026 MajestaNet
// SPDX-License-Identifier: Apache-2.0

import Foundation
import TwoClient

@MainActor
final class PhoneModel: ObservableObject {
    @Published var session: WatchSession?
    @Published var username = ""
    @Published var host = ""
    @Published var status = ""
    @Published var banner = ""
    @Published var bannerVisible = false
    @Published var authenticating = false
    @Published var discoveryFailed = false

    private var accessGroup = AccessGroup.resolved()
    private var fadeTask: Task<Void, Never>?

    var groupReady: Bool { accessGroup != nil }
    var showsGlobe: Bool { session != nil && session?.needsEnrollment != true }

    init() {
        bootstrap()
    }

    func bootstrap() {
        accessGroup = AccessGroup.resolved()
        guard let accessGroup else {
            status = "Select a Development Team so the keychain access group can be signed."
            return
        }
        do {
            guard let enrollment = try WatchKeychain.loadEnrollment(accessGroup: accessGroup) else {
                Task { await discoverHost() }
                return
            }
            host = enrollment.endpoint.host
            session = WatchSession(
                api: liveAPI(
                    enrollment.endpoint,
                    enrollment.pinnedCertificate,
                    accessGroup,
                    also: enrollment.alternates
                )
            )
            Task { await checkExisting() }
        } catch let error as KeychainError {
            status = error.screenText
        } catch {
            status = "The keychain could not be read."
        }
    }

    func enroll() async {
        guard let accessGroup else {
            status = "Select a Development Team so the keychain access group can be signed."
            return
        }
        authenticating = true
        defer { authenticating = false }
        do {
            let name = try EdgeUsername.parse(username)
            var enrollHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            if enrollHost.isEmpty {
                enrollHost = await EnrollDiscovery.firstHost() ?? ""
            }
            if enrollHost.isEmpty {
                discoveryFailed = true
                status = "Enter the mini's private host."
                return
            }
            let key = try PhoneIdentityKey.make(accessGroup: accessGroup)
            let csr = try CertificateRequest.pem(username: name, privateKey: key)
            let issued = try await EnrollClient.submit(username: name, csrPEM: csr, host: enrollHost)
            try WatchKeychain.saveIssuedCertificate(
                certificatePEM: issued.certificatePEM,
                pinnedCertificate: issued.pinnedCertificate,
                endpoint: issued.endpoint,
                accessGroup: accessGroup
            )
            host = issued.endpoint.host
            username = ""
            let alternates = issued.hosts.filter { $0.host != issued.endpoint.host }
            try WatchKeychain.saveReach(
                primary: issued.endpoint,
                alternates: alternates,
                accessGroup: accessGroup
            )
            let next = WatchSession(
                api: liveAPI(issued.endpoint, issued.pinnedCertificate, accessGroup, also: alternates)
            )
            session = next
            await next.checkCapabilities()
            rememberReach(next)
            if next.needsEnrollment {
                WatchKeychain.clear(accessGroup: accessGroup)
                session = nil
                status = next.notice
                return
            }
            status = ""
        } catch let error as EdgeUsernameError {
            status = error.screenText
        } catch let error as EndpointError {
            discoveryFailed = true
            status = error.screenText
        } catch let error as EnrollFailure {
            status = error.screenText
        } catch let error as KeychainError {
            status = error.screenText
        } catch is CertificateRequestError {
            status = "The phone could not create an enrollment key."
        } catch {
            status = "Enrollment failed."
        }
    }

    func send(_ spoken: String) async {
        guard let session, showsGlobe else { return }
        guard let submission = UtteranceRouting.submission(from: spoken) else { return }
        await session.sendTranscript(submission.text, profile: submission.profile, foreground: true)
        await poll(session)
        if session.needsEnrollment {
            forgetSession()
            status = session.notice
            return
        }
        showBanner(session.replyText ?? session.notice)
    }

    func discoverHost() async {
        if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let found = await EnrollDiscovery.firstHost() {
                host = found
                discoveryFailed = false
            } else {
                discoveryFailed = true
            }
        }
    }

    func refreshIfNeeded() async {
        guard session != nil, session?.principalMatches != true else { return }
        await checkExisting()
    }

    private func checkExisting() async {
        guard let session else { return }
        await session.checkCapabilities()
        rememberReach(session)
        if session.needsEnrollment {
            forgetSession()
            status = session.notice
        }
    }

    private func rememberReach(_ session: WatchSession) {
        guard let accessGroup else { return }
        guard let enrollment = try? WatchKeychain.loadEnrollment(accessGroup: accessGroup) else { return }
        let learned = session.capabilities?.edgeHosts ?? []
        let names = EdgeReach.ordered(
            [enrollment.endpoint.host] + enrollment.alternates.map(\.host) + learned
        )
        guard let primary = try? EdgeEndpoint(host: names[0], port: enrollment.endpoint.port) else { return }
        let alternates = names.dropFirst().compactMap { try? EdgeEndpoint(host: $0, port: enrollment.endpoint.port) }
        let changed = primary.host != enrollment.endpoint.host
            || alternates.map(\.host) != enrollment.alternates.map(\.host)
        if changed {
            try? WatchKeychain.saveReach(
                primary: primary,
                alternates: alternates,
                accessGroup: accessGroup
            )
        }
        session.adopt(endpoints: [primary] + alternates)
    }

    private func poll(_ session: WatchSession) async {
        var remaining = 40
        while let id = session.pendingTurnID, remaining > 0 {
            remaining -= 1
            try? await Task.sleep(nanoseconds: 500_000_000)
            await session.refreshVoice(id: id)
        }
    }

    private func showBanner(_ text: String) {
        fadeTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            banner = ""
            bannerVisible = false
            return
        }
        banner = trimmed
        bannerVisible = true
        fadeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            bannerVisible = false
        }
    }

    private func forgetSession() {
        if let accessGroup {
            WatchKeychain.clear(accessGroup: accessGroup)
        }
        session = nil
        Task { await discoverHost() }
    }

    private func liveAPI(
        _ endpoint: EdgeEndpoint,
        _ certificate: Data,
        _ accessGroup: String,
        also: [EdgeEndpoint] = []
    ) -> WatchAPI {
        WatchAPI.makeLive(
            endpoint: endpoint,
            pinnedCertificate: certificate,
            accessGroup: accessGroup,
            also: also
        )
    }
}
