// Copyright 2026 MajestaNet
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Security

enum PinnedTrust {
    static func der(from pinned: Data) -> Data? {
        guard !pinned.isEmpty else { return nil }
        guard let text = String(data: pinned, encoding: .utf8),
              text.contains("BEGIN CERTIFICATE") else {
            return pinned
        }
        guard let start = text.range(of: "-----BEGIN CERTIFICATE-----"),
              let end = text.range(of: "-----END CERTIFICATE-----"),
              start.upperBound <= end.lowerBound else {
            return nil
        }
        let base64 = text[start.upperBound..<end.lowerBound]
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        return Data(base64Encoded: base64)
    }

    /// The chain has to end at the enrolled CA. A matching leaf is not enough.
    static func chainEnds(at pinned: Data, chain: [Data]) -> Bool {
        guard let root = chain.last, let der = der(from: pinned) else { return false }
        return root == der
    }

    static func accept(trust: SecTrust, pinnedCertificate pinned: Data) -> Bool {
        guard let der = der(from: pinned),
              let anchor = SecCertificateCreateWithData(nil, der as CFData) else {
            return false
        }
        SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else { return false }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], !chain.isEmpty else {
            return false
        }
        let ders = chain.map { SecCertificateCopyData($0) as Data }
        return chainEnds(at: pinned, chain: ders)
    }

    static func leaf(_ leafDER: Data, signedBy pinned: Data) -> Bool {
        guard let cert = SecCertificateCreateWithData(nil, leafDER as CFData),
              let der = der(from: pinned),
              let anchor = SecCertificateCreateWithData(nil, der as CFData) else {
            return false
        }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(cert, SecPolicyCreateBasicX509(), &trust) == errSecSuccess,
              let trust else {
            return false
        }
        SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }
}

public enum AccessGroup {
    public static func resolved(bundle: Bundle = .main) -> String? {
        guard let raw = bundle.object(forInfoDictionaryKey: "TwoKeychainAccessGroup") as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.contains("$") {
            return nil
        }
        return trimmed
    }
}

public struct Enrollment: Equatable, Sendable {
    public let endpoint: EdgeEndpoint
    public let alternates: [EdgeEndpoint]
    public let pinnedCertificate: Data

    public init(
        endpoint: EdgeEndpoint,
        pinnedCertificate: Data,
        alternates: [EdgeEndpoint] = []
    ) {
        self.endpoint = endpoint
        self.alternates = alternates
        self.pinnedCertificate = pinnedCertificate
    }

    public var reach: [EdgeEndpoint] {
        var hosts = [endpoint]
        for alternate in alternates where alternate.host != endpoint.host {
            hosts.append(alternate)
        }
        return hosts
    }
}

public enum KeychainError: Error, Equatable {
    case passwordRejected
    case missingEntitlement
    case emptyAccessGroup
    case status(Int)

    public var screenText: String {
        switch self {
        case .passwordRejected:
            return "The password was not accepted."
        case .missingEntitlement:
            return "The keychain access group is not signed yet."
        case .emptyAccessGroup:
            return "The keychain access group is not set."
        case .status(let code):
            return "The keychain rejected the item (\(code))."
        }
    }
}

public enum WatchKeychain {
    private static let identityLabel = "two.watch.identity"
    private static let certificateAccount = "pinned-ca"
    private static let endpointAccount = "edge-endpoint"
    private static let service = "two.watch"

    public static func saveEnrollment(
        pkcs12: Data,
        password: String,
        certificate: Data,
        endpoint: EdgeEndpoint,
        accessGroup: String
    ) throws {
        try require(accessGroup)
        let identity = try importIdentity(pkcs12: pkcs12, password: password)
        try storeIdentity(identity, accessGroup: accessGroup)
        do {
            try storeItem(account: certificateAccount, data: certificate, accessGroup: accessGroup)
            try storeItem(
                account: endpointAccount,
                data: EndpointRecord.encode(endpoint),
                accessGroup: accessGroup
            )
        } catch {
            deleteIdentity(accessGroup: accessGroup)
            throw error
        }
    }

    public static func loadEnrollment(accessGroup: String) throws -> Enrollment? {
        try require(accessGroup)
        guard let certificate = try readItem(account: certificateAccount, accessGroup: accessGroup),
              let endpointData = try readItem(account: endpointAccount, accessGroup: accessGroup),
              let decoded = EndpointRecord.decode(endpointData) else {
            return nil
        }
        guard try copyIdentity(accessGroup: accessGroup) != nil else { return nil }
        return Enrollment(
            endpoint: decoded.0,
            pinnedCertificate: certificate,
            alternates: decoded.1
        )
    }

