import Foundation

actor PhotoThumbnailHashCache {
    private let fileURL: URL
    private var entries: [String: ImageSimilaritySignature] = [:]
    private var loaded = false
    init(fileURL: URL) { self.fileURL = fileURL }
    func value(for photo: LibraryPhoto) -> ImageSimilaritySignature? {
        load()
        guard let key = photo.cacheKey else { return nil }
        return entries[key]
    }
    func insert(_ signature: ImageSimilaritySignature, for photo: LibraryPhoto) {
        load()
        guard let key = photo.cacheKey else { return }
        entries[key] = signature
    }
    func save(retaining photos: [LibraryPhoto]) throws {
        let keys = Set(photos.compactMap(\.cacheKey))
        entries = entries.filter { keys.contains($0.key) }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
    func clear() throws {
        entries.removeAll(); loaded = true
        do { try FileManager.default.removeItem(at: fileURL) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { return }
    }
    private func load() {
        guard !loaded else { return }; loaded = true
        // Bound corrupt/foreign cache input; cache failure is a miss, never a scan failure.
        if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size <= 32 * 1024 * 1024,
           let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: ImageSimilaritySignature].self, from: data) {
            entries = decoded
        }
    }
}

struct PhotoLibraryScanner: Sendable {
    static let maximumPhotos = 50_000
    static let batchSize = 200
    static let comparisonBudget = 3_200_000  // >= 50,000-photo cap x 64-photo window
    static let neighborWindow = 64
    static let captureWindowSeconds: TimeInterval = 24 * 60 * 60
    let provider: any PhotoLibraryProviding
    let cache: PhotoThumbnailHashCache

    func scan(limit: Int = Self.maximumPhotos,
              progress: @escaping @Sendable (Int) async -> Void = { _ in }) async throws -> LibraryPhotoScanResult {
        guard await provider.authorization().canRead else { throw PhotoLibraryError.permission }
        try Task.checkCancellation()
        let cap = max(0, min(limit, Self.maximumPhotos))
        let available = try await provider.begin(limit: cap)
        do {
            var photos: [LibraryPhoto] = []
            var signatures: [String: ImageSimilaritySignature] = [:]
            var missing = 0
            while photos.count < min(available, cap) {
                try Task.checkCancellation()
                let batch = try await provider.batch(offset: photos.count, count: min(Self.batchSize, cap - photos.count))
                guard !batch.isEmpty else { break }
                for photo in batch.prefix(cap - photos.count) {
                    try Task.checkCancellation()
                    photos.append(photo)
                    if let hit = await cache.value(for: photo) { signatures[photo.id] = hit }
                    else if let thumbnail = try await provider.thumbnail(for: photo, includePreview: false) {
                        signatures[photo.id] = thumbnail.signature
                        await cache.insert(thumbnail.signature, for: photo)
                    } else { missing += 1 }
                }
                await progress(photos.count)
            }
            let grouped = try Self.group(photos, signatures: signatures)
            let reviewed = try await provider.reviewMetadata(for: grouped.groups.flatMap(\.photos))
            let reviewByID = Dictionary(uniqueKeysWithValues: reviewed.map { ($0.id, $0) })
            let finalGroups = grouped.groups.map { group in
                let members = group.photos.map { reviewByID[$0.id] ?? $0 }
                return LibraryPhotoGroup(id: group.id, photos: members, evidence: group.evidence,
                                         keeperID: Self.preferredKeeper(members).id)
            }
            try Task.checkCancellation()
            guard await provider.authorization().canRead else {
                try await cache.clear()
                throw PhotoLibraryError.permission
            }
            // Cache errors do not conceal valid results. No photo data is logged.
            try? await cache.save(retaining: photos)
            await provider.finish()
            return .init(groups: finalGroups, processed: photos.count, available: available,
                         missingThumbnails: missing, comparisonLimited: grouped.limited)
        } catch {
            if !(await provider.authorization()).canRead { try? await cache.clear() }
            await provider.finish(); throw error
        }
    }

    static func preferredKeeper(_ photos: [LibraryPhoto]) -> LibraryPhoto {
        photos.sorted {
            let left = Int64($0.width) * Int64($0.height), right = Int64($1.width) * Int64($1.height)
            if $0.favorite != $1.favorite { return $0.favorite }
            if left != right { return left > right }
            if $0.edited != $1.edited { return $0.edited }
            if $0.creationDate != $1.creationDate { return ($0.creationDate ?? .distantFuture) < ($1.creationDate ?? .distantFuture) }
            return $0.id < $1.id
        }.first!
    }

