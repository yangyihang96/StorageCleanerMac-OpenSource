import CryptoKit
import Foundation

enum SignedRegistryLoadError: Error, Equatable, LocalizedError, Sendable {
    case envelopeTooLarge
    case malformedEnvelope
    case payloadTooLarge
    case unknownKey(String)
    case keyIdentifierMismatch
    case invalidPublicKey
    case invalidSignature
    case unsupportedSchema(Int)
    case invalidSequence
    case replayedSequence
    case invalidValidityWindow
    case issuedInFuture
    case expired
    case tooManyEntries
    case invalidEntry(String)

    var errorDescription: String? {
        switch self {
        case .envelopeTooLarge: return L10n.text("来源注册表文件过大。", "The source registry envelope is too large.")
        case .malformedEnvelope: return L10n.text("来源注册表格式无效。", "The source registry envelope is malformed.")
        case .payloadTooLarge: return L10n.text("来源注册表负载过大。", "The source registry payload is too large.")
        case let .unknownKey(key): return OfficialUpdateLocalization.format("来源注册表使用未知密钥 %@。", "The source registry uses unknown key %@.", key)
        case .keyIdentifierMismatch: return L10n.text("来源注册表密钥标识不一致。", "The source registry key identifiers do not match.")
        case .invalidPublicKey: return L10n.text("来源注册表公钥无效。", "The source registry public key is invalid.")
        case .invalidSignature: return L10n.text("来源注册表数字签名无效。", "The source registry signature is invalid.")
        case let .unsupportedSchema(version): return OfficialUpdateLocalization.format("不支持来源注册表 schema %lld。", "Unsupported source registry schema %lld.", Int64(version))
        case .invalidSequence: return L10n.text("来源注册表序列号无效。", "The source registry sequence is invalid.")
        case .replayedSequence: return L10n.text("拒绝使用较旧的来源注册表。", "An older source registry was rejected.")
        case .invalidValidityWindow: return L10n.text("来源注册表有效期无效。", "The source registry validity window is invalid.")
        case .issuedInFuture: return L10n.text("来源注册表的签发时间在未来。", "The source registry issue date is in the future.")
        case .expired: return L10n.text("来源注册表已过期。", "The source registry has expired.")
        case .tooManyEntries: return L10n.text("来源注册表条目过多。", "The source registry contains too many entries.")
        case let .invalidEntry(identifier): return OfficialUpdateLocalization.format("来源注册表条目 %@ 无效。", "Source registry entry %@ is invalid.", identifier)
        }
    }
}

enum SignedRegistryLoadDisposition: String, Sendable {
    case acceptedRemote
    case retainedLastKnownGood
}

struct SignedRegistryLoadOutcome: Sendable {
    let snapshot: OfficialSourceRegistrySnapshot
    let disposition: SignedRegistryLoadDisposition
    let remoteRejection: SignedRegistryLoadError?
}

struct SignedRegistryLoader: Sendable {
    let trustedPublicKeys: [String: Data]
    let supportedSchemaVersion: Int
    let maximumEnvelopeBytes: Int
    let maximumPayloadBytes: Int
    let maximumEntries: Int
    let maximumValidityInterval: TimeInterval
    let futureClockSkewAllowance: TimeInterval

    init(
        trustedPublicKeys: [String: Data],
        supportedSchemaVersion: Int = 1,
        maximumEnvelopeBytes: Int = 6 * 1_024 * 1_024,
        maximumPayloadBytes: Int = 4 * 1_024 * 1_024,
        maximumEntries: Int = 10_000,
        maximumValidityInterval: TimeInterval = 180 * 24 * 60 * 60,
        futureClockSkewAllowance: TimeInterval = 5 * 60
    ) {
        self.trustedPublicKeys = trustedPublicKeys
        self.supportedSchemaVersion = supportedSchemaVersion
        self.maximumEnvelopeBytes = maximumEnvelopeBytes
        self.maximumPayloadBytes = maximumPayloadBytes
        self.maximumEntries = maximumEntries
        self.maximumValidityInterval = maximumValidityInterval
        self.futureClockSkewAllowance = futureClockSkewAllowance
    }

    func load(
        envelopeData: Data,
        lastKnownGood: OfficialSourceRegistrySnapshot? = nil,
        now: Date = Date()
    ) throws -> SignedRegistryLoadOutcome {
        do {
            let snapshot = try verify(envelopeData: envelopeData, lastKnownGood: lastKnownGood, now: now)
            return SignedRegistryLoadOutcome(
                snapshot: snapshot,
                disposition: .acceptedRemote,
                remoteRejection: nil
            )
        } catch let error as SignedRegistryLoadError {
            if let lastKnownGood,
               !lastKnownGood.isExpired,
               lastKnownGood.payload.schemaVersion == supportedSchemaVersion,
               lastKnownGood.payload.expiresAt > now {
                return SignedRegistryLoadOutcome(
                    snapshot: lastKnownGood,
                    disposition: .retainedLastKnownGood,
                    remoteRejection: error
                )
            }
            throw error
        }
    }

