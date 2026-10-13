import Foundation
import SwiftUI

/// D70 approved option artwork. PNG preserves the approved exports' alpha;
/// the sandbox's HEIC encoder failed (see the B2 handoff). Same loader as D58.
enum LightfieldOptionIcon: String, CaseIterable, Sendable {
    case benchmarkCpu = "opt-benchmark-cpu"
    case benchmarkGpu = "opt-benchmark-gpu"
    case benchmarkMemory = "opt-benchmark-memory"
    case benchmarkStorage = "opt-benchmark-storage"
    case cleanupDownloadRemnants = "opt-cleanup-download-remnants"
    case cleanupLogs = "opt-cleanup-logs"
    case cleanupSystemCache = "opt-cleanup-system-cache"
    case cleanupTemporaryFiles = "opt-cleanup-temporary-files"
    case devcachesActivityThreshold = "opt-devcaches-activity-threshold"
    case devcachesAgent = "opt-devcaches-agent"
    case devcachesArtifacts = "opt-devcaches-artifacts"
    case devcachesProjects = "opt-devcaches-projects"
    case devcachesSessions = "opt-devcaches-sessions"
    case duplicatesAddFolder = "opt-duplicates-add-folder"
    case duplicatesAudio = "opt-duplicates-audio"
    case duplicatesExternalVolume = "opt-duplicates-external-volume"
    case duplicatesPhotos = "opt-duplicates-photos"
    case duplicatesSelectedLocation = "opt-duplicates-selected-location"
    case duplicatesUserData = "opt-duplicates-user-data"
    case duplicatesUserFiles = "opt-duplicates-user-files"
    case duplicatesVideos = "opt-duplicates-videos"
    case energyAttribution = "opt-energy-attribution"
    case energyBackground = "opt-energy-background"
    case energyBaseline = "opt-energy-baseline"
    case energyBattery = "opt-energy-battery"
    case energyEnergy = "opt-energy-energy"
    case energyPreview = "opt-energy-preview"
    case energyProcesses = "opt-energy-processes"
    case energySampling = "opt-energy-sampling"
    case energySummary = "opt-energy-summary"
    case energyThermals = "opt-energy-thermals"
    case fileanalysisArchives = "opt-fileanalysis-archives"
    case fileanalysisDocuments = "opt-fileanalysis-documents"
    case fileanalysisMedia = "opt-fileanalysis-media"
    case fileanalysisOther = "opt-fileanalysis-other"
    case healthBattery = "opt-health-battery"
    case healthDisk = "opt-health-disk"
    case healthSystemState = "opt-health-system-state"
    case memoryApplication = "opt-memory-application"
    case memoryMemory = "opt-memory-memory"
    case memoryPressure = "opt-memory-pressure"
    case memorySwap = "opt-memory-swap"
    case migrationApplication = "opt-migration-application"
    case migrationDestinationDrive = "opt-migration-destination-drive"
    case migrationDocuments = "opt-migration-documents"
    case migrationItemType = "opt-migration-item-type"
    case migrationMove = "opt-migration-move"
    case migrationSourceFolder = "opt-migration-source-folder"
    case migrationVerification = "opt-migration-verification"
    case privacyConfirm = "opt-privacy-confirm"
    case privacyGrouping = "opt-privacy-grouping"
    case privacyPrivacy = "opt-privacy-privacy"
    case privacySearch = "opt-privacy-search"
    case privacyTimeline = "opt-privacy-timeline"
    case privacyWebsite = "opt-privacy-website"
    case scanCleanupCandidates = "opt-scan-cleanup-candidates"
    case scanHealthCheck = "opt-scan-health-check"
    case scanReviewFiles = "opt-scan-review-files"
    case startupBackground = "opt-startup-background"
    case startupLogin = "opt-startup-login"
    case startupStartupAgent = "opt-startup-startup-agent"
    case startupSystemItems = "opt-startup-system-items"
    case uninstallApplication = "opt-uninstall-application"
    case uninstallContainers = "opt-uninstall-containers"
    case uninstallRelatedFiles = "opt-uninstall-related-files"
    case uninstallSupportFiles = "opt-uninstall-support-files"
    case updaterPackages = "opt-updater-packages"
    case updaterStore = "opt-updater-store"
    case updaterUpdateFeed = "opt-updater-update-feed"
    case updaterWebsite = "opt-updater-website"

    enum Variant: Int, CaseIterable, Sendable { case twoX = 56, threeX = 84 }
    static let pointSize: CGFloat = 28
    func resourceName(_ variant: Variant) -> String { "\(rawValue)-\(variant.rawValue)" }
    static func variant(displayScale: CGFloat) -> Variant { displayScale > 2 ? .threeX : .twoX }
    /// Larger draws (e.g. a 32 pt bubble icon at 2x needs 64 px) use the 84 px
    /// export instead of upscaling the 56 px one (B2 review P2-7).
    static func variant(pointSize: CGFloat, displayScale: CGFloat) -> Variant {
        pointSize * max(1, displayScale) > CGFloat(Variant.twoX.rawValue) + 0.5 ? .threeX : .twoX
    }
    static let library = GeneratedArtLibrary(resolver: .lightfieldOptionsBundle())
}

extension GeneratedArtResolver {
    static func lightfieldOptionsBundle(_ bundleURL: URL = Bundle.main.bundleURL) -> Self {
        Self { name in
            Bundle(url: bundleURL)?.url(forResource: name, withExtension: "png",
                                       subdirectory: GeneratedArt.resourceDirectory)
        }
    }
    static func lightfieldOptionsDirectory(_ directory: URL) -> Self {
        Self { name in
            let url = directory.appendingPathComponent(name).appendingPathExtension("png")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }
}
