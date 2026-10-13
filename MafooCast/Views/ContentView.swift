import Photos
import SwiftUI

struct ViewerTarget: Identifiable {
    let index: Int
    var id: Int { index }
}

struct ContentView: View {
    @StateObject private var library = PhotoLibrary()
    @StateObject private var collections = CollectionStore()

    var body: some View {
        Group {
            switch library.status {
            case .authorized, .limited:
                TabView {
                    LibraryTab()
                        .tabItem { Label("Library", systemImage: "photo.on.rectangle") }
                    AlbumsTab()
                        .tabItem { Label("Albums", systemImage: "rectangle.stack") }
                    CollectionsTab()
                        .tabItem { Label("Collections", systemImage: "sparkles.tv") }
                }
            case .notDetermined:
                ProgressView().task { await library.requestAccess() }
            default:
                ContentUnavailableView {
                    Label("Photo access needed", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("Allow NazCast to see your photos so you can show them on your TV.")
                } actions: {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .environmentObject(library)
        .environmentObject(collections)
    }
}

struct LibraryTab: View {
    @EnvironmentObject private var library: PhotoLibrary
    @EnvironmentObject private var cast: CastController
    @State private var showPicker = false

    var body: some View {
        NavigationStack {
            SelectableAssetGrid(assets: library.list, sort: $library.sort, sortOptions: [.newest, .oldest]) {
                VStack(spacing: 12) {
                    Picker("Show", selection: $library.filter) {
                        ForEach(LibraryFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    if cast.selected == nil {
                        Button { showPicker = true } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "tv.badge.wifi").font(.title2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Connect to your TV").font(.headline)
                                    Text("Pick your Samsung TV to start casting.")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .padding()
                            .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
            .navigationTitle("NazCast")
            .sheet(isPresented: $showPicker) { DevicePickerView() }
        }
        .castingBar()
    }
}

struct AssetThumbnail: View {
    let asset: PHAsset
    /// nil when not in select mode.
    var isSelected: Bool? = nil
    @EnvironmentObject private var cast: CastController
    @State private var image: UIImage?

    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if asset.isVideo {
                    Text(asset.durationText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(4)
                }
            }
            .overlay {
                if cast.castingAssetID == asset.localIdentifier {
                    ZStack(alignment: .topLeading) {
                        Rectangle().strokeBorder(.tint, lineWidth: 3)
                        Image(systemName: "tv.fill")
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(.tint, in: RoundedRectangle(cornerRadius: 4))
                            .padding(4)
                    }
                }
            }
            .overlay {
                if let isSelected {
                    ZStack(alignment: .bottomTrailing) {
                        Color.white.opacity(isSelected ? 0.25 : 0)
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, isSelected ? Color.accentColor : Color.black.opacity(0.25))
                            .shadow(radius: 1)
                            .padding(5)
                    }
                }
            }
            .task(id: asset.localIdentifier) {
                image = await ImageLoader.thumbnail(for: asset, side: 240)
            }
    }
}

struct TVButton: View {
    @EnvironmentObject private var cast: CastController
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: cast.selected == nil ? "tv" : "tv.fill")
                if let tv = cast.selected {
                    Text(tv.name).lineLimit(1).frame(maxWidth: 140)
                }
            }
            .font(.subheadline.weight(.medium))
        }
        .accessibilityLabel(cast.selected.map { "Connected to \($0.name)" } ?? "Choose a TV")
    }
}

extension View {
    /// Shows the "Showing on TV" bar at the bottom while something is on the TV.
    func castingBar() -> some View { modifier(CastingBarModifier()) }
}

private struct CastingBarModifier: ViewModifier {
    @EnvironmentObject private var cast: CastController

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom) {
            if cast.castingAssetID != nil || cast.busy != nil {
                NowCastingBar()
            }
        }
    }
}

struct NowCastingBar: View {
    @EnvironmentObject private var cast: CastController

    var body: some View {
        HStack(spacing: 12) {
            if let busy = cast.busy {
                ProgressView()
                Text(busy.message).font(.subheadline)
            } else {
                Image(systemName: "tv.fill").foregroundStyle(.tint)
                Text("Showing on \(cast.selected?.name ?? "TV")").font(.subheadline).lineLimit(1)
            }
            Spacer()
            if cast.isVideo {
                Button { cast.togglePlayPause() } label: {
                    Image(systemName: cast.isPlaying ? "pause.fill" : "play.fill")
                }
            }
            Button("Stop", role: .destructive) { cast.stop() }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
