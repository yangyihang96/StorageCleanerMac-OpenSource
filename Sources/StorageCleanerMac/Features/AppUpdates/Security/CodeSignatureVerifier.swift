import Foundation
import Security

struct CodeSignatureVerificationResult: Hashable, Sendable {
    let isValid: Bool
    let codeSigningIdentifier: String?
    let teamIdentifier: String?
    let designatedRequirement: String?
    let certificateCommonNames: [String]
    let status: OSStatus
}

enum CodeSignatureVerificationError: Error, Equatable, LocalizedError, Sendable {
    case targetDoesNotExist
    case cannotCreateStaticCode(OSStatus)
    case invalidSignature(OSStatus)
    case cannotReadSigningInformation(OSStatus)

    var errorDescription: String? {
        switch self {
        case .targetDoesNotExist:
            return L10n.text("找不到要验证的应用或安装包。", "The app or package to verify does not exist.")
        case let .cannotCreateStaticCode(status):
            return OfficialUpdateLocalization.format("无法读取代码签名（%lld）。", "Unable to read the code signature (%lld).", Int64(status))
        case let .invalidSignature(status):
            return OfficialUpdateLocalization.format("代码签名验证失败（%lld）。", "Code signature validation failed (%lld).", Int64(status))
        case let .cannotReadSigningInformation(status):
            return OfficialUpdateLocalization.format("无法读取签名身份（%lld）。", "Unable to read signing identity information (%lld).", Int64(status))
        }
    }
}

struct CodeSignatureVerifier: Sendable {
    /// Security.framework validates the static code object and every Mach-O slice.
    /// No `codesign` subprocess or shell parsing is involved.
    func verifyCode(at url: URL) throws -> CodeSignatureVerificationResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CodeSignatureVerificationError.targetDoesNotExist
        }

        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            throw CodeSignatureVerificationError.cannotCreateStaticCode(createStatus)
        }

        let validationFlags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        let validationStatus = SecStaticCodeCheckValidity(staticCode, validationFlags, nil)
        guard validationStatus == errSecSuccess else {
            throw CodeSignatureVerificationError.invalidSignature(validationStatus)
        }

        var rawInformation: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &rawInformation
        )
        guard informationStatus == errSecSuccess,
              let information = rawInformation as? [String: Any] else {
            throw CodeSignatureVerificationError.cannotReadSigningInformation(informationStatus)
        }

        let identifier = information[kSecCodeInfoIdentifier as String] as? String
        let teamIdentifier = information[kSecCodeInfoTeamIdentifier as String] as? String
        let requirement = Self.requirementString(from: information[kSecCodeInfoDesignatedRequirement as String])
        let certificates = (information[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? [])
            .compactMap(Self.commonName)

        return CodeSignatureVerificationResult(
            isValid: true,
            codeSigningIdentifier: identifier,
            teamIdentifier: teamIdentifier,
            designatedRequirement: requirement,
            certificateCommonNames: certificates,
            status: validationStatus
        )
    }

    private static func requirementString(from rawValue: Any?) -> String? {
        guard let rawValue else { return nil }
        let cfValue = rawValue as CFTypeRef
        guard CFGetTypeID(cfValue) == SecRequirementGetTypeID() else { return nil }
        let requirement = unsafeDowncast(cfValue, to: SecRequirement.self)
        var text: CFString?
        guard SecRequirementCopyString(requirement, SecCSFlags(), &text) == errSecSuccess else { return nil }
        return text as String?
    }

    private static func commonName(_ certificate: SecCertificate) -> String? {
        var name: CFString?
        guard SecCertificateCopyCommonName(certificate, &name) == errSecSuccess else { return nil }
        return name as String?
    }
}
