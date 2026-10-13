import Photos
import SwiftUI

struct CollectionsTab: View {
    @EnvironmentObject private var store: CollectionStore
    @State private var showNew = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            Group {
                if store.collections.isEmpty {
                    ContentUnavailableView {
                        Label("No collections yet", systemImage: "sparkles.tv")
                    } description: {
                        Text("Open Library or Albums (including Shared Albums), tap Select, pick photos, then tap Add.")
                    } actions: {
                        Button("New Collection") { showNew = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(store.collections) { collection in
                            NavigationLink(value: collection.id) { CollectionRow(collection: collection) }
                        }
                        .onDelete { offsets in
                            offsets.map { store.collections[$0].id }.forEach(store.delete)
                        }
                    }
                }
            }
            .navigationTitle("Collections")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNew = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New collection")
                }
            }
            .navigationDestination(for: UUID.self) { id in CollectionDetail(id: id) }
            .alert("New Collection", isPresented: $showNew) {
                TextField("Name", text: $newName)
                Button("Create") { store.create(name: newName); newName = "" }
                Button("Cancel", role: .cancel) { newName = "" }
            }
        }
        .castingBar()
    }
}

private struct CollectionRow: View {
    let collection: CastCollection
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 14) {
            Color(.secondarySystemBackground)
                .frame(width: 56, height: 56)
                .overlay {
                    if let thumbnail {
                        Image(uiImage: thumbnail).resizable().scaledToFill()
                    } else {
                        Image(systemName: "sparkles.tv").foregroundStyle(.secondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(collection.name)
                Text("\(collection.assetIDs.count) item\(collection.assetIDs.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: collection.assetIDs.first) {
            let assets = CollectionStore.assets(for: CastCollection(name: "", assetIDs: Array(collection.assetIDs.prefix(1))))
            thumbnail = assets.isEmpty ? nil : await ImageLoader.thumbnail(for: assets[0], side: 120)
        }
    }
}

private struct CollectionDetail: View {
    let id: CastCollection.ID
    @EnvironmentObject private var store: CollectionStore
    @EnvironmentObject private var cast: CastController
    @Environment(\.dismiss) private var dismiss
    @State private var assets = AssetList.empty
    @State private var slideshow: ViewerTarget?
    @State private var showRename = false
    @State private var renameText = ""
    @State private var confirmDelete = false

    var body: some View {
        if let collection = store.collection(id) {
            SelectableAssetGrid(assets: assets, loops: true, action: .removeFromCollection(id), sort: Binding(
                get: { collection.sort ?? .added },
                set: { store.setSort($0, for: id) }
            )) {
                VStack(spacing: 8) {
                    Button { startSlideshow() } label: {
                        Label("Play Slideshow on TV", systemImage: "play.tv.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(assets.isEmpty)

                    Text(caption(for: collection))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal)
            }
            .navigationTitle(collection.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .secondaryAction) {
                    Button { renameText = collection.name; showRename = true } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Delete Collection", systemImage: "trash")
                    }
                }
            }
            .task(id: collection) { assets = CollectionStore.assets(for: collection) }
            .fullScreenCover(item: $slideshow) { target in
                ViewerView(assets: assets, startIndex: target.index, slideshow: true, loops: true)
            }
            .alert("Rename Collection", isPresented: $showRename) {
                TextField("Name", text: $renameText)
                Button("Save") { store.rename(id, to: renameText) }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete “\(collection.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Collection", role: .destructive) {
                    store.delete(id)
                    dismiss()
                }
            } message: {
                Text("Your photos stay in your library and albums.")
            }
        }
    }

    private func caption(for collection: CastCollection) -> String {
        if collection.assetIDs.isEmpty {
            return "Empty. Add photos from Library or Albums using Select."
        }
        var parts = ["\(assets.count) item\(assets.count == 1 ? "" : "s")"]
        let missing = collection.assetIDs.count - assets.count
        if missing > 0 { parts.append("\(missing) no longer available") }
        if cast.selected == nil { parts.append("connect a TV with the TV button") }
        parts.append((collection.sort ?? .added).title.lowercased())
        parts.append("slideshow loops and skips videos")
        return parts.joined(separator: " · ")
    }

    private func startSlideshow() {
        let firstPhoto = (0..<assets.count).first { !assets[$0].isVideo } ?? 0
        slideshow = ViewerTarget(index: firstPhoto)
    }
}
