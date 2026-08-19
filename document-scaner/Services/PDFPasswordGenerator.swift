import Foundation
import Security

nonisolated struct PDFPasswordPair: Equatable, Sendable {
    let userPassword: String
    let ownerPassword: String

    var displayedUserPassword: String {
        stride(from: 0, to: userPassword.count, by: 4).map { offset in
            let start = userPassword.index(userPassword.startIndex, offsetBy: offset)
            let end = userPassword.index(start, offsetBy: min(4, userPassword.count - offset))
            return String(userPassword[start..<end])
        }
        .joined(separator: "-")
    }

    /// The grouped value is also the actual PDF password so reveal, copy, and
    /// manual entry always use the same characters.
    var pdfPassword: String { displayedUserPassword }
}

nonisolated struct PDFPasswordGenerator: Sendable {
    private static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789".utf8)

    func generate() throws -> PDFPasswordPair {
        PDFPasswordPair(
            userPassword: try randomString(length: 16),
            ownerPassword: try randomString(length: 32)
        )
    }

    private func randomString(length: Int) throws -> String {
        let alphabet = Self.alphabet
        let acceptanceLimit = UInt8.max - UInt8((Int(UInt8.max) + 1) % alphabet.count)
        var result = [UInt8]()
        result.reserveCapacity(length)

        while result.count < length {
            var byte: UInt8 = 0
            let status = SecRandomCopyBytes(kSecRandomDefault, 1, &byte)
            guard status == errSecSuccess else { throw PDFPasswordGenerationError.randomSourceFailed(status) }
            guard byte <= acceptanceLimit else { continue }
            result.append(alphabet[Int(byte) % alphabet.count])
        }
        return String(decoding: result, as: UTF8.self)
    }
}

nonisolated enum PDFPasswordGenerationError: LocalizedError, Equatable, Sendable {
    case randomSourceFailed(OSStatus)

    var errorDescription: String? {
        "The app could not generate a secure PDF password."
    }
}

nonisolated struct PDFExportConfiguration: Sendable {
    let quality: DocumentExportQuality
    let requiresPassword: Bool
    let passwords: PDFPasswordPair
    let sourceProtection: DocumentProtection
}
