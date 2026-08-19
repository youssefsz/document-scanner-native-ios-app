import CryptoKit
import Foundation
import Security

nonisolated enum VaultCryptoError: LocalizedError, Equatable, Sendable {
    case unsupportedVersion
    case wrongDocument
    case wrongAssetKind
    case malformedEnvelope
    case truncatedEnvelope
    case authenticationFailed
    case emptyAsset

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion:
            "This secure document uses an unsupported encryption format."
        case .wrongDocument, .wrongAssetKind:
            "The secure file does not belong to this document."
        case .malformedEnvelope, .truncatedEnvelope:
            "The secure file is damaged or incomplete."
        case .authenticationFailed:
            "The secure file could not be authenticated."
        case .emptyAsset:
            "An empty file cannot be secured."
        }
    }
}

nonisolated struct VaultCryptoService: @unchecked Sendable {
    static let formatVersion: UInt16 = 1
    static let chunkSize = 1_048_576

    private static let assetMagic = Data("DSVAULT1".utf8)
    private static let titleMagic = Data("DSTITLE1".utf8)
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func encryptFile(
        at sourceURL: URL,
        to destinationURL: URL,
        documentID: UUID,
        kind: VaultAssetKind,
        access: VaultAccess
    ) throws {
        guard kind != .title else { throw VaultCryptoError.wrongAssetKind }
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey])
        let originalLength = UInt64(values.fileSize ?? 0)

        try access.withRootKey { rootKey in
            let salt = randomData(count: 32)
            // One authenticated empty chunk keeps even a zero-byte envelope
            // cryptographically bound to its header.
            let chunkCount = UInt32(max(1, (originalLength + UInt64(Self.chunkSize) - 1) / UInt64(Self.chunkSize)))
            let header = assetHeader(
                documentID: documentID,
                kind: kind,
                salt: salt,
                originalLength: originalLength,
                chunkSize: UInt32(Self.chunkSize),
                chunkCount: chunkCount
            )
            let key = deriveKey(rootKey: rootKey, salt: salt, documentID: documentID, kind: kind)
            let temporaryURL = try protectedTemporaryURL(nextTo: destinationURL)
            defer { try? fileManager.removeItem(at: temporaryURL) }

            fileManager.createFile(atPath: temporaryURL.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete])
            let input = try FileHandle(forReadingFrom: sourceURL)
            let output = try FileHandle(forWritingTo: temporaryURL)
            defer {
                try? input.close()
                try? output.close()
            }

            try output.write(contentsOf: header)
            for index in 0..<chunkCount {
                if Task.isCancelled { throw CancellationError() }
                let plaintext = try input.read(upToCount: Self.chunkSize) ?? Data()
                guard !plaintext.isEmpty || originalLength == 0 else { throw VaultCryptoError.truncatedEnvelope }
                var associatedData = header
                associatedData.appendInteger(index)
                let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: associatedData)
                guard let combined = sealed.combined, combined.count <= Int(UInt32.max) else {
                    throw VaultCryptoError.malformedEnvelope
                }
                try output.write(contentsOf: Data.integer(UInt32(combined.count)))
                try output.write(contentsOf: combined)
            }

            if let trailing = try input.read(upToCount: 1), !trailing.isEmpty {
                throw VaultCryptoError.malformedEnvelope
            }
            try output.synchronize()
            try installVerifiedTemporary(temporaryURL, at: destinationURL)
        }
    }

    func decryptFile(
        at sourceURL: URL,
        to destinationURL: URL,
        documentID: UUID,
        kind: VaultAssetKind,
        access: VaultAccess
    ) throws {
        guard kind != .title else { throw VaultCryptoError.wrongAssetKind }
        try access.withRootKey { rootKey in
            let input = try FileHandle(forReadingFrom: sourceURL)
            defer { try? input.close() }
            let headerData = try readExactly(Self.assetHeaderLength, from: input)
            let header = try parseAssetHeader(headerData, expectedDocumentID: documentID, expectedKind: kind)
            let key = deriveKey(rootKey: rootKey, salt: header.salt, documentID: documentID, kind: kind)
            let temporaryURL = try protectedTemporaryURL(nextTo: destinationURL)
            defer { try? fileManager.removeItem(at: temporaryURL) }

            fileManager.createFile(atPath: temporaryURL.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete])
            let output = try FileHandle(forWritingTo: temporaryURL)
            defer { try? output.close() }
            var written: UInt64 = 0

            for index in 0..<header.chunkCount {
                if Task.isCancelled { throw CancellationError() }
                let sealedLength = try readExactly(4, from: input).readInteger(UInt32.self)
                let maximumLength = UInt32(header.chunkSize) + 12 + 16
                guard sealedLength >= 28, sealedLength <= maximumLength else {
                    throw VaultCryptoError.malformedEnvelope
                }
                let combined = try readExactly(Int(sealedLength), from: input)
                let sealed: AES.GCM.SealedBox
                do {
                    sealed = try AES.GCM.SealedBox(combined: combined)
                } catch {
                    throw VaultCryptoError.malformedEnvelope
                }
                var associatedData = headerData
                associatedData.appendInteger(index)
                let plaintext: Data
                do {
                    plaintext = try AES.GCM.open(sealed, using: key, authenticating: associatedData)
                } catch {
                    throw VaultCryptoError.authenticationFailed
                }

                let remaining = header.originalLength - written
                let expected = Int(min(UInt64(header.chunkSize), remaining))
                guard plaintext.count == expected else { throw VaultCryptoError.malformedEnvelope }
                try output.write(contentsOf: plaintext)
                written += UInt64(plaintext.count)
            }

            guard written == header.originalLength else { throw VaultCryptoError.truncatedEnvelope }
            if let trailing = try input.read(upToCount: 1), !trailing.isEmpty {
                throw VaultCryptoError.malformedEnvelope
            }
            try output.synchronize()
            try installVerifiedTemporary(temporaryURL, at: destinationURL)
        }
    }

    func decryptFileData(
        at sourceURL: URL,
        documentID: UUID,
        kind: VaultAssetKind,
        access: VaultAccess,
        temporaryDirectory: URL
    ) throws -> Data {
        let temporaryURL = temporaryDirectory.appendingPathComponent(UUID().uuidString.lowercased())
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try fileManager.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        try decryptFile(
            at: sourceURL,
            to: temporaryURL,
            documentID: documentID,
            kind: kind,
            access: access
        )
        return try Data(contentsOf: temporaryURL, options: .mappedIfSafe)
    }

    func encryptTitle(_ title: String, documentID: UUID, access: VaultAccess) throws -> Data {
        try access.withRootKey { rootKey in
            let plaintext = Data(title.utf8)
            let salt = randomData(count: 32)
            let header = titleHeader(documentID: documentID, salt: salt, originalLength: UInt32(plaintext.count))
            let key = deriveKey(rootKey: rootKey, salt: salt, documentID: documentID, kind: .title)
            let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: header)

            var envelope = header
            envelope.append(sealed.nonce.withUnsafeBytes { Data($0) })
            envelope.append(sealed.ciphertext)
            envelope.append(sealed.tag)
            return envelope
        }
    }

    func decryptTitle(_ blob: Data, documentID: UUID, access: VaultAccess) throws -> String {
        try access.withRootKey { rootKey in
            var reader = VaultByteReader(data: blob)
            guard try reader.read(Self.titleMagic.count) == Self.titleMagic else {
                throw VaultCryptoError.malformedEnvelope
            }
            guard try reader.readInteger(UInt16.self) == Self.formatVersion else {
                throw VaultCryptoError.unsupportedVersion
            }
            guard try reader.readInteger(UInt8.self) == VaultAssetKind.title.rawValue else {
                throw VaultCryptoError.wrongAssetKind
            }
            _ = try reader.readInteger(UInt8.self)
            guard try reader.read(16) == documentID.byteData else { throw VaultCryptoError.wrongDocument }
            let salt = try reader.read(32)
            let originalLength = try reader.readInteger(UInt32.self)
            let header = blob.prefix(reader.offset)
            let nonceData = try reader.read(12)
            let ciphertext = try reader.read(Int(originalLength))
            let tag = try reader.read(16)
            guard reader.isAtEnd else { throw VaultCryptoError.malformedEnvelope }

            let sealed: AES.GCM.SealedBox
            do {
                sealed = try AES.GCM.SealedBox(
                    nonce: AES.GCM.Nonce(data: nonceData),
                    ciphertext: ciphertext,
                    tag: tag
                )
            } catch {
                throw VaultCryptoError.malformedEnvelope
            }
            let key = deriveKey(rootKey: rootKey, salt: salt, documentID: documentID, kind: .title)
            let plaintext: Data
            do {
                plaintext = try AES.GCM.open(sealed, using: key, authenticating: Data(header))
            } catch {
                throw VaultCryptoError.authenticationFailed
            }
            guard let title = String(data: plaintext, encoding: .utf8) else {
                throw VaultCryptoError.malformedEnvelope
            }
            return title
        }
    }

    private static let assetHeaderLength = 8 + 2 + 1 + 1 + 16 + 32 + 8 + 4 + 4

    private func assetHeader(
        documentID: UUID,
        kind: VaultAssetKind,
        salt: Data,
        originalLength: UInt64,
        chunkSize: UInt32,
        chunkCount: UInt32
    ) -> Data {
        var data = Self.assetMagic
        data.appendInteger(Self.formatVersion)
        data.appendInteger(kind.rawValue)
        data.appendInteger(UInt8(0))
        data.append(documentID.byteData)
        data.append(salt)
        data.appendInteger(originalLength)
        data.appendInteger(chunkSize)
        data.appendInteger(chunkCount)
        return data
    }

    private func titleHeader(documentID: UUID, salt: Data, originalLength: UInt32) -> Data {
        var data = Self.titleMagic
        data.appendInteger(Self.formatVersion)
        data.appendInteger(VaultAssetKind.title.rawValue)
        data.appendInteger(UInt8(0))
        data.append(documentID.byteData)
        data.append(salt)
        data.appendInteger(originalLength)
        return data
    }

    private func parseAssetHeader(
        _ data: Data,
        expectedDocumentID: UUID,
        expectedKind: VaultAssetKind
    ) throws -> AssetHeader {
        var reader = VaultByteReader(data: data)
        guard try reader.read(Self.assetMagic.count) == Self.assetMagic else {
            throw VaultCryptoError.malformedEnvelope
        }
        guard try reader.readInteger(UInt16.self) == Self.formatVersion else {
            throw VaultCryptoError.unsupportedVersion
        }
        guard try reader.readInteger(UInt8.self) == expectedKind.rawValue else {
            throw VaultCryptoError.wrongAssetKind
        }
        _ = try reader.readInteger(UInt8.self)
        guard try reader.read(16) == expectedDocumentID.byteData else {
            throw VaultCryptoError.wrongDocument
        }
        let salt = try reader.read(32)
        let originalLength = try reader.readInteger(UInt64.self)
        let chunkSize = try reader.readInteger(UInt32.self)
        let chunkCount = try reader.readInteger(UInt32.self)
        guard reader.isAtEnd,
              chunkSize == UInt32(Self.chunkSize),
              chunkCount > 0,
              UInt64(chunkCount) == max(1, (originalLength + UInt64(chunkSize) - 1) / UInt64(chunkSize)) else {
            throw VaultCryptoError.malformedEnvelope
        }
        return AssetHeader(salt: salt, originalLength: originalLength, chunkSize: chunkSize, chunkCount: chunkCount)
    }

    private func deriveKey(
        rootKey: SymmetricKey,
        salt: Data,
        documentID: UUID,
        kind: VaultAssetKind
    ) -> SymmetricKey {
        var info = Data("DocScanner.Vault.Asset".utf8)
        info.append(documentID.byteData)
        info.appendInteger(kind.rawValue)
        info.appendInteger(Self.formatVersion)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: rootKey,
            salt: salt,
            info: info,
            outputByteCount: 32
        )
    }

    private func randomData(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "Secure random generation failed")
        return Data(bytes)
    }

    private func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw VaultCryptoError.truncatedEnvelope
        }
        return data
    }

    private func protectedTemporaryURL(nextTo destinationURL: URL) throws -> URL {
        let directory = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        return directory.appendingPathComponent(".\(UUID().uuidString).vault-tmp")
    }

    private func installVerifiedTemporary(_ temporaryURL: URL, at destinationURL: URL) throws {
        try fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: temporaryURL.path)
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
        try fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destinationURL.path)
    }
}

