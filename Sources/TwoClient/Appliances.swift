// Copyright 2026 MajestaNet
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct AdapterMenu: Decodable, Equatable, Sendable {
    public let slots: [AdapterSlot]
}

public struct AdapterSlot: Decodable, Equatable, Sendable {
    public let id: String
    public let installEnabled: Bool
    public let devices: [AdapterDevice]

    enum CodingKeys: String, CodingKey {
        case id
        case installEnabled = "install_enabled"
        case devices
    }
}

public struct AdapterDevice: Decodable, Equatable, Sendable {
    public let id: String
    public let kind: String
    public let aliases: [String]

    public init(id: String, kind: String, aliases: [String] = []) {
        self.id = id
        self.kind = kind
        self.aliases = aliases
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(String.self, forKey: .kind)
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case aliases
    }
}

public enum ApplianceLink: Equatable, Sendable {
    case unknown
    case online
    case offline
}

public struct ApplianceSight: Equatable, Sendable {
    /// Nil leaves the lamp as it was. A failed probe with no read-back is offline.
    public let link: ApplianceLink?
    public let detail: String

    public init(link: ApplianceLink?, detail: String) {
        self.link = link
        self.detail = detail
    }
}

public enum ApplianceVerb: String, Equatable, Sendable, CaseIterable {
    case on
    case off
    case heat
    case cool
    case start
    case stop
    case station
    case read

    public var title: String {
        switch self {
        case .on: "On"
        case .off: "Off"
        case .heat: "Heat"
        case .cool: "Cool"
        case .start: "Start"
        case .stop: "Stop"
        case .station: "Return"
        case .read: "Status"
        }
    }

    public var accessibilityTitle: String {
        self == .station ? "Return to station" : title
    }
}

public struct BoundAppliance: Equatable, Sendable, Identifiable {
    public let slot: String
    public let deviceID: String
    public let title: String
    public let kindName: String
    public let actions: [ApplianceVerb]
    public let aliases: [String]

    public var id: String { "\(slot)/\(deviceID)" }

    public init(slot: String, deviceID: String, aliases: [String] = []) {
        self.slot = slot
        self.deviceID = deviceID
        self.aliases = aliases
        title = ApplianceCatalog.title(deviceID)
        kindName = ApplianceCatalog.kindName(slot)
        actions = ApplianceCatalog.actions(slot)
    }
}

public enum ApplianceCatalog {
    /// Bound zones, sets, and robots. Nodes and disabled slots stay off the list.
    public static func appliances(in menu: AdapterMenu) -> [BoundAppliance] {
        let kinds = ["climate": "zone", "tv": "set", "vacuum": "robot"]
        var listed: [BoundAppliance] = []
        for slot in menu.slots {
            guard slot.installEnabled, let kind = kinds[slot.id] else { continue }
            for device in slot.devices where device.kind == kind && !device.id.isEmpty {
                listed.append(
                    BoundAppliance(slot: slot.id, deviceID: device.id, aliases: device.aliases)
                )
            }
        }
        return listed
    }

    public static func actions(_ slot: String) -> [ApplianceVerb] {
        switch slot {
        case "climate": [.on, .off, .heat, .cool]
        case "tv": [.on, .off]
        case "vacuum": [.start, .stop, .station]
        default: []
        }
    }

    public static func kindName(_ slot: String) -> String {
        switch slot {
        case "climate": "Air conditioner"
        case "tv": "Television"
        case "vacuum": "Vacuum"
        default: "Appliance"
        }
    }

    public static func title(_ id: String) -> String {
        spokenName(id).capitalized
    }

