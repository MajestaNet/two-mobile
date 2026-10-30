// Copyright 2026 MajestaNet
// SPDX-License-Identifier: Apache-2.0

import Combine
import Foundation

public struct HousePicture: Equatable, Sendable {
    public let healthLine: String
    public let queueLine: String
    public let notice: String
    public let correlationID: String?
}

public struct ApprovalPicture: Equatable, Sendable {
    public enum Body: Equatable, Sendable {
        case needsRefresh
        case missingScope
        case empty
        case unreachable
        case task(OpenApproval)
        case voice(VoiceApproval)
    }

    public let body: Body
    /// The digest is shown as text. It is not an editable field.
    public var digestEditable: Bool { false }
}

@MainActor
public final class WatchSession: ObservableObject {
    /// Decisions are not stored for a later network. This stays zero.
    public let queuedDecisionCount = 0

    @Published public private(set) var capabilities: Capabilities?
    @Published public private(set) var health: SystemHealth?
    @Published public private(set) var queue: SystemQueue?
    @Published public private(set) var approvals: [OpenApproval] = []
    @Published public private(set) var voiceApproval: VoiceApproval?
    @Published public private(set) var notice = ""
    @Published public private(set) var correlationID: String?
    @Published public private(set) var unreachable = false
    @Published public private(set) var confirmationTranscript = ""
    @Published public private(set) var replyText: String?
    @Published public private(set) var voiceInFlight = false
    @Published public private(set) var deciding = false

    public var canDecide: Bool { capabilities?.canDecide == true }
    public var showsChat: Bool { capabilities?.allows(.chat) == true }
    public var showsHomeAction: Bool { capabilities?.allows(.homeAction) == true }
    public var principalMatches: Bool { capabilities?.principal == WatchPrincipal.expected }

    private let api: WatchAPI

    public init(api: WatchAPI) {
        self.api = api
    }

    public func housePicture() -> HousePicture {
        if unreachable {
            return HousePicture(
                healthLine: "The mini is unreachable.",
                queueLine: "",
                notice: notice,
                correlationID: correlationID
            )
        }
        if let capabilities, !capabilities.canReadSystem {
            return HousePicture(
                healthLine: "system:read is not granted.",
                queueLine: "",
                notice: notice,
                correlationID: correlationID
            )
        }
        let healthLine: String
        if let health {
            healthLine = health.stale ? "Health is stale (\(health.status))." : "Health \(health.status)."
        } else {
            healthLine = "No health yet."
        }
        let queueLine: String
        if let queue {
            queueLine = queue.isEmpty ? "The queue is empty." : "Queue depth \(queue.depth)."
        } else {
            queueLine = "No queue yet."
        }
        return HousePicture(
            healthLine: healthLine,
            queueLine: queueLine,
            notice: notice,
            correlationID: correlationID
        )
    }

    public func approvalPicture() -> ApprovalPicture {
        if unreachable { return ApprovalPicture(body: .unreachable) }
        if let capabilities, !capabilities.canDecide {
            return ApprovalPicture(body: .missingScope)
        }
        if let voiceApproval { return ApprovalPicture(body: .voice(voiceApproval)) }
        if let first = approvals.first { return ApprovalPicture(body: .task(first)) }
        if capabilities == nil { return ApprovalPicture(body: .needsRefresh) }
        return ApprovalPicture(body: .empty)
    }

    public func checkCapabilities() async {
        do {
            let next = try await api.capabilities()
            capabilities = next
            unreachable = false
            correlationID = nil
            if next.principal == WatchPrincipal.expected {
                notice = "Principal \(next.principal)."
            } else {
                notice = "Principal is \(next.principal). Expected \(WatchPrincipal.expected)."
            }
        } catch let failure as WatchFailure {
            apply(failure)
        } catch {
            apply(.unreachable)
        }
    }

    public func refreshHouse() async {
        if capabilities == nil { await checkCapabilities() }
        guard capabilities?.canReadSystem == true else { return }
        do {
            health = try await api.health()
            queue = try await api.queue()
            unreachable = false
        } catch let failure as WatchFailure {
            apply(failure)
        } catch {
            apply(.unreachable)
        }
    }

    public func refreshApprovals() async {
        if capabilities == nil { await checkCapabilities() }
        guard capabilities?.canReadTasks == true else {
            approvals = []
            if capabilities != nil {
                notice = "tasks:read is not granted."
            }
            return
        }
        do {
            approvals = try await api.openApprovals()
            unreachable = false
        } catch let failure as WatchFailure {
            apply(failure)
        } catch {
            apply(.unreachable)
        }
    }

    public func sendTranscript(_ text: String, profile: VoiceProfile?, foreground: Bool) async {
        guard foreground, !voiceInFlight else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        confirmationTranscript = trimmed
        guard !trimmed.isEmpty else {
            notice = WatchFailure.validation(correlationID: nil).screenText
            return
        }
        if let profile, capabilities?.allows(profile) == false {
            notice = WatchFailure.forbidden(detail: "", correlationID: nil).screenText
            return
        }
        voiceInFlight = true
        defer { voiceInFlight = false }
        do {
            let receipt = try await api.submitVoiceTurn(text: trimmed, profile: profile)
            apply(receipt)
        } catch let failure as WatchFailure {
            apply(failure)
        } catch {
            apply(.unreachable)
        }
    }

    public func refreshVoice(id: String) async {
        do {
            apply(try await api.voiceTurn(id: id))
        } catch let failure as WatchFailure {
            apply(failure)
        } catch {
            apply(.unreachable)
        }
    }

    public func decide(_ approval: OpenApproval, decision: ApprovalDecision, foreground: Bool) async {
        guard foreground, canDecide, !deciding else { return }
        deciding = true
        defer { deciding = false }
        do {
            _ = try await api.decide(approval: approval, decision: decision)
            unreachable = false
            correlationID = nil
            notice = decision == .approve ? "Approved." : "Rejected."
            await refreshApprovals()
        } catch let failure as WatchFailure {
            apply(failure)
            if case .staleDigest = failure {
                await refreshApprovals()
            }
        } catch {
            apply(.unreachable)
        }
    }

    public func decideVoice(_ approval: VoiceApproval, decision: ApprovalDecision, foreground: Bool) async {
        guard foreground, canDecide, !deciding else { return }
        deciding = true
        defer { deciding = false }
        do {
            let receipt = try await api.decideVoiceTurn(
                id: approval.turnID,
                decision: decision,
                digest: approval.actionDigest
            )
            apply(receipt)
        } catch let failure as WatchFailure {
            apply(failure)
        } catch {
            apply(.unreachable)
        }
    }

    public func leaveTalkScreen() {
        confirmationTranscript = ""
        replyText = nil
    }

    private func apply(_ receipt: VoiceTurnReceipt) {
        unreachable = false
        correlationID = nil
        replyText = receipt.replyForDisplay
        voiceApproval = receipt.voiceApproval
        notice = receipt.statusLine
    }

    private func apply(_ failure: WatchFailure) {
        notice = failure.screenText
        correlationID = failure.correlationID
        unreachable = failure.isUnreachable
    }
}
