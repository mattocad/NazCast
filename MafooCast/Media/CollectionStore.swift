import Photos
import SwiftUI

/// A named, ordered set of photos to put on the TV. Items can come from anywhere —
/// the library, your albums, or Shared Albums.
struct CastCollection: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var assetIDs: [String]
    var created = Date()
    /// Optional so collections saved before sorting existed still load.
    var sort: PhotoSort?
}

/// Saves collections as JSON in Application Support.
@MainActor
final class CollectionStore: ObservableObject {
    @Published private(set) var collections: [CastCollection] = []

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("collections.json")
    }()

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([CastCollection].self, from: data) {
            collections = saved
        }
    }

    func collection(_ id: CastCollection.ID) -> CastCollection? {
        collections.first { $0.id == id }
    }

    @discardableResult
    func create(name: String, assetIDs: [String] = []) -> CastCollection {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let collection = CastCollection(name: trimmed.isEmpty ? "New Collection" : trimmed, assetIDs: Self.unique(assetIDs))
        collections.insert(collection, at: 0)
        save()
        return collection
    }

    /// Appends `assetIDs`, skipping ones already in the collection. Returns how many were added.
    @discardableResult
    func add(_ assetIDs: [String], to id: CastCollection.ID) -> Int {
        guard let i = collections.firstIndex(where: { $0.id == id }) else { return 0 }
        let existing = Set(collections[i].assetIDs)
        let new = Self.unique(assetIDs).filter { !existing.contains($0) }
        collections[i].assetIDs += new
        save()
        return new.count
    }

    func remove(_ assetIDs: Set<String>, from id: CastCollection.ID) {
        guard let i = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[i].assetIDs.removeAll { assetIDs.contains($0) }
        save()
    }

    func rename(_ id: CastCollection.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[i].name = trimmed
        save()
    }

    func setSort(_ sort: PhotoSort, for id: CastCollection.ID) {
        guard let i = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[i].sort = sort
        save()
    }

    func delete(_ id: CastCollection.ID) {
        collections.removeAll { $0.id == id }
        save()
    }

    /// The collection's photos, in its chosen sort order. Items that no longer exist (deleted, or
    /// the Shared Album was left) are skipped.
    static func assets(for collection: CastCollection) -> AssetList {
        guard !collection.assetIDs.isEmpty else { return .empty }
        let options = PHFetchOptions()
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
        let result = PHAsset.fetchAssets(withLocalIdentifiers: collection.assetIDs, options: options)
        var byID: [String: PHAsset] = [:]
        result.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }
        return .array((collection.sort ?? .added).apply(to: collection.assetIDs.compactMap { byID[$0] }))
    }

    private func save() {
        do {
            try JSONEncoder().encode(collections).write(to: fileURL, options: .atomic)
        } catch {
            print("Couldn't save collections: \(error)")
        }
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}
