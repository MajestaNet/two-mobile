// Copyright 2026 MajestaNet
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum WatchPrincipal {
    public static let expected = "client:watch"
}

public enum VoiceProfile: String, Codable, Equatable, Sendable {
    case chat
    case homeAction = "home-action"
}

public enum ApprovalDecision: String, Equatable, Sendable {
    case approve
    case reject
}

public struct Capabilities: Decodable, Equatable, Sendable {
    public let principal: String
    public let scopes: [String]
    public let allowedHarnessProfiles: [String]
    public let auth: AuthCapabilities

    public var canDecide: Bool { scopes.contains("approvals:decide") }
    public var canReadSystem: Bool { scopes.contains("system:read") }
    public var canReadTasks: Bool { scopes.contains("tasks:read") }

    public func allows(_ profile: VoiceProfile) -> Bool {
        allowedHarnessProfiles.contains(profile.rawValue)
    }

    enum CodingKeys: String, CodingKey {
        case principal
        case scopes
        case allowedHarnessProfiles = "allowed_harness_profiles"
        case auth
    }
}

public struct AuthCapabilities: Decodable, Equatable, Sendable {
    public let method: String
    public let oidcAvailable: Bool
    public let mobileReady: Bool
    public let edgeAvailable: Bool

    enum CodingKeys: String, CodingKey {
        case method
        case oidcAvailable = "oidc_available"
        case mobileReady = "mobile_ready"
        case edgeAvailable = "edge_available"
    }
}

public struct ClimateReadback: Decodable, Equatable, Sendable {
    public let zone: String
    public let setpointCelsius: Double?
    public let reachable: Bool

    enum CodingKeys: String, CodingKey {
        case zone
        case setpointCelsius = "setpoint_celsius"
        case reachable
    }
}

public struct TVReadback: Decodable, Equatable, Sendable {
    public let setName: String
    public let power: String
    public let reachable: Bool

    enum CodingKeys: String, CodingKey {
        case setName = "set"
        case power
        case reachable
    }
}

public struct VacuumReadback: Decodable, Equatable, Sendable {
    public let robot: String
    public let activity: String
    public let reachable: Bool
}

public struct ClimatePending: Decodable, Equatable, Sendable {
    public let tool: String
    public let zone: String
}

public struct TVPending: Decodable, Equatable, Sendable {
    public let tool: String
    public let setName: String

    enum CodingKeys: String, CodingKey {
        case tool
        case setName = "set"
    }
}

public struct InstallPending: Decodable, Equatable, Sendable {
    public let tool: String
    public let summary: String
}

public struct FanoutItem: Decodable, Equatable, Sendable {
    public let slot: String
    public let target: String
    public let status: String
}

public struct VoiceTurnReceipt: Decodable, Equatable, Sendable {
    public let turnID: String
    public let profile: String
    public let status: String
    public let reply: String?
    public let errorCode: String?
    public let actionDigest: String?
    public let climate: ClimateReadback?
    public let tv: TVReadback?
    public let vacuum: VacuumReadback?
    public let pendingAction: ClimatePending?
    public let pendingTV: TVPending?
    public let pendingInstall: InstallPending?
    public let fanout: [FanoutItem]
    public let routeSlots: [String]
    public let cursor: String
    public let revision: Int

    public var replyForDisplay: String? {
        status == "complete" ? reply : nil
    }

    public var displayLine: String? {
        if let climate {
            if let setpoint = climate.setpointCelsius {
                let value = setpoint.rounded() == setpoint
                    ? String(Int(setpoint))
                    : String(setpoint)
                return "\(climate.zone) \(value)°"
            }
            return climate.zone
        }
        if let tv {
            return "\(tv.setName) \(tv.power)"
        }
        if let vacuum {
            return "\(vacuum.robot) \(vacuum.activity)"
        }
        if !fanout.isEmpty {
            return fanout.map { "\($0.target) \($0.status)" }.joined(separator: ", ")
        }
        switch status {
        case "complete":
            return reply
        case "awaiting_approval":
            return "Needs a decision on the watch."
        case "failed":
            return "The turn failed."
        default:
            return nil
        }
    }

