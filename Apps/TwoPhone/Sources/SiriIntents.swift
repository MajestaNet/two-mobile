// Copyright 2026 MajestaNet
// SPDX-License-Identifier: Apache-2.0

import AppIntents
import Foundation
import TwoClient

extension Notification.Name {
    static let twoSiriApproval = Notification.Name("two.siri.open-approval")
}

struct TwoApplianceEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Appliance")
    static var defaultQuery = TwoApplianceQuery()

    var id: String
    var title: String
    var aliases: [String]

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

struct TwoApplianceQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [TwoApplianceEntity.ID]) async throws -> [TwoApplianceEntity] {
        let all = try await Self.load()
        return all.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [TwoApplianceEntity] {
        try await Self.load()
    }

    func entities(matching string: String) async throws -> [TwoApplianceEntity] {
        let menu = try await Self.menu()
        return ApplianceCatalog.appliances(in: menu).filter { appliance in
            ApplianceCatalog.matchesSpoken(appliance, string)
        }.map(Self.entity)
    }

    private static func load() async throws -> [TwoApplianceEntity] {
        ApplianceCatalog.appliances(in: try await menu()).map(entity)
    }

    private static func menu() async throws -> AdapterMenu {
        try await SiriPerformer.menu()
    }

    private static func entity(_ appliance: BoundAppliance) -> TwoApplianceEntity {
        TwoApplianceEntity(id: appliance.id, title: appliance.title, aliases: appliance.aliases)
    }
}

enum SiriPerformer {
    static func menu() async throws -> AdapterMenu {
        try await api().adapters()
    }

    static func dialog<Intent: AppIntent & ForegroundContinuableIntent>(
        _ kind: SiriKind,
        intent: Intent
    ) async -> IntentDialog {
        let speech = await speech(for: kind)
        if speech.opensApproval {
            let prompt = IntentDialog(stringLiteral: speech.dialog)
            if #available(iOS 26.0, *) {
                try? await intent.continueInForeground(prompt, alwaysConfirm: false)
            } else {
                try? await intent.requestToContinueInForeground(prompt)
            }
            if let turnID = speech.turnID {
                await MainActor.run {
                    NotificationCenter.default.post(name: .twoSiriApproval, object: turnID)
                }
            }
        }
        return IntentDialog(stringLiteral: speech.dialog)
    }

    private static func speech(for kind: SiriKind) async -> SiriSpeech {
        do {
            let client = try api()
            let listed = try await client.adapters()
            let resolution = SiriPhrases.resolve(kind, menu: listed)
            guard case .submit(let submission) = resolution else {
                return SiriSpeech(resolution)
            }
            return await SiriExchange.complete(
                submission: submission,
                submit: { text, profile in
                    try await client.submitVoiceTurn(text: text, profile: profile)
                },
                refresh: { id in
                    try await client.voiceTurn(id: id)
                }
            )
        } catch let failure as WatchFailure {
            return SiriSpeech(failure)
        } catch SiriLaunchError.noAccessGroup {
            return SiriSpeech(
                dialog: "Select a Development Team so the keychain access group can be signed.",
                opensApproval: false,
                turnID: nil
            )
        } catch {
            return SiriSpeech(
                dialog: "Enroll Two on this iPhone first.",
                opensApproval: false,
                turnID: nil
            )
        }
    }

    private static func api() throws -> WatchAPI {
        guard let accessGroup = AccessGroup.resolved() else { throw SiriLaunchError.noAccessGroup }
        guard let enrollment = try WatchKeychain.loadEnrollment(accessGroup: accessGroup) else {
            throw SiriLaunchError.notEnrolled
        }
        return WatchAPI.makeLive(
            endpoint: enrollment.endpoint,
            pinnedCertificate: enrollment.pinnedCertificate,
            accessGroup: accessGroup,
            also: enrollment.alternates
        )
    }
}

private enum SiriLaunchError: Error {
    case noAccessGroup
    case notEnrolled
}

struct AskTwoIntent: AppIntent, ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Ask Two"
    static var openAppWhenRun: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @Parameter(title: "Request", requestValueDialog: "What should I ask?")
    var request: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Two \(\.$request)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: await SiriPerformer.dialog(.ask(request), intent: self))
    }
}

struct TurnOffApplianceIntent: AppIntent, ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Turn an appliance off"
    static var openAppWhenRun: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @Parameter(title: "Appliance")
    var appliance: TwoApplianceEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Turn \(\.$appliance) off")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: await SiriPerformer.dialog(.off(appliance.id), intent: self))
    }
}

