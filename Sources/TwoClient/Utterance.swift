// Copyright 2026 MajestaNet
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct VoiceSubmission: Equatable, Sendable {
    public let text: String
    public let profile: VoiceProfile?

    public init(text: String, profile: VoiceProfile?) {
        self.text = text
        self.profile = profile
    }
}

public enum UtteranceRouting {
    /// Omits `profile` unless the first word is `chat`. `chat` alone is dropped.
    public static func submission(from spoken: String) -> VoiceSubmission? {
        let trimmed = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",:"))
        guard let split = trimmed.firstIndex(where: { character in
            character.unicodeScalars.contains(where: { separators.contains($0) })
        }) else {
            return trimmed.lowercased() == "chat" ? nil : VoiceSubmission(text: trimmed, profile: nil)
        }
        let first = String(trimmed[..<split])
            .trimmingCharacters(in: CharacterSet(charactersIn: ",:"))
        if first.lowercased() == "chat" {
            let rest = trimmed[split...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ",:"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rest.isEmpty else { return nil }
            return VoiceSubmission(text: rest, profile: .chat)
        }
        return VoiceSubmission(text: trimmed, profile: nil)
    }
}

public enum EdgeUsername {
    public static func parse(_ raw: String) throws -> String {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...32).contains(token.count) else {
            throw EdgeUsernameError.invalid
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard token.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw EdgeUsernameError.invalid
        }
        return token
    }
}

public enum EdgeUsernameError: Error, Equatable {
    case invalid

    public var screenText: String {
        "Username is 1 to 32 letters, digits, or hyphens."
    }
}
