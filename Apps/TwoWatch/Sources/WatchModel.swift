// Copyright 2026 MajestaNet
// SPDX-License-Identifier: Apache-2.0

import Foundation
import TwoClient

@MainActor
final class WatchModel: ObservableObject {
    @Published var session: WatchSession?
    @Published var status = ""
    @Published var banner = ""
    @Published var bannerVisible = false

    private var accessGroup = AccessGroup.resolved()
    private var fadeTask: Task<Void, Never>?

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
                status = "Enroll on the iPhone."
                return
            }
            guard session == nil else { return }
            session = WatchSession(
                api: WatchAPI.makeLive(
                    endpoint: enrollment.endpoint,
                    pinnedCertificate: enrollment.pinnedCertificate,
                    accessGroup: accessGroup,
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

    func refreshIfNeeded() async {
        guard session != nil, session?.principalMatches != true else { return }
        await checkExisting()
    }

    private func checkExisting() async {
        guard let session else { return }
        await session.checkCapabilities()
        if let accessGroup,
           let enrollment = try? WatchKeychain.loadEnrollment(accessGroup: accessGroup) {
            let names = EdgeReach.ordered(
                [enrollment.endpoint.host] + enrollment.alternates.map(\.host) + (session.capabilities?.edgeHosts ?? [])
            )
            let port = enrollment.endpoint.port
            let endpoints = names.compactMap { try? EdgeEndpoint(host: $0, port: port) }
            if !endpoints.isEmpty {
                session.adopt(endpoints: endpoints)
            }
        }
        if session.needsEnrollment {
            forgetSession()
            status = session.notice
        }
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
    }
}
