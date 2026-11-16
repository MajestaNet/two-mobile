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
    private var startupTask: Task<Void, Never>?
    private var applianceSweep: Task<Void, Never>?
    private var appliancesLoadedAt: Date?

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
            appliances = ApplianceCache.load()
            startupTask = Task { await checkExisting() }
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
            ApplianceCache.clear()
            appliances = []
            appliancesReady = false
            appliancesLoadedAt = nil
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
            warmAppliances()
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
        appliancesLoadedAt = nil
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

    func presentVoiceTurn(_ turnID: String) async {
        if session == nil { bootstrap() }
        guard let session else {
            status = "Enroll Two on this iPhone first."
            return
        }
        if session.capabilities == nil {
            await session.checkCapabilities()
        }
        await session.refreshVoice(id: turnID)
    }

    func decideVoice(_ decision: ApprovalDecision) {
        guard let session, let approval = session.voiceApproval, !session.deciding else { return }
        Task { await session.decideVoice(approval, decision: decision, foreground: true) }
    }

    func refreshIfNeeded() async {
        if let startupTask {
            await startupTask.value
            self.startupTask = nil
        }
        guard session != nil, session?.principalMatches != true else { return }
        await checkExisting()
    }

    /// Opens the device list. A sweep that is already running, or one that just finished, stays put.
    func showAppliances() async {
        if checkingAppliances {
            await applianceSweep?.value
            return
        }
        if appliancesReady, let appliancesLoadedAt, Date().timeIntervalSince(appliancesLoadedAt) < 30 {
            return
        }
        await refreshAppliances()
    }

    func refreshAppliances() async {
        let generation = nextHouseGeneration()
        checkingAppliances = true
        let task = Task { await reloadAppliances(generation) }
        applianceSweep = task
        await task.value
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
            return
        }
        guard session.principalMatches else { return }
        warmAppliances()
    }

    /// Starts the status sweep while the globe is still on screen.
    private func warmAppliances() {
        guard showsGlobe, !checkingAppliances else { return }
        if appliancesReady, let appliancesLoadedAt, Date().timeIntervalSince(appliancesLoadedAt) < 30 {
            return
        }
        checkingAppliances = true
        let generation = nextHouseGeneration()
        applianceSweep = Task { await reloadAppliances(generation) }
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
        guard let session, showsGlobe, current(generation) else {
            if current(generation) { checkingAppliances = false }
            return
        }
        checkingAppliances = true
        defer {
            if current(generation) {
                checkingAppliances = false
                appliancesReady = true
                if !session.unreachable {
                    appliancesLoadedAt = Date()
                }
                ApplianceCache.save(appliances)
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
        TwoShortcuts.updateAppShortcutParameters()
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
        await runTurn(phrase, appliance: appliance, generation: generation, quiet: true)
    }

    private func command(_ verb: ApplianceVerb, _ card: ApplianceCard, _ generation: Int) async {
        defer {
            if busyApplianceID == card.id { busyApplianceID = nil }
        }
        guard let session, showsGlobe, session.showsHomeAction else { return }
        guard let phrase = ApplianceCatalog.phrase(card.appliance, verb) else { return }
        await runTurn(phrase, appliance: card.appliance, generation: generation, quiet: false)
    }

    private func runTurn(_ phrase: String, appliance: BoundAppliance, generation: Int, quiet: Bool) async {
        guard let session else { return }
        await waitUntilVoiceIdle(generation)
        guard current(generation) else { return }
        let submitted: VoiceTurnReceipt
        if quiet {
            switch await session.readHomeAction(phrase) {
            case .success(let receipt):
                submitted = receipt
            case .failure(let failure):
                guard current(generation) else { return }
                noteProbe(failure)
                return
            }
        } else if let receipt = await session.submitHomeAction(phrase) {
            submitted = receipt
        } else {
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
            let polled = await pollAppliance(session, receipt.turnID, generation, quiet: quiet)
            guard let finished = polled.receipt else {
                guard current(generation) else { return }
                if let failure = polled.failure {
                    if quiet {
                        noteProbe(failure, only: appliance.id)
                    } else if session.unreachable {
                        applianceNotice = session.notice
                        apply(ApplianceSight(link: .offline, detail: "Offline"), to: appliance.id)
                    }
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
        } else if !quiet && session.unreachable {
            applianceNotice = session.notice
        } else if quiet || !session.unreachable {
            applianceNotice = ""
        }
    }

    private func pollAppliance(
        _ session: WatchSession,
        _ id: String,
        _ generation: Int,
        quiet: Bool
    ) async -> (receipt: VoiceTurnReceipt?, failure: WatchFailure?) {
        var latest: VoiceTurnReceipt?
        var remaining = 40
        var pause: UInt64 = 200_000_000
        while remaining > 0 && current(generation) {
            remaining -= 1
            try? await Task.sleep(nanoseconds: pause)
            if pause < 500_000_000 {
                pause += 100_000_000
            }
            guard current(generation) else { return (latest, nil) }
            if quiet {
                switch await session.readVoice(id) {
                case .success(let receipt):
                    latest = receipt
                case .failure(let failure):
                    return (latest, failure)
                }
            } else if let receipt = await session.pollVoice(id: id) {
                latest = receipt
            } else {
                return (latest, session.unreachable ? .unreachable : nil)
            }
            if let latest, latest.status != "queued", latest.status != "running" {
                return (latest, nil)
            }
        }
        return (latest, nil)
    }

    private func noteProbe(_ failure: WatchFailure, only id: String? = nil) {
        applianceNotice = failure.screenText
        if failure.isUnreachable {
            if let id {
                apply(ApplianceSight(link: .offline, detail: "Offline"), to: id)
            } else {
                markOffline()
            }
        }
        guard failure.isUnauthorized else { return }
        let note = failure.screenText
        forgetSession()
        status = note
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
        appliances = []
        appliancesReady = false
        appliancesLoadedAt = nil
        ApplianceCache.clear()
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

private enum ApplianceCache {
    private static let key = "two.phone.appliance-snapshot"

    private struct Row: Codable {
        var slot: String
        var deviceID: String
        var aliases: [String]
        var link: String
        var detail: String
    }

    static func load() -> [ApplianceCard] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let rows = try? JSONDecoder().decode([Row].self, from: data) else {
            return []
        }
        return rows.compactMap { row in
            guard !row.slot.isEmpty, !row.deviceID.isEmpty else { return nil }
            return ApplianceCard(
                appliance: BoundAppliance(slot: row.slot, deviceID: row.deviceID, aliases: row.aliases),
                link: link(row.link),
                detail: row.detail
            )
        }
    }

    static func save(_ cards: [ApplianceCard]) {
        if cards.isEmpty {
            clear()
            return
        }
        let rows = cards.compactMap { card -> Row? in
            if card.detail == "Checking" || card.detail == "Still waiting." { return nil }
            return Row(
                slot: card.appliance.slot,
                deviceID: card.appliance.deviceID,
                aliases: card.appliance.aliases,
                link: stored(card.link),
                detail: card.detail
            )
        }
        guard !rows.isEmpty, let data = try? JSONEncoder().encode(rows) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func stored(_ link: ApplianceLink) -> String {
        switch link {
        case .online: "online"
        case .offline: "offline"
        case .unknown: "unknown"
        }
    }

    private static func link(_ stored: String) -> ApplianceLink {
        switch stored {
        case "online": .online
        case "offline": .offline
        default: .unknown
        }
    }
}