    static func group(_ photos: [LibraryPhoto], signatures: [String: ImageSimilaritySignature], comparisonLimit: Int = PhotoLibraryScanner.comparisonBudget) throws -> (groups: [LibraryPhotoGroup], limited: Bool, comparisons: Int) {
        // Newest first. Similarity searches only the preceding 64 photos within 24 hours.
        // Unknown dates can only use the positional window, never metadata confirmation.
        let ordered = photos.sorted {
            if $0.creationDate != $1.creationDate { return ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
            return $0.id < $1.id
        }
        struct Key: Hashable { let width: Int; let height: Int; let date: Date; let evidence: String }
        var buckets: [Key: [Int]] = [:]
        for (position, photo) in ordered.enumerated() {
            try Task.checkCancellation()
            guard let date = photo.creationDate else { continue }
            let evidence = photo.resourceFingerprint.map { "fingerprint:" + $0 }
                ?? photo.fileSize.map { "size:" + String($0) } ?? "metadata"
            buckets[Key(width: photo.width, height: photo.height, date: date, evidence: evidence), default: []].append(position)
        }
        struct Seed { let photo: LibraryPhoto; let signature: ImageSimilaritySignature; var positions: [Int]; var lastPosition: Int }
        var groups: [LibraryPhotoGroup] = []
        var consumed = Set<Int>()
        var comparisons = 0, limited = false
        let budget = min(max(0, comparisonLimit), comparisonBudget)
        // Reserve half for newest-first similarity, so old metadata buckets cannot starve new photos.
        var phaseBudget = budget / 2
        func cluster(_ positions: [Int]) throws -> [Seed] {
            var seeds: [Seed] = []
            var active: [Int] = [] // At most 64 representatives; no per-photo Set/hash-band construction.
            for position in positions {
                try Task.checkCancellation()
                let photo = ordered[position]
                guard let signature = signatures[photo.id] else { continue }
                active.removeAll { position - seeds[$0].lastPosition > neighborWindow }
                var matched: Int?
                for candidate in active.reversed() {
                    let seed = seeds[candidate]
                    if let left = photo.creationDate, let right = seed.photo.creationDate,
                       abs(left.timeIntervalSince(right)) > captureWindowSeconds { continue }
                    guard comparisons < phaseBudget else { limited = true; break }
                    comparisons += 1
                    if ImageSimilarity.score(seed.signature, signature) != nil { matched = candidate; break }
                }
                if limited { break }
                if let matched {
                    seeds[matched].positions.append(position)
                    seeds[matched].lastPosition = position
                    active.removeAll { $0 == matched }
                    active.append(matched)
                } else {
                    active.append(seeds.count)
                    seeds.append(.init(photo: photo, signature: signature, positions: [position], lastPosition: position))
                }
            }
            return seeds
        }
        // Metadata alone cannot consume a photo: every member must match its seed thumbnail.
        for key in buckets.keys.sorted(by: { buckets[$0]!.first! < buckets[$1]!.first! }) {
            let positions = buckets[key]!
            guard positions.count > 1 else { continue }
            for seed in try cluster(positions) where seed.positions.count > 1 {
                let members = seed.positions.map { ordered[$0] }
                let keeper = preferredKeeper(members)
                let evidence: LibraryPhotoGroup.Evidence = key.evidence.hasPrefix("fingerprint:") ? .contentFingerprint
                    : key.evidence.hasPrefix("size:") ? .sizeAndDate : .metadata
                groups.append(.init(id: "duplicate:" + keeper.id, photos: members, evidence: evidence, keeperID: keeper.id))
                consumed.formUnion(seed.positions)
            }
            if limited { break }
        }
        let metadataLimited = limited
        limited = false
        phaseBudget = budget
        do {
            for seed in try cluster(ordered.indices.filter { !consumed.contains($0) }) where seed.positions.count > 1 {
                let members = seed.positions.map { ordered[$0] }
                groups.append(.init(id: "similar:" + seed.photo.id, photos: members, evidence: .similar,
                                    keeperID: preferredKeeper(members).id))
            }
        }
        return (groups, limited || metadataLimited, comparisons)
    }
}
