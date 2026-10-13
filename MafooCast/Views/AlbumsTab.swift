import Photos
import SwiftUI

struct AlbumsTab: View {
    @EnvironmentObject private var library: PhotoLibrary

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if library.sharedAlbums.isEmpty {
                        Text(library.status == .limited
                             ? "Shared Albums need Full Access. Settings › NazCast › Photos › Full Access."
                             : "No Shared Albums. Turn on Shared Albums in Settings › Photos.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(library.sharedAlbums) { album in
                        NavigationLink(value: album.id) { AlbumRow(album: album) }
                    }
                } header: {
                    Text("Shared Albums")
                }

                Section("My Albums") {
                    ForEach(library.myAlbums) { album in
                        NavigationLink(value: album.id) { AlbumRow(album: album) }
                    }
                }
            }
            .navigationTitle("Albums")
            .refreshable { library.reloadAlbums() }
            .navigationDestination(for: String.self) { id in
                if let album = (library.sharedAlbums + library.myAlbums).first(where: { $0.id == id }) {
                    AlbumDetail(album: album)
                }
            }
        }
        .castingBar()
    }
}

private struct AlbumRow: View {
    let album: Album
    @State private var count: Int?
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 14) {
            Color(.secondarySystemBackground)
                .frame(width: 56, height: 56)
                .overlay {
                    if let thumbnail {
                        Image(uiImage: thumbnail).resizable().scaledToFill()
                    } else {
                        Image(systemName: album.isShared ? "person.2" : "photo.on.rectangle")
                            .foregroundStyle(.secondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                if let count {
                    Text("\(count) item\(count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: album.id) {
            let assets = album.assets
            count = assets.count
            if !assets.isEmpty {
                thumbnail = await ImageLoader.thumbnail(for: assets[0], side: 120)
            }
        }
    }
}

private struct AlbumDetail: View {
    let album: Album
    @State private var assets = AssetList.empty
    @AppStorage("albumSort") private var sort: PhotoSort = .added

    var body: some View {
        SelectableAssetGrid(assets: assets, sort: $sort) {
            Text("Tap Select to add photos to a collection.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(album.id)|\(sort.rawValue)") { assets = album.assets(sort: sort) }
    }
}
