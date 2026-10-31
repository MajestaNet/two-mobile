// Copyright 2026 MajestaNet
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Security

public enum CertificateRequestError: Error {
    case keyGeneration
    case publicKey
    case signature
}

public enum PhoneIdentityKey {
    static let tag = Data("two.phone.identity".utf8)

    public static func make(accessGroup: String) throws -> SecKey {
        delete(accessGroup: accessGroup)
        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var privateAttrs: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: tag,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
        ]
        if !accessGroup.isEmpty {
            privateAttrs[kSecAttrAccessGroup as String] = accessGroup
        }
        attributes[kSecPrivateKeyAttrs as String] = privateAttrs
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw CertificateRequestError.keyGeneration
        }
        return key
    }

    public static func delete(accessGroup: String) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrSynchronizable as String: false,
        ]
        if !accessGroup.isEmpty {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        SecItemDelete(query as CFDictionary)
    }
}

public enum CertificateRequest {
    public static func pem(username: String, privateKey: SecKey) throws -> String {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw CertificateRequestError.publicKey
        }
        var error: Unmanaged<CFError>?
        guard let spki = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw CertificateRequestError.publicKey
        }
        let info = certificationRequestInfo(username: username, publicKey: spki)
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            info as CFData,
            &error
        ) as Data? else {
            throw CertificateRequestError.signature
        }
        let der = ASN1.sequence(
            info,
            ASN1.sequence(ASN1.ecdsaWithSHA256),
            ASN1.bitString(signature)
        )
        return pemBlock("CERTIFICATE REQUEST", der: der)
    }

    private static func certificationRequestInfo(username: String, publicKey: Data) -> Data {
        ASN1.sequence(
            ASN1.integer(0),
            subject(username),
            subjectPublicKeyInfo(publicKey),
            ASN1.context0(Data())
        )
    }

    private static func subject(_ username: String) -> Data {
        ASN1.sequence(
            ASN1.set(
                ASN1.sequence(
                    ASN1.objectIdentifier([2, 5, 4, 3]),
                    ASN1.printableString(username)
                )
            )
        )
    }

    private static func subjectPublicKeyInfo(_ publicKey: Data) -> Data {
        ASN1.sequence(
            ASN1.sequence(ASN1.ecPublicKey, ASN1.prime256v1),
            ASN1.bitString(publicKey)
        )
    }

    private static func pemBlock(_ kind: String, der: Data) -> String {
        let body = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN \(kind)-----\n\(body)\n-----END \(kind)-----\n"
    }
}

enum ASN1 {
    static let ecPublicKey = objectIdentifier([1, 2, 840, 10045, 2, 1])
    static let prime256v1 = objectIdentifier([1, 2, 840, 10045, 3, 1, 7])
    static let ecdsaWithSHA256 = objectIdentifier([1, 2, 840, 10045, 4, 3, 2])

    static func sequence(_ items: Data...) -> Data {
        wrap(0x30, items.reduce(into: Data(), { $0.append($1) }))
    }

    static func set(_ items: Data...) -> Data {
        wrap(0x31, items.reduce(into: Data(), { $0.append($1) }))
    }

    static func integer(_ value: Int) -> Data {
        wrap(0x02, Data([UInt8(value)]))
    }

    static func bitString(_ bytes: Data) -> Data {
        var content = Data([0x00])
        content.append(bytes)
        return wrap(0x03, content)
    }

    static func printableString(_ text: String) -> Data {
        wrap(0x13, Data(text.utf8))
    }

    static func context0(_ content: Data) -> Data {
        wrap(0xA0, content)
    }

    static func objectIdentifier(_ oid: [UInt]) -> Data {
        precondition(oid.count >= 2)
        var bytes = Data([UInt8(oid[0] * 40 + oid[1])])
        for component in oid.dropFirst(2) {
            bytes.append(base128(component))
        }
        return wrap(0x06, bytes)
    }

    private static func wrap(_ tag: UInt8, _ content: Data) -> Data {
        var output = Data([tag])
        output.append(length(content.count))
        output.append(content)
        return output
    }

    private static func length(_ count: Int) -> Data {
        if count < 0x80 {
            return Data([UInt8(count)])
        }
        var value = count
        var bytes = [UInt8]()
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    private static func base128(_ value: UInt) -> Data {
        if value == 0 { return Data([0]) }
        var remainder = value
        var bytes = [UInt8]()
        bytes.insert(UInt8(remainder & 0x7F), at: 0)
        remainder >>= 7
        while remainder > 0 {
            bytes.insert(UInt8((remainder & 0x7F) | 0x80), at: 0)
            remainder >>= 7
        }
        return Data(bytes)
    }
}