    public var voiceApproval: VoiceApproval? {
        guard status == "awaiting_approval", let actionDigest else { return nil }
        return VoiceApproval(turnID: turnID, actionDigest: actionDigest, summary: pendingSummary)
    }

    public var statusLine: String {
        let base: String
        switch status {
        case "queued", "running", "complete":
            base = "Stored."
        case "awaiting_approval":
            base = "Needs a decision."
        case "failed":
            base = "The turn failed."
        default:
            base = status
        }
        if routeSlots.isEmpty { return base }
        return base + " " + routeSlots.joined(separator: ", ")
    }

    private var pendingSummary: String {
        if let pendingAction { return "\(pendingAction.tool) \(pendingAction.zone)" }
        if let pendingTV { return "\(pendingTV.tool) \(pendingTV.setName)" }
        if let pendingInstall { return pendingInstall.summary }
        return "Pending"
    }

    enum CodingKeys: String, CodingKey {
        case turnID = "turn_id"
        case profile
        case status
        case reply
        case errorCode = "error_code"
        case actionDigest = "action_digest"
        case climate
        case tv
        case vacuum
        case pendingAction = "pending_action"
        case pendingTV = "pending_tv"
        case pendingInstall = "pending_install"
        case fanout
        case routeSlots = "route_slots"
        case cursor
        case revision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        turnID = try container.decode(String.self, forKey: .turnID)
        profile = try container.decode(String.self, forKey: .profile)
        status = try container.decode(String.self, forKey: .status)
        let rawReply = try container.decodeIfPresent(String.self, forKey: .reply)
        reply = status == "complete" ? rawReply : nil
        errorCode = try container.decodeIfPresent(String.self, forKey: .errorCode)
        actionDigest = try container.decodeIfPresent(String.self, forKey: .actionDigest)
        climate = try container.decodeIfPresent(ClimateReadback.self, forKey: .climate)
        tv = try container.decodeIfPresent(TVReadback.self, forKey: .tv)
        vacuum = try container.decodeIfPresent(VacuumReadback.self, forKey: .vacuum)
        pendingAction = try container.decodeIfPresent(ClimatePending.self, forKey: .pendingAction)
        pendingTV = try container.decodeIfPresent(TVPending.self, forKey: .pendingTV)
        pendingInstall = try container.decodeIfPresent(InstallPending.self, forKey: .pendingInstall)
        fanout = try container.decodeIfPresent([FanoutItem].self, forKey: .fanout) ?? []
        routeSlots = try container.decodeIfPresent([String].self, forKey: .routeSlots) ?? []
        cursor = try container.decode(String.self, forKey: .cursor)
        revision = try container.decode(Int.self, forKey: .revision)
    }
}

public struct VoiceApproval: Equatable, Sendable, Identifiable {
    public let turnID: String
    public let actionDigest: String
    public let summary: String
    public var id: String { turnID }

    public init(turnID: String, actionDigest: String, summary: String) {
        self.turnID = turnID
        self.actionDigest = actionDigest
        self.summary = summary
    }
}

public struct OpenApproval: Equatable, Sendable, Identifiable {
    public let taskID: String
    public let approvalID: String
    public let actionClass: String
    public let actionDigest: String
    public let paths: [String]
    public var id: String { "\(taskID)/\(approvalID)" }

    public init(
        taskID: String,
        approvalID: String,
        actionClass: String,
        actionDigest: String,
        paths: [String]
    ) {
        self.taskID = taskID
        self.approvalID = approvalID
        self.actionClass = actionClass
        self.actionDigest = actionDigest
        self.paths = paths
    }
}