    /// Phrases the control plane compiles without the model.
    /// Climate on is auto: a bare "turn the ac on" does not compile.
    public static func phrase(_ appliance: BoundAppliance, _ verb: ApplianceVerb) -> String? {
        let name = spokenName(appliance.deviceID)
        guard !name.isEmpty else { return nil }
        switch (appliance.slot, verb) {
        case ("climate", .on):
            return "turn \(name) auto"
        case ("climate", .off):
            return "turn \(name) ac off"
        case ("climate", .heat):
            return "heat \(name)"
        case ("climate", .cool):
            return "cool \(name)"
        case ("climate", .read):
            return "\(name) ac temperature"
        case ("tv", .on):
            return "turn \(name) tv on"
        case ("tv", .off):
            return "turn \(name) tv off"
        case ("tv", .read):
            return "\(name) tv status"
        case ("vacuum", .start):
            return "start \(name) vacuum"
        case ("vacuum", .stop):
            return "stop \(name) vacuum"
        case ("vacuum", .station):
            return "dock \(name) vacuum"
        case ("vacuum", .read):
            return "\(name) vacuum status"
        default:
            return nil
        }
    }

    /// Whole degrees the climate compiler accepts.
    public static func setpointPhrase(_ appliance: BoundAppliance, celsius: Int) -> String? {
        guard appliance.slot == "climate", (0...50).contains(celsius) else { return nil }
        let name = spokenName(appliance.deviceID)
        guard !name.isEmpty else { return nil }
        return "set \(name) to \(celsius)"
    }

    /// True when the spoken words name this appliance or one of its aliases.
    public static func matchesSpoken(_ appliance: BoundAppliance, _ spoken: String) -> Bool {
        let query = spokenName(spoken).lowercased()
        guard !query.isEmpty else { return false }
        let names = [spokenName(appliance.deviceID)] + appliance.aliases.map(spokenName)
        return names.contains { name in
            let normalized = name.lowercased()
            guard !normalized.isEmpty else { return false }
            if query == normalized { return true }
            return " \(query) ".contains(" \(normalized) ")
        }
    }

    public static func sight(
        in receipt: VoiceTurnReceipt,
        slot: String,
        deviceID: String
    ) -> ApplianceSight {
        if receipt.status == "awaiting_approval" {
            return ApplianceSight(link: nil, detail: "Needs a decision on the watch.")
        }
        let observed = observations(in: receipt, slot: slot, deviceID: deviceID)
        if observed.contains(where: { !$0.reachable }) {
            return ApplianceSight(link: .offline, detail: "Offline")
        }
        if let last = observed.last {
            let detail = last.detail.isEmpty ? "Connected" : last.detail
            return ApplianceSight(link: .online, detail: detail)
        }
        if receipt.status == "failed" || receipt.status == "complete" {
            return ApplianceSight(link: .offline, detail: receipt.status == "failed" ? "The turn failed." : "Offline")
        }
        return ApplianceSight(link: nil, detail: "")
    }

    public static func spokenName(_ id: String) -> String {
        id.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func observations(
        in receipt: VoiceTurnReceipt,
        slot: String,
        deviceID: String
    ) -> [(reachable: Bool, detail: String)] {
        var found: [(reachable: Bool, detail: String)] = []
        if slot == "climate", let climate = receipt.climate, climate.zone == deviceID {
            found.append((climate.reachable, climateDetail(climate)))
        }
        if slot == "tv", let tv = receipt.tv, tv.setName == deviceID {
            found.append((tv.reachable, titled(tv.power)))
        }
        if slot == "vacuum", let vacuum = receipt.vacuum, vacuum.robot == deviceID {
            found.append((vacuum.reachable, titled(vacuum.activity)))
        }
        for item in receipt.fanout where item.slot == slot && item.target == deviceID {
            if let climate = item.climate, climate.zone == deviceID {
                found.append((climate.reachable, climateDetail(climate)))
            }
            if let tv = item.tv, tv.setName == deviceID {
                found.append((tv.reachable, titled(tv.power)))
            }
            if let vacuum = item.vacuum, vacuum.robot == deviceID {
                found.append((vacuum.reachable, titled(vacuum.activity)))
            }
        }
        return found
    }

    private static func climateDetail(_ climate: ClimateReadback) -> String {
        var words: [String] = []
        if let mode = climate.mode, !mode.isEmpty {
            words.append(titled(mode))
        }
        if let setpoint = climate.setpointCelsius {
            words.append(degrees(setpoint))
        }
        return words.joined(separator: " ")
    }

    private static func degrees(_ value: Double) -> String {
        let shown = value.rounded() == value ? String(Int(value)) : String(value)
        return "\(shown)°"
    }

    private static func titled(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst()
    }
}
