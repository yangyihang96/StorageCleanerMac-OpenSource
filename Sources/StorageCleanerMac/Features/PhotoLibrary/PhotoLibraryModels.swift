import Foundation

// No destructive operation exists in this boundary.
protocol PhotoLibraryProviding: Sendable {
    func authorization() async -> PhotoLibraryAuthorization
    func requestAuthorization() async -> PhotoLibraryAuthorization
    func begin(limit: Int) async throws -> Int
    func batch(offset: Int, count: Int) async throws -> [LibraryPhoto]
    func thumbnail(for photo: LibraryPhoto, includePreview: Bool) async throws -> LibraryPhotoThumbnail?
    func reviewMetadata(for photos: [LibraryPhoto]) async throws -> [LibraryPhoto]
    func finish() async
    func addToReviewAlbum(identifiers: [String]) async throws -> Int
}

extension PhotoLibraryProviding {
    func reviewMetadata(for photos: [LibraryPhoto]) async throws -> [LibraryPhoto] { photos }
}

enum PhotoLibraryAuthorization: String, Sendable, CaseIterable {
    case notDetermined, restricted, denied, limited, authorized
    var canRead: Bool { self == .authorized || self == .limited }
    var canAddToAlbum: Bool { self == .authorized }
    var message: String {
        switch self {
        case .notDetermined: L10n.text("尚未授权。点击授权后仅读取元数据与本地小缩略图。读写权限用于创建待删除相册和加入照片。", "Not authorized. Access reads metadata and small local thumbnails. Read/write access is needed to create the review album and add photos.")
        case .restricted: L10n.text("系统限制照片访问。请检查系统设置或设备管理限制。", "Photo access is restricted. Check System Settings or device management restrictions.")
        case .denied: L10n.text("照片访问已拒绝。请在系统设置中开启；不会再次弹出授权。", "Photo access was denied. Enable it in System Settings; permission will not be requested again.")
        case .limited: L10n.text("受限授权：仅处理您允许访问的照片，结果不代表完整图库。受限授权下不能加入相册，请到系统设置开启完整访问。", "Limited access: only permitted photos are processed; results do not cover the full library. Album addition is disabled until full access is enabled in System Settings.")
        case .authorized: L10n.text("已授权。扫描只读，不上传、不读取原图或位置，不下载云端原图。", "Authorized. Scanning is read-only: no uploads, original image or location reads, or cloud original downloads.")
        }
    }
}

struct LibraryPhoto: Identifiable, Sendable, Equatable {
    let id: String
    let width: Int
    let height: Int
    let creationDate: Date?
    let modificationDate: Date?
    let favorite: Bool
    let edited: Bool
    // Optional evidence for providers that can supply it without reading originals.
    // The PhotoKit provider intentionally leaves both nil: no private KVC fileSize.
    var fileSize: Int64? = nil
    var resourceFingerprint: String? = nil
    var cacheKey: String? {
        modificationDate.map { id + "|" + String($0.timeIntervalSinceReferenceDate) + "|similarity-v1" }
    }
}
struct LibraryPhotoThumbnail: Sendable {
    let signature: ImageSimilaritySignature
    let preview: Data
}
struct LibraryPhotoGroup: Identifiable, Sendable {
    enum Evidence: Sendable, Equatable { case contentFingerprint, sizeAndDate, metadata, similar }
    let id: String
    let photos: [LibraryPhoto]
    let evidence: Evidence
    let keeperID: String
    var title: String {
        switch evidence {
        case .contentFingerprint: L10n.text("完全重复（资源指纹确认）", "Exact duplicates (resource fingerprint confirmed)")
        case .sizeAndDate: L10n.text("重复候选（尺寸、时间、大小一致）", "Duplicate candidates (dimensions, date and size match)")
        case .metadata: L10n.text("重复候选（尺寸、拍摄时间一致）", "Duplicate candidates (dimensions and capture date match)")
        case .similar: L10n.text("相似照片（缩略图比对）", "Similar photos (thumbnail comparison)")
        }
    }
}
struct LibraryPhotoScanResult: Sendable {
    let groups: [LibraryPhotoGroup]
    let processed: Int
    let available: Int
    let missingThumbnails: Int
    let comparisonLimited: Bool
    var truncated: Bool { available > processed }
}
enum PhotoLibraryError: Error { case permission, unavailable, albumChangeFailed }
