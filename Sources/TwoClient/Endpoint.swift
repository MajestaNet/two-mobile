// Copyright 2026 MajestaNet
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum EndpointError: Error, Equatable {
    case emptyHost
    case loopbackRefused
    case apiPortRefused
    case notHTTPS
    case invalidPort
    case invalidHost

    public var screenText: String {
        switch self {
        case .emptyHost:
            return "Enter the mini's private host."
        case .loopbackRefused:
            return "Use the private LAN address Caddy is listening on. The simulator cannot use loopback."
        case .apiPortRefused:
            return "That port is the control API. Use the Caddy port."
        case .notHTTPS:
            return "The mini is reached over HTTPS."
        case .invalidPort:
            return "The port is not valid."
        case .invalidHost:
            return "The host is not valid."
        }
    }
}

/// Host saved at enrollment. There is no built-in address.
public struct EdgeEndpoint: Equatable, Sendable {
    public let host: String
    public let port: Int

    /// Control API bind. Caddy is the only LAN listener.
    private static let controlAPIPort = 8741

    public var baseURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = port
        guard let url = components.url else {
            preconditionFailure("endpoint was validated")
        }
        return url
    }

    public init(host: String, port: Int) throws {
        try self.init(parsingHost: host, portField: String(port))
    }

    public init(parsingHost hostField: String, portField: String) throws {
        let trimmed = hostField.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw EndpointError.emptyHost
        }
        if trimmed.contains("://") {
            guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
                throw EndpointError.invalidHost
            }
            guard scheme == "https" else { throw EndpointError.notHTTPS }
            guard url.user == nil, url.password == nil else { throw EndpointError.invalidHost }
            let path = url.path
            guard path.isEmpty || path == "/", url.query == nil, url.fragment == nil else {
                throw EndpointError.invalidHost
            }
            guard let parsedHost = url.host, !parsedHost.isEmpty else {
                throw EndpointError.emptyHost
            }
            let parsedPort = url.port ?? Self.port(from: portField, fallback: 8443)
            try Self.validate(host: parsedHost, port: parsedPort)
            host = parsedHost
            port = parsedPort
            return
        }
        let parsedPort = Self.port(from: portField, fallback: 8443)
        try Self.validate(host: trimmed, port: parsedPort)
        host = trimmed
        port = parsedPort
    }

    private static func port(from field: String, fallback: Int) -> Int {
        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return fallback }
        return Int(trimmed) ?? -1
    }

    private static func validate(host: String, port: Int) throws {
        if host.contains("/") || host.contains("@") || host.contains(where: { $0.isWhitespace }) {
            throw EndpointError.invalidHost
        }
        if host.count > 253 || host.isEmpty {
            throw EndpointError.invalidHost
        }
        if isLoopback(host) {
            throw EndpointError.loopbackRefused
        }
        if port == controlAPIPort {
            throw EndpointError.apiPortRefused
        }
        if port < 1 || port > 65535 {
            throw EndpointError.invalidPort
        }
    }

    private static func isLoopback(_ host: String) -> Bool {
        let value = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if value == "localhost" || value == "::1" || value == "0.0.0.0" || value == "::" {
            return true
        }
        return value.hasPrefix("127.")
    }
}

public enum EdgeReach {
    /// Overlay addresses first, so cellular does not wait on the home network.
    public static func ordered(_ hosts: [String]) -> [String] {
        var seen = Set<String>()
        let unique = hosts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return unique.sorted { rank($0) < rank($1) }
    }

    private static func rank(_ host: String) -> Int {
        isOverlay(host) ? 0 : 1
    }

    /// Tailscale IPv4 is 100.64.0.0/10. A hostname is an overlay name.
    public static func isOverlay(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) {
            return parts[0] == 100 && (64...127).contains(parts[1])
        }
        return host.range(of: ".", options: []) == nil || host.contains(where: { $0.isLetter })
    }
}

enum EndpointRecord {
    static func encode(primary: EdgeEndpoint, alternates: [EdgeEndpoint]) -> Data {
        var lines = [primary.host, String(primary.port)]
        for alternate in alternates where alternate.host != primary.host {
            lines.append(alternate.host)
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    static func encode(_ endpoint: EdgeEndpoint) -> Data {
        encode(primary: endpoint, alternates: [])
    }

    static func decode(_ data: Data) -> (EdgeEndpoint, [EdgeEndpoint])? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let parts = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let port = Int(parts[1]) else { return nil }
        guard let primary = try? EdgeEndpoint(host: parts[0], port: port) else { return nil }
        let alternates = parts.dropFirst(2).compactMap { try? EdgeEndpoint(host: $0, port: port) }
        return (primary, alternates)
    }
}
