import Foundation

/// Derived only. The existing history repository owns this sidecar transaction.
struct MSeriesV11DerivedCache: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let key: String
        let sessionID: UUID
        let rawPayloadSHA256: String
        let originalCompletedAt: Date?
        let originalReference: MSeriesReferenceIdentity?
        let scores: MSeriesV11Scores
    }
    let referenceIdentity: MSeriesReferenceIdentity
    let entries: [Entry]
    let previousSnapshots: [Entry]

    static func key(sessionID: UUID, rawSHA256: String, reference: MSeriesReferenceIdentity) -> String {
        [sessionID.uuidString, rawSHA256, MSeriesScoringV11.version,
         reference.version ?? "unavailable", reference.sha256 ?? "unavailable"].joined(separator: "+")
    }
}