    func verify(
        envelopeData: Data,
        lastKnownGood: OfficialSourceRegistrySnapshot? = nil,
        now: Date = Date()
    ) throws -> OfficialSourceRegistrySnapshot {
        guard envelopeData.count <= maximumEnvelopeBytes else {
            throw SignedRegistryLoadError.envelopeTooLarge
        }
        let envelope: SignedOfficialSourceRegistry
        do {
            envelope = try JSONDecoder().decode(SignedOfficialSourceRegistry.self, from: envelopeData)
        } catch {
            throw SignedRegistryLoadError.malformedEnvelope
        }
        guard envelope.payload.count <= maximumPayloadBytes else {
            throw SignedRegistryLoadError.payloadTooLarge
        }
        guard let rawKey = trustedPublicKeys[envelope.keyID] else {
            throw SignedRegistryLoadError.unknownKey(envelope.keyID)
        }
        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: rawKey)
        } catch {
            throw SignedRegistryLoadError.invalidPublicKey
        }
        guard envelope.signature.count == 64,
              publicKey.isValidSignature(envelope.signature, for: envelope.payload) else {
            throw SignedRegistryLoadError.invalidSignature
        }

        let payload: OfficialSourceRegistryPayload
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            payload = try decoder.decode(OfficialSourceRegistryPayload.self, from: envelope.payload)
        } catch {
            throw SignedRegistryLoadError.malformedEnvelope
        }
        guard payload.keyID == envelope.keyID else { throw SignedRegistryLoadError.keyIdentifierMismatch }
        guard payload.schemaVersion == supportedSchemaVersion else {
            throw SignedRegistryLoadError.unsupportedSchema(payload.schemaVersion)
        }
        guard payload.sequence > 0 else { throw SignedRegistryLoadError.invalidSequence }
        if let lastKnownGood, payload.sequence < lastKnownGood.payload.sequence {
            throw SignedRegistryLoadError.replayedSequence
        }
        guard payload.issuedAt <= now.addingTimeInterval(futureClockSkewAllowance) else {
            throw SignedRegistryLoadError.issuedInFuture
        }
        let validity = payload.expiresAt.timeIntervalSince(payload.issuedAt)
        guard validity > 0, validity <= maximumValidityInterval else {
            throw SignedRegistryLoadError.invalidValidityWindow
        }
        guard payload.expiresAt > now else { throw SignedRegistryLoadError.expired }
        guard payload.entries.count <= maximumEntries else { throw SignedRegistryLoadError.tooManyEntries }
        for entry in payload.entries {
            try validate(entry: entry)
        }
        return OfficialSourceRegistrySnapshot(payload: payload, verifiedAt: now, isExpired: false)
    }

    private func validate(entry: OfficialSourceRegistryEntry) throws {
        let identifier = entry.bundleIdentifier.trimmed
        guard !identifier.isEmpty,
              entry.homepageURL.scheme?.lowercased() == "https",
              entry.bundleIdentifier == identifier,
              entry.signingTeamIdentifier?.trimmed.nonEmpty != nil
                || entry.codeSigningIdentifier?.trimmed.nonEmpty != nil
                || entry.expectedDesignatedRequirement?.trimmed.nonEmpty != nil,
              !entry.allowedHosts.isEmpty else {
            throw SignedRegistryLoadError.invalidEntry(identifier)
        }
        do {
            let validator = AllowedHostValidator()
            try validator.validate(entry.homepageURL, allowedHosts: entry.allowedHosts)
            for url in [entry.updatePageURL, entry.releaseFeedURL, entry.directDownloadURL].compactMap({ $0 }) {
                try validator.validate(url, allowedHosts: entry.allowedHosts)
            }
        } catch {
            throw SignedRegistryLoadError.invalidEntry(identifier)
        }

        let extensions = Set(entry.expectedPackageExtensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
        guard extensions.isSubset(of: PackageTypeValidator.supportedExtensions) else {
            throw SignedRegistryLoadError.invalidEntry(identifier)
        }
        if let directDownloadURL = entry.directDownloadURL {
            do {
                _ = try PackageTypeValidator().validateRemoteURL(
                    directDownloadURL,
                    expectedExtensions: extensions
                )
            } catch {
                throw SignedRegistryLoadError.invalidEntry(identifier)
            }
        }
    }
}
