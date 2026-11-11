// Copyright 2026 MajestaNet
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A Siri shortcut, before it becomes a voice-turn transcript.
public enum SiriKind: Equatable, Sendable {
    case ask(String)
    case off(String)
    case on(String)
    case heat(String)
    case cool(String)
    case setpoint(String, Int)
    case start(String)
    case dock(String)
    case read(String)
}

public enum SiriResolution: Equatable, Sendable {
    case submit(VoiceSubmission)
    case empty
    case unbound
    case unsupported
    case temperatureOutOfRange
}

public enum SiriPhrases {
    /// Maps a shortcut onto the transcript the house buttons already send.
    public static func resolve(_ kind: SiriKind, menu: AdapterMenu) -> SiriResolution {
        switch kind {
        case .ask(let words):
            guard let submission = UtteranceRouting.submission(from: words) else { return .empty }
            return .submit(submission)
        case .off(let id):
            return appliance(id, menu: menu, verb: .off)
        case .on(let id):
            return appliance(id, menu: menu, verb: .on)
        case .heat(let id):
            return appliance(id, menu: menu, verb: .heat)
        case .cool(let id):
            return appliance(id, menu: menu, verb: .cool)
        case .start(let id):
            return appliance(id, menu: menu, verb: .start)
        case .dock(let id):
            return appliance(id, menu: menu, verb: .station)
        case .read(let id):
            return appliance(id, menu: menu, verb: .read)
        case .setpoint(let id, let celsius):
            guard (0...50).contains(celsius) else { return .temperatureOutOfRange }
            guard let appliance = bound(id, menu: menu) else { return .unbound }
            guard let phrase = ApplianceCatalog.setpointPhrase(appliance, celsius: celsius) else {
                return .unsupported
            }
            return .submit(VoiceSubmission(text: phrase, profile: nil))
        }
    }

    private static func appliance(
        _ id: String,
        menu: AdapterMenu,
        verb: ApplianceVerb
    ) -> SiriResolution {
        guard let appliance = bound(id, menu: menu) else { return .unbound }
        guard let phrase = ApplianceCatalog.phrase(appliance, verb) else { return .unsupported }
        return .submit(VoiceSubmission(text: phrase, profile: nil))
    }

    private static func bound(_ id: String, menu: AdapterMenu) -> BoundAppliance? {
        ApplianceCatalog.appliances(in: menu).first { $0.id == id }
    }
}

public struct SiriSpeech: Equatable, Sendable {
    public let dialog: String
    public let opensApproval: Bool
    public let turnID: String?

    public init(dialog: String, opensApproval: Bool, turnID: String?) {
        self.dialog = dialog
        self.opensApproval = opensApproval
        self.turnID = turnID
    }

    public init(_ resolution: SiriResolution) {
        opensApproval = false
        turnID = nil
        switch resolution {
        case .submit:
            dialog = "Sent to Two."
        case .empty:
            dialog = "The request was empty."
        case .unbound:
            dialog = "That appliance is not bound."
        case .unsupported:
            dialog = "That appliance cannot do that."
        case .temperatureOutOfRange:
            dialog = "Say a whole number from 0 to 50."
        }
    }

    public init(_ failure: WatchFailure) {
        dialog = failure.screenText
        opensApproval = false
        turnID = nil
    }

    public init(_ receipt: VoiceTurnReceipt) {
        turnID = receipt.turnID
        if receipt.status == "awaiting_approval" {
            dialog = "That needs a decision on the phone."
            opensApproval = receipt.actionDigest != nil
            return
        }
        if receipt.errorCode == "fanout_needs_approval" {
            dialog = "That needs a decision on the phone."
            opensApproval = false
            return
        }
        if receipt.status == "queued" || receipt.status == "running" {
            dialog = "Two is still working."
            opensApproval = false
            return
        }
        if receipt.status == "failed" {
            dialog = "The turn failed."
            opensApproval = false
            return
        }
        if let line = receipt.displayLine, receipt.climate != nil || receipt.tv != nil || receipt.vacuum != nil || !receipt.fanout.isEmpty {
            dialog = line
            opensApproval = false
            return
        }
        if receipt.profile == VoiceProfile.chat.rawValue,
           receipt.status == "complete",
           let reply = receipt.reply,
           !reply.isEmpty {
            dialog = SiriSpeech.spokenReply(reply)
            opensApproval = false
            return
        }
        if receipt.status == "complete" {
            dialog = receipt.displayLine ?? "Done."
            opensApproval = false
            return
        }
        dialog = "Sent to Two."
        opensApproval = false
    }

    /// HomePod has no screen. Keep a long chat answer speakable.
    static func spokenReply(_ reply: String) -> String {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 500 else { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: 500)
        return String(trimmed[..<end]) + "…"
    }
}

public enum SiriExchange {
    public static let pauseCount = 8

    public static func complete(
        submission: VoiceSubmission,
        submit: (String, VoiceProfile?) async throws -> VoiceTurnReceipt,
        refresh: (String) async throws -> VoiceTurnReceipt,
        pause: @Sendable () async -> Void = {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    ) async -> SiriSpeech {
        let receipt: VoiceTurnReceipt
        do {
            receipt = try await submit(submission.text, submission.profile)
        } catch let failure as WatchFailure {
            return SiriSpeech(failure)
        } catch {
            return SiriSpeech(WatchFailure.unreachable)
        }
        return await settle(receipt, refresh: refresh, pause: pause, remaining: pauseCount)
    }

    static func settle(
        _ receipt: VoiceTurnReceipt,
        refresh: (String) async throws -> VoiceTurnReceipt,
        pause: @Sendable () async -> Void,
        remaining: Int
    ) async -> SiriSpeech {
        var current = receipt
        var left = remaining
        while (current.status == "queued" || current.status == "running"), left > 0 {
            left -= 1
            await pause()
            do {
                current = try await refresh(current.turnID)
            } catch let failure as WatchFailure {
                return SiriSpeech(failure)
            } catch {
                return SiriSpeech(WatchFailure.unreachable)
            }
        }
        return SiriSpeech(current)
    }
}