struct TurnOnApplianceIntent: AppIntent, ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Turn an appliance on"
    static var openAppWhenRun: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @Parameter(title: "Appliance")
    var appliance: TwoApplianceEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Turn \(\.$appliance) on")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: await SiriPerformer.dialog(.on(appliance.id), intent: self))
    }
}

struct HeatApplianceIntent: AppIntent, ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Heat a room"
    static var openAppWhenRun: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @Parameter(title: "Appliance")
    var appliance: TwoApplianceEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Heat \(\.$appliance)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: await SiriPerformer.dialog(.heat(appliance.id), intent: self))
    }
}

struct CoolApplianceIntent: AppIntent, ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Cool a room"
    static var openAppWhenRun: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @Parameter(title: "Appliance")
    var appliance: TwoApplianceEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Cool \(\.$appliance)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: await SiriPerformer.dialog(.cool(appliance.id), intent: self))
    }
}

struct SetClimateSetpointIntent: AppIntent, ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Set a temperature"
    static var openAppWhenRun: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @Parameter(title: "Appliance")
    var appliance: TwoApplianceEntity

    @Parameter(title: "Degrees", requestValueDialog: "How many degrees?")
    var degrees: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$appliance) to \(\.$degrees)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: await SiriPerformer.dialog(.setpoint(appliance.id, degrees), intent: self))
    }
}

struct StartVacuumIntent: AppIntent, ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Start the vacuum"
    static var openAppWhenRun: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @Parameter(title: "Appliance")
    var appliance: TwoApplianceEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Start \(\.$appliance)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: await SiriPerformer.dialog(.start(appliance.id), intent: self))
    }
}

struct DockVacuumIntent: AppIntent, ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Dock the vacuum"
    static var openAppWhenRun: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @Parameter(title: "Appliance")
    var appliance: TwoApplianceEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Dock \(\.$appliance)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: await SiriPerformer.dialog(.dock(appliance.id), intent: self))
    }
}

struct ReadApplianceIntent: AppIntent, ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Check an appliance"
    static var openAppWhenRun: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @Parameter(title: "Appliance")
    var appliance: TwoApplianceEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Check \(\.$appliance)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: await SiriPerformer.dialog(.read(appliance.id), intent: self))
    }
}

struct TwoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskTwoIntent(),
            phrases: [
                "Ask \(.applicationName)",
            ],
            shortTitle: "Ask Two",
            systemImageName: "mic"
        )
        AppShortcut(
            intent: TurnOffApplianceIntent(),
            phrases: [
                "Turn \(\.$appliance) off with \(.applicationName)",
            ],
            shortTitle: "Turn off",
            systemImageName: "power"
        )
        AppShortcut(
            intent: TurnOnApplianceIntent(),
            phrases: [
                "Turn \(\.$appliance) on with \(.applicationName)",
            ],
            shortTitle: "Turn on",
            systemImageName: "power"
        )
        AppShortcut(
            intent: HeatApplianceIntent(),
            phrases: [
                "Heat \(\.$appliance) with \(.applicationName)",
            ],
            shortTitle: "Heat",
            systemImageName: "thermometer.sun"
        )
        AppShortcut(
            intent: CoolApplianceIntent(),
            phrases: [
                "Cool \(\.$appliance) with \(.applicationName)",
            ],
            shortTitle: "Cool",
            systemImageName: "thermometer.snowflake"
        )
        AppShortcut(
            intent: SetClimateSetpointIntent(),
            phrases: [
                "Set \(\.$appliance) with \(.applicationName)",
            ],
            shortTitle: "Set temperature",
            systemImageName: "thermometer.medium"
        )
        AppShortcut(
            intent: StartVacuumIntent(),
            phrases: [
                "Start \(\.$appliance) with \(.applicationName)",
            ],
            shortTitle: "Start vacuum",
            systemImageName: "play"
        )
        AppShortcut(
            intent: DockVacuumIntent(),
            phrases: [
                "Dock \(\.$appliance) with \(.applicationName)",
            ],
            shortTitle: "Dock vacuum",
            systemImageName: "house"
        )
        AppShortcut(
            intent: ReadApplianceIntent(),
            phrases: [
                "Ask \(.applicationName) about \(\.$appliance)",
            ],
            shortTitle: "Check appliance",
            systemImageName: "info.circle"
        )
    }
}