    public static func saveIssuedCertificate(
        certificatePEM: Data,
        pinnedCertificate: Data,
        endpoint: EdgeEndpoint,
        accessGroup: String
    ) throws {
        try require(accessGroup)
        guard let der = PinnedTrust.der(from: certificatePEM),
              let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw KeychainError.status(Int(errSecDecode))
        }
        deleteIdentity(accessGroup: accessGroup)
        deleteCertificate(accessGroup: accessGroup)
        // iOS returns errSecParam (-50) for kSecAttrAccessible, kSecAttrSynchronizable,
        // and kSecMatchItemList on a certificate or identity. The private key already
        // carries the access policy. The certificate label is how the identity is found.
        let add: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: identityLabel,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { throw map(status) }
        do {
            if try copyIdentity(accessGroup: accessGroup) == nil {
                guard let found = try copyIdentity(matching: certificate, accessGroup: accessGroup) else {
                    throw KeychainError.status(Int(errSecItemNotFound))
                }
                try labelExistingIdentity(found, accessGroup: accessGroup)
            }
            try storeItem(account: certificateAccount, data: pinnedCertificate, accessGroup: accessGroup)
            try storeItem(
                account: endpointAccount,
                data: EndpointRecord.encode(endpoint),
                accessGroup: accessGroup
            )
        } catch {
            clear(accessGroup: accessGroup)
            throw error
        }
    }

    public static func saveReach(
        primary: EdgeEndpoint,
        alternates: [EdgeEndpoint],
        accessGroup: String
    ) throws {
        try require(accessGroup)
        try storeItem(
            account: endpointAccount,
            data: EndpointRecord.encode(primary: primary, alternates: alternates),
            accessGroup: accessGroup
        )
    }

    public static func clear(accessGroup: String) {
        deleteIdentity(accessGroup: accessGroup)
        PhoneIdentityKey.delete(accessGroup: accessGroup)
        deleteCertificate(accessGroup: accessGroup)
        for account in [certificateAccount, endpointAccount] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrAccessGroup as String: accessGroup,
                kSecAttrSynchronizable as String: false,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

    static func copyIdentity(accessGroup: String) throws -> SecIdentity? {
        try require(accessGroup)
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: identityLabel,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let item else {
            throw map(status)
        }
        let object = item as AnyObject
        guard CFGetTypeID(object) == SecIdentityGetTypeID() else { return nil }
        return (object as! SecIdentity)
    }

    private static func deleteCertificate(accessGroup: String) {
        let certificate: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: identityLabel,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        SecItemDelete(certificate as CFDictionary)
    }

    static func copyIdentity(matching certificate: SecCertificate, accessGroup: String) throws -> SecIdentity? {
        try require(accessGroup)
        if let labeled = try copyIdentity(accessGroup: accessGroup),
           try sameCertificate(labeled, certificate) {
            return labeled
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let item else {
            throw map(status)
        }
        for identity in identities(from: item) where try sameCertificate(identity, certificate) {
            return identity
        }
        return nil
    }

    private static func identities(from item: CFTypeRef) -> [SecIdentity] {
        let object = item as AnyObject
        if CFGetTypeID(object) == SecIdentityGetTypeID() {
            return [(object as! SecIdentity)]
        }
        guard CFGetTypeID(object) == CFArrayGetTypeID() else { return [] }
        let array = object as! CFArray
        return (0..<CFArrayGetCount(array)).compactMap { index in
            let value = CFArrayGetValueAtIndex(array, index)
            let element = unsafeBitCast(value, to: AnyObject.self)
            guard CFGetTypeID(element) == SecIdentityGetTypeID() else { return nil }
            return (element as! SecIdentity)
        }
    }

    private static func sameCertificate(_ identity: SecIdentity, _ certificate: SecCertificate) throws -> Bool {
        var found: SecCertificate?
        let status = SecIdentityCopyCertificate(identity, &found)
        guard status == errSecSuccess, let found else { throw map(status) }
        return (SecCertificateCopyData(found) as Data) == (SecCertificateCopyData(certificate) as Data)
    }

    private static func require(_ accessGroup: String) throws {
        if accessGroup.isEmpty || accessGroup.contains("$") {
            throw KeychainError.emptyAccessGroup
        }
    }

    private static func importIdentity(pkcs12: Data, password: String) throws -> SecIdentity {
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        var raw: CFArray?
        let status = SecPKCS12Import(pkcs12 as CFData, options, &raw)
        if status == errSecAuthFailed || status == errSecDecode || status == errSecPkcs12VerifyFailure {
            throw KeychainError.passwordRejected
        }
        guard status == errSecSuccess,
              let list = raw as? [[String: Any]],
              let first = list.first,
              let value = first[kSecImportItemIdentity as String] else {
            throw map(status)
        }
        let object = value as AnyObject
        guard CFGetTypeID(object) == SecIdentityGetTypeID() else {
            throw KeychainError.status(Int(errSecDecode))
        }
        return (object as! SecIdentity)
    }

    private static func storeIdentity(_ identity: SecIdentity, accessGroup: String) throws {
        deleteIdentity(accessGroup: accessGroup)
        let add: [String: Any] = [
            kSecValueRef as String: identity,
            kSecAttrLabel as String: identityLabel,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            try labelExistingIdentity(identity, accessGroup: accessGroup)
            return
        }
        guard status == errSecSuccess else { throw map(status) }
    }

    private static func labelExistingIdentity(_ identity: SecIdentity, accessGroup: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecValueRef as String: identity,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        let changes = [kSecAttrLabel as String: identityLabel] as CFDictionary
        let status = SecItemUpdate(query as CFDictionary, changes)
        guard status == errSecSuccess else { throw map(status) }
    }

    private static func deleteIdentity(accessGroup: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: identityLabel,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func storeItem(account: String, data: Data, accessGroup: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: false,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw map(status) }
    }

    private static func readItem(account: String, accessGroup: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let item else { throw map(status) }
        return item as? Data
    }

    private static func map(_ status: OSStatus) -> KeychainError {
        if status == errSecMissingEntitlement { return .missingEntitlement }
        if status == errSecAuthFailed || status == errSecPkcs12VerifyFailure { return .passwordRejected }
        return .status(Int(status))
    }
}
