import Photos
import SwiftUI

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "All", photos = "Photos", videos = "Videos"
    var id: Self { self }
}

struct Album: Identifiable {
    let collection: PHAssetCollection
    let isShared: Bool

    var id: String { collection.localIdentifier }
    var title: String { collection.localizedTitle ?? "Untitled" }
    var assets: AssetList { assets(sort: .added) }

    func assets(sort: PhotoSort) -> AssetList {
        .fetch(PHAsset.fetchAssets(in: collection, options: .photosAndVideos(sort: sort)))
    }
}

@MainActor
final class PhotoLibrary: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published private(set) var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published private(set) var assets = PHFetchResult<PHAsset>()
    @Published private(set) var myAlbums: [Album] = []
    @Published private(set) var sharedAlbums: [Album] = []
    @Published var filter: LibraryFilter = .all {
        didSet { reload() }
    }
    /// Newest or oldest first (the library has no "order added").
    @Published var sort: PhotoSort = PhotoSort(rawValue: UserDefaults.standard.string(forKey: "librarySort") ?? "") ?? .newest {
        didSet {
            UserDefaults.standard.set(sort.rawValue, forKey: "librarySort")
            reload()
        }
    }

    override init() {
        super.init()
        if status == .authorized || status == .limited { start() }
    }

    func requestAccess() async {
        status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if status == .authorized || status == .limited { start() }
    }

    private func start() {
        PHPhotoLibrary.shared().register(self)
        reload()
        reloadAlbums()
    }

    var list: AssetList { .fetch(assets) }

    func reloadAlbums() {
        func albums(_ type: PHAssetCollectionType, _ subtype: PHAssetCollectionSubtype, shared: Bool = false) -> [Album] {
            var result: [Album] = []
            PHAssetCollection.fetchAssetCollections(with: type, subtype: subtype, options: nil)
                .enumerateObjects { collection, _, _ in result.append(Album(collection: collection, isShared: shared)) }
            return result
        }
        myAlbums = albums(.smartAlbum, .smartAlbumFavorites)
            + albums(.album, .albumRegular).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        sharedAlbums = albums(.album, .albumCloudShared, shared: true)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func reload() {
        let options = PHFetchOptions()
        options.sortDescriptors = (sort == .added ? PhotoSort.newest : sort).sortDescriptors
        switch filter {
        case .all:
            options.predicate = NSPredicate(format: "mediaType == %d || mediaType == %d",
                                            PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        case .photos:
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        case .videos:
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        }
        assets = PHAsset.fetchAssets(with: options)
    }

    nonisolated func photoLibraryDidChange(_ change: PHChange) {
        Task { @MainActor in
            if let details = change.changeDetails(for: self.assets) {
                self.assets = details.fetchResultAfterChanges
            }
            self.reloadAlbums()
        }
    }
}

extension PHAsset {
    var isVideo: Bool { mediaType == .video }

    var durationText: String {
        let s = Int(duration.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
