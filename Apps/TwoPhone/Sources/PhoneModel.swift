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
    @Published var appliances: [ApplianceCard] = []
    @Published var applianceNotice = ""
    @Published var checkingAppliances = false
    @Published var appliancesReady = false
    @Published var busyApplianceID: String?

    private var accessGroup = AccessGroup.resolved()
    private var fadeTask: Task<Void, Never>?
    private var houseGeneration = 0

    var groupReady: Bool { accessGroup != nil }
    var showsGlobe: Bool { session != nil && session?.needsEnrollment != true }
    var controlsEnabled: Bool {
        session?.showsHomeAction == true && busyApplianceID == nil
    }

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
        let generation = nextHouseGeneration()
        checkingAppliances = false
        await waitUntilVoiceIdle(generation)
        guard current(generation) else { return }
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

    func refreshAppliances() async {
        let generation = nextHouseGeneration()
        await reloadAppliances(generation)
    }

    func stopApplianceChecks() {
        houseGeneration += 1
        checkingAppliances = false
    }

    func control(_ verb: ApplianceVerb, _ card: ApplianceCard) {
        guard session?.showsHomeAction == true, busyApplianceID == nil else { return }
        guard ApplianceCatalog.phrase(card.appliance, verb) != nil else { return }
        busyApplianceID = card.id
        checkingAppliances = false
        let generation = nextHouseGeneration()
        Task { await command(verb, card, generation) }
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

    private func reloadAppliances(_ generation: Int) async {
        guard let session, showsGlobe else { return }
        checkingAppliances = true
        defer {
            if current(generation) {
                checkingAppliances = false
                appliancesReady = true
            }
        }
        if session.capabilities == nil {
            await session.checkCapabilities()
        }
        guard current(generation) else { return }
        guard session.capabilities?.canReadSystem == true else {
            applianceNotice = "system:read is not granted."
            appliances = []
            return
        }
        let menu: AdapterMenu
        do {
            menu = try await session.adapters()
        } catch let failure as WatchFailure {
            applianceNotice = failure.screenText
            if failure.isUnreachable { markOffline() }
            return
        } catch {
            applianceNotice = WatchFailure.unreachable.screenText
            markOffline()
            return
        }
        guard current(generation) else { return }
        let prior = Dictionary(uniqueKeysWithValues: appliances.map { ($0.id, $0) })
        appliances = ApplianceCatalog.appliances(in: menu).map { item in
            if let existing = prior[item.id] {
                return ApplianceCard(appliance: item, link: existing.link, detail: existing.detail)
            }
            return ApplianceCard(appliance: item, link: .unknown, detail: "")
        }
        if appliances.isEmpty {
            applianceNotice = "No appliances are bound."
            return
        }
        applianceNotice = ""
        guard session.showsHomeAction else {
            applianceNotice = "home-action is not granted."
            return
        }
        for card in appliances {
            guard current(generation) else { return }
            await probe(card.appliance, generation)
        }
    }

    private func probe(_ appliance: BoundAppliance, _ generation: Int) async {
        guard let phrase = ApplianceCatalog.phrase(appliance, .read) else { return }
        markChecking(appliance.id, generation)
        await runTurn(phrase, appliance: appliance, generation: generation)
    }

    private func command(_ verb: ApplianceVerb, _ card: ApplianceCard, _ generation: Int) async {
        defer {
            if busyApplianceID == card.id { busyApplianceID = nil }
        }
        guard let session, showsGlobe, session.showsHomeAction else { return }
        guard let phrase = ApplianceCatalog.phrase(card.appliance, verb) else { return }
        await runTurn(phrase, appliance: card.appliance, generation: generation)
    }

    private func runTurn(_ phrase: String, appliance: BoundAppliance, generation: Int) async {
        guard let session else { return }
        await waitUntilVoiceIdle(generation)
        guard current(generation) else { return }
        guard let submitted = await session.submitHomeAction(phrase) else {
            guard current(generation) else { return }
            if session.unreachable {
                applianceNotice = session.notice
                markOffline()
            } else if !session.notice.isEmpty {
                applianceNotice = session.notice
            }
            return
        }
        var receipt = submitted
        if receipt.status == "queued" || receipt.status == "running" {
            guard let finished = await pollAppliance(session, receipt.turnID, generation) else {
                guard current(generation) else { return }
                if session.unreachable {
                    applianceNotice = session.notice
                    apply(ApplianceSight(link: .offline, detail: "Offline"), to: appliance.id)
                }
                return
            }
            receipt = finished
        }
        guard current(generation) else { return }
        if receipt.status == "queued" || receipt.status == "running" {
            apply(ApplianceSight(link: nil, detail: "Still waiting."), to: appliance.id)
            return
        }
        let sight = ApplianceCatalog.sight(
            in: receipt,
            slot: appliance.slot,
            deviceID: appliance.deviceID
        )
        apply(sight, to: appliance.id)
        if receipt.status == "failed" || receipt.status == "awaiting_approval" {
            applianceNotice = sight.detail
        } else if session.unreachable {
            applianceNotice = session.notice
        } else {
            applianceNotice = ""
        }
    }

    private func pollAppliance(
        _ session: WatchSession,
        _ id: String,
        _ generation: Int
    ) async -> VoiceTurnReceipt? {
        var latest: VoiceTurnReceipt?
        var remaining = 40
        while remaining > 0 && current(generation) {
            remaining -= 1
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard current(generation) else { return latest }
            guard let receipt = await session.pollVoice(id: id) else { return latest }
            latest = receipt
            if receipt.status != "queued" && receipt.status != "running" {
                return receipt
            }
        }
        return latest
    }

    private func waitUntilVoiceIdle(_ generation: Int) async {
        var spins = 0
        while session?.voiceInFlight == true, spins < 160, current(generation) {
            spins += 1
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func nextHouseGeneration() -> Int {
        houseGeneration += 1
        return houseGeneration
    }

    private func current(_ generation: Int) -> Bool {
        generation == houseGeneration && !Task.isCancelled
    }

    private func markChecking(_ id: String, _ generation: Int) {
        guard current(generation), let index = appliances.firstIndex(where: { $0.id == id }) else { return }
        if appliances[index].detail.isEmpty {
            appliances[index].detail = "Checking"
        }
    }

    private func markOffline() {
        for index in appliances.indices {
            appliances[index].link = .offline
            if appliances[index].detail.isEmpty || appliances[index].detail == "Checking" {
                appliances[index].detail = "Offline"
            }
        }
    }

    private func apply(_ sight: ApplianceSight, to id: String) {
        guard let index = appliances.firstIndex(where: { $0.id == id }) else { return }
        if let link = sight.link {
            appliances[index].link = link
        }
        if !sight.detail.isEmpty {
            appliances[index].detail = sight.detail
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

struct ApplianceCard: Identifiable, Equatable {
    var appliance: BoundAppliance
    var link: ApplianceLink
    var detail: String

    var id: String { appliance.id }
}
