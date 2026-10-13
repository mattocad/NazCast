import Photos

/// An ordered list of photos/videos: either a lazy PhotoKit fetch (library, albums — can be huge)
/// or a plain array (collections, whose order is ours rather than PhotoKit's).
enum AssetList {
    case fetch(PHFetchResult<PHAsset>)
    case array([PHAsset])

    static let empty = AssetList.array([])

    var count: Int {
        switch self {
        case .fetch(let result): return result.count
        case .array(let assets): return assets.count
        }
    }

    subscript(index: Int) -> PHAsset {
        switch self {
        case .fetch(let result): return result.object(at: index)
        case .array(let assets): return assets[index]
        }
    }

    var isEmpty: Bool { count == 0 }

    /// Local identifiers of the assets in `ids`, in list order.
    func identifiers(in ids: Set<String>) -> [String] {
        guard !ids.isEmpty else { return [] }
        var result: [String] = []
        for i in 0..<count {
            let id = self[i].localIdentifier
            if ids.contains(id) { result.append(id) }
            if result.count == ids.count { break }
        }
        return result
    }

    var allIdentifiers: [String] {
        (0..<count).map { self[$0].localIdentifier }
    }
}

enum PhotoSort: String, Codable, CaseIterable, Identifiable {
    /// The order photos were added (album order, or the order you built a collection in).
    case added
    case newest
    case oldest

    var id: Self { self }

    var title: String {
        switch self {
        case .added: return "Order Added"
        case .newest: return "Newest First"
        case .oldest: return "Oldest First"
        }
    }

    var sortDescriptors: [NSSortDescriptor]? {
        switch self {
        case .added: return nil
        case .newest: return [NSSortDescriptor(key: "creationDate", ascending: false)]
        case .oldest: return [NSSortDescriptor(key: "creationDate", ascending: true)]
        }
    }

    /// Sorts an in-memory list by capture date. `.added` keeps the given order.
    func apply(to assets: [PHAsset]) -> [PHAsset] {
        switch self {
        case .added: return assets
        case .newest: return assets.sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        case .oldest: return assets.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        }
    }
}

extension PHFetchOptions {
    /// Photos and videos, including ones that live in iCloud Shared Albums.
    static func photosAndVideos(sort: PhotoSort = .added) -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
        options.predicate = NSPredicate(format: "mediaType == %d || mediaType == %d",
                                        PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        options.sortDescriptors = sort.sortDescriptors
        return options
    }
}
