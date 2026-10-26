import CryptoKit
import Foundation
import Security

/// D102 L7, L1, L2: the requirement each end of the fan-control channel sets
/// on the other, so the system checks every message. It names the peer, pins
/// the leaf certificate this side is signed with and, when that signature has
/// a Team ID, requires it too. Same text as FileOperationPeerRequirement in
/// FileOperationShared, which this module cannot import;
/// FanControlPeerRequirementTests compares the two.
public enum FanControlPeerRequirement {
    /// The app's requirement for the helper, made from the app's own
    /// signature. Nil for any other peer and for a process without a
    /// certificate (ad hoc or unsigned), so the caller does not connect. The
    /// helper makes its requirement from its startup signature instead, never
    /// from the file on disk, which an update may have replaced.
    public static func currentSigner(peerIdentifier: String) -> String? {
        guard peerIdentifier == StorageCleanerBuildIdentity.helperLabel else { return nil }
        var code: SecCode?; var staticCode: SecStaticCode?; var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any],
              let certificates = values[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        return expression(identifier: peerIdentifier, leafCertificate: SecCertificateCopyData(leaf) as Data,
                          teamIdentifier: values[kSecCodeInfoTeamIdentifier as String] as? String ?? "")
    }

    /// The requirement text. Without a Team ID (Apple's own system code) the
    /// Team ID clause is left out. Nil when the identifier or Team ID holds
    /// anything but the characters they are made of, so a quote can never
    /// end a string early, or when Security cannot parse the result.
    public static func expression(identifier: String, leafCertificate: Data, teamIdentifier: String) -> String? {
        guard !identifier.isEmpty,
              identifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
              teamIdentifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        let fingerprint = Insecure.SHA1.hash(data: leafCertificate).map { String(format: "%02x", $0) }.joined()
        var expression = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf = H\"\(fingerprint)\""
        if !teamIdentifier.isEmpty {
            expression += " and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess else { return nil }
        return expression
    }
}