public struct DecideResult: Decodable, Equatable, Sendable {
    public let taskID: String
    public let approvalID: String
    public let decision: String
    public let actionDigest: String
    public let principal: String
    public let ignored: Bool

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case approvalID = "approval_id"
        case decision
        case actionDigest = "action_digest"
        case principal
        case ignored
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taskID = try container.decode(String.self, forKey: .taskID)
        approvalID = try container.decode(String.self, forKey: .approvalID)
        decision = try container.decode(String.self, forKey: .decision)
        actionDigest = try container.decode(String.self, forKey: .actionDigest)
        principal = try container.decode(String.self, forKey: .principal)
        ignored = try container.decodeIfPresent(Bool.self, forKey: .ignored) ?? false
    }
}

public struct TaskDiff: Decodable, Equatable, Sendable, CustomStringConvertible {
    public let taskID: String
    public let filesChanged: Int?
    public let linesAdded: Int?
    public let linesRemoved: Int?
    public let sourceIncluded: Bool

    public var rendersPatch: Bool { false }

    public var summaryText: String {
        let files = filesChanged.map(String.init) ?? "0"
        let added = linesAdded.map(String.init) ?? "0"
        let removed = linesRemoved.map(String.init) ?? "0"
        return "\(files) files, +\(added) -\(removed)"
    }

    public var description: String { summaryText }

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case summary
        case sourceIncluded = "source_included"
    }

    private struct Summary: Decodable {
        let filesChanged: Int?
        let linesAdded: Int?
        let linesRemoved: Int?

        enum CodingKeys: String, CodingKey {
            case filesChanged = "files_changed"
            case linesAdded = "lines_added"
            case linesRemoved = "lines_removed"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taskID = try container.decode(String.self, forKey: .taskID)
        sourceIncluded = try container.decodeIfPresent(Bool.self, forKey: .sourceIncluded) ?? false
        let summary = try container.decode(Summary.self, forKey: .summary)
        filesChanged = summary.filesChanged
        linesAdded = summary.linesAdded
        linesRemoved = summary.linesRemoved
    }
}

public struct ComponentHealth: Decodable, Equatable, Sendable {
    public let name: String
    public let status: String
    public let stale: Bool
}

public struct SystemHealth: Decodable, Equatable, Sendable {
    public let status: String
    public let stale: Bool
    public let observedAt: String
    public let components: [ComponentHealth]

    enum CodingKeys: String, CodingKey {
        case status
        case stale
        case observedAt = "observed_at"
        case components
    }
}

public struct QueueItem: Decodable, Equatable, Sendable {
    public let taskID: String

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
    }
}

public struct SystemQueue: Decodable, Equatable, Sendable {
    public let depth: Int
    public let activeTaskID: String?
    public let items: [QueueItem]
    public let observedAt: String

    public var isEmpty: Bool { depth == 0 && items.isEmpty }

    enum CodingKeys: String, CodingKey {
        case depth
        case activeTaskID = "active_task_id"
        case items
        case observedAt = "observed_at"
    }
}

struct TaskPage: Decodable {
    let tasks: [TaskRow]
}

struct TaskRow: Decodable {
    let id: String
    let approvals: [ApprovalRow]
}

struct ApprovalRow: Decodable {
    let id: String
    let actionClass: String
    let actionDigest: String
    let paths: [String]
    let status: String

    enum CodingKeys: String, CodingKey {
        case id
        case actionClass = "action_class"
        case actionDigest = "action_digest"
        case paths
        case status
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        actionClass = try container.decode(String.self, forKey: .actionClass)
        actionDigest = try container.decode(String.self, forKey: .actionDigest)
        paths = try container.decodeIfPresent([String].self, forKey: .paths) ?? []
        status = try container.decode(String.self, forKey: .status)
    }
}

func listedOpenApprovals(in page: TaskPage) -> [OpenApproval] {
    page.tasks.flatMap { task in
        task.approvals.compactMap { row in
            guard row.status == "open" else { return nil }
            return OpenApproval(
                taskID: task.id,
                approvalID: row.id,
                actionClass: row.actionClass,
                actionDigest: row.actionDigest,
                paths: row.paths
            )
        }
    }
}

enum JSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder = JSONDecoder()
}