nonisolated private struct AssetHeader {
    let salt: Data
    let originalLength: UInt64
    let chunkSize: UInt32
    let chunkCount: UInt32
}

nonisolated private struct VaultByteReader {
    let data: Data
    private(set) var offset = 0

    var isAtEnd: Bool { offset == data.count }

    mutating func read(_ count: Int) throws -> Data {
        guard count >= 0, offset <= data.count - count else { throw VaultCryptoError.truncatedEnvelope }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    mutating func readInteger<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let bytes = try read(MemoryLayout<T>.size)
        return bytes.withUnsafeBytes { rawBuffer in
            rawBuffer.loadUnaligned(as: T.self).bigEndian
        }
    }
}

nonisolated private extension Data {
    static func integer<T: FixedWidthInteger>(_ value: T) -> Data {
        var value = value.bigEndian
        return Swift.withUnsafeBytes(of: &value) { Data($0) }
    }

    mutating func appendInteger<T: FixedWidthInteger>(_ value: T) {
        append(Self.integer(value))
    }

    func readInteger<T: FixedWidthInteger>(_ type: T.Type) -> T {
        withUnsafeBytes { $0.loadUnaligned(as: T.self).bigEndian }
    }
}

nonisolated private extension UUID {
    var byteData: Data {
        var bytes = uuid
        return Swift.withUnsafeBytes(of: &bytes) { Data($0) }
    }
}
