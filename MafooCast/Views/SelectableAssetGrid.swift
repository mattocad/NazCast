import Photos
import SwiftUI

enum GridSelectionAction {
    /// Library and albums: pick photos and add them to a collection.
    case addToCollection
    /// Inside a collection: pick photos and remove them from it.
    case removeFromCollection(CastCollection.ID)
}

/// A photo grid with a TV button, an optional sort menu, and a "Select" mode. Tapping a photo
/// opens the viewer (which puts it on the TV); in select mode taps toggle a checkmark, and
/// sliding a finger across photos selects them in bulk like the Photos app.
struct SelectableAssetGrid<Header: View>: View {
    let assets: AssetList
    var loops = false
    var action: GridSelectionAction = .addToCollection
    var sort: Binding<PhotoSort>? = nil
    var sortOptions: [PhotoSort] = PhotoSort.allCases
    @ViewBuilder var header: () -> Header

    @EnvironmentObject private var store: CollectionStore
    @State private var isSelecting = false
    @State private var selection = Set<String>()
    @State private var viewer: ViewerTarget?
    @State private var showPicker = false
    @State private var showNewCollection = false
    @State private var newName = ""
    @State private var toast: String?

    // Drag-to-select
    @State private var drag: DragSelection?
    @State private var gridFrame: CGRect = .zero          // screen coordinates
    @State private var scrollFrame: CGRect = .zero        // screen coordinates
    @State private var metrics = ScrollMetrics()
    @State private var scrollPosition = ScrollPosition()
    @State private var autoScroll: Task<Void, Never>?

    private static var columnCount: Int { 4 }
    private static var spacing: CGFloat { 2 }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount)

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                header()
                LazyVGrid(columns: columns, spacing: Self.spacing) {
                    ForEach(0..<assets.count, id: \.self) { index in
                        let asset = assets[index]
                        Button { tap(index, asset) } label: {
                            AssetThumbnail(asset: asset,
                                           isSelected: isSelecting ? selection.contains(asset.localIdentifier) : nil)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { gridFrame = $0 }
                .gesture(DragSelectRecognizer(isEnabled: isSelecting,
                                              onBegin: dragBegan, onChange: dragMoved, onEnd: dragEnded))
            }
            .padding(.top, 8)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { scrollFrame = $0 }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: ScrollMetrics.self) { geo in
            ScrollMetrics(offset: geo.contentOffset.y, contentHeight: geo.contentSize.height,
                          viewportHeight: geo.containerSize.height,
                          insetTop: geo.contentInsets.top, insetBottom: geo.contentInsets.bottom)
        } action: { _, new in
            metrics = new
        }
        .sensoryFeedback(.selection, trigger: selection.count) { _, _ in drag != nil }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let sort, !isSelecting {
                    Menu {
                        Picker("Sort", selection: sort) {
                            ForEach(sortOptions) { Text($0.title).tag($0) }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .accessibilityLabel("Sort")
                }
                if !assets.isEmpty {
                    Button(isSelecting ? "Cancel" : "Select") {
                        withAnimation { isSelecting.toggle() }
                        selection.removeAll()
                    }
                }
                if !isSelecting {
                    TVButton { showPicker = true }
                }
            }
        }
        .toolbar(isSelecting ? .hidden : .automatic, for: .tabBar)
        .safeAreaInset(edge: .bottom) {
            if isSelecting { selectionBar }
        }
        .overlay(alignment: .top) {
            if let toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(2))
                        withAnimation { self.toast = nil }
                    }
            }
        }
        .sheet(isPresented: $showPicker) { DevicePickerView() }
        .fullScreenCover(item: $viewer) { target in
            ViewerView(assets: assets, startIndex: target.index, loops: loops)
        }
        .alert("New Collection", isPresented: $showNewCollection) {
            TextField("Name", text: $newName)
            Button("Create") {
                let collection = store.create(name: newName, assetIDs: assets.identifiers(in: selection))
                finish("Added \(collection.assetIDs.count) to \(collection.name)")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Add \(selection.count) item\(selection.count == 1 ? "" : "s") to a new collection.")
        }
    }

    private var selectionBar: some View {
        HStack {
            let allSelected = selection.count == assets.count
            Button(allSelected ? "Deselect All" : "Select All") {
                selection = allSelected ? [] : Set(assets.allIdentifiers)
            }
            Spacer()
            Text(selection.isEmpty ? "Tap or slide across photos" : "\(selection.count) selected")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(selection.isEmpty ? .secondary : .primary)
            Spacer()
            switch action {
            case .addToCollection:
                Menu {
                    Button {
                        newName = ""
                        showNewCollection = true
                    } label: {
                        Label("New Collection…", systemImage: "plus")
                    }
                    if !store.collections.isEmpty {
                        Section("Add to") {
                            ForEach(store.collections) { collection in
                                Button(collection.name) { add(to: collection) }
                            }
                        }
                    }
                } label: {
                    Label("Add", systemImage: "rectangle.stack.badge.plus")
                        .fontWeight(.semibold)
                }
                .disabled(selection.isEmpty)
            case .removeFromCollection(let id):
                Button(role: .destructive) {
                    let count = selection.count
                    store.remove(selection, from: id)
                    finish("Removed \(count)")
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .disabled(selection.isEmpty)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func tap(_ index: Int, _ asset: PHAsset) {
        if isSelecting {
            if selection.remove(asset.localIdentifier) == nil { selection.insert(asset.localIdentifier) }
        } else {
            viewer = ViewerTarget(index: index)
        }
    }

    private func add(to collection: CastCollection) {
        let added = store.add(assets.identifiers(in: selection), to: collection.id)
        finish(added == 0 ? "Already in \(collection.name)" : "Added \(added) to \(collection.name)")
    }

    private func finish(_ message: String) {
        withAnimation {
            isSelecting = false
            selection.removeAll()
            toast = message
        }
    }

    // MARK: - Drag to select

    private struct DragSelection {
        let start: Int
        let adding: Bool          // decided by the first photo touched, like Photos
        let base: Set<String>     // selection before the drag; the swept range is applied on top
        var point: CGPoint        // finger position on screen (stays put while auto-scrolling)
    }

    struct ScrollMetrics: Equatable {
        var offset: CGFloat = 0
        var contentHeight: CGFloat = 0
        var viewportHeight: CGFloat = 0
        var insetTop: CGFloat = 0
        var insetBottom: CGFloat = 0
    }

    /// The photo under a point on screen. With `clamp`, points above/below the grid
    /// map to the first/last photo instead of nil.
    private func index(at point: CGPoint, clamp: Bool) -> Int? {
        let width = gridFrame.width
        guard width > 0, assets.count > 0 else { return nil }
        let n = Self.columnCount
        let pitch = (width - CGFloat(n - 1) * Self.spacing) / CGFloat(n) + Self.spacing
        let x = point.x - gridFrame.minX, y = point.y - gridFrame.minY
        if !clamp, y < 0 || y > gridFrame.height || x < 0 || x > width { return nil }
        let column = min(max(Int(x / pitch), 0), n - 1)
        let row = max(Int((y / pitch).rounded(.down)), 0)
        return min(row * n + column, assets.count - 1)
    }

    private func dragBegan(at start: CGPoint) {
        guard let index = index(at: start, clamp: false) else { return }
        let id = assets[index].localIdentifier
        drag = DragSelection(start: index, adding: !selection.contains(id), base: selection, point: start)
        applyDrag()
    }

    private func dragMoved(to point: CGPoint) {
        guard drag != nil else { return }
        drag?.point = point
        applyDrag()
        if autoScroll == nil, autoScrollSpeed() != 0 {
            autoScroll = Task { await runAutoScroll() }
        }
    }

    private func dragEnded() {
        drag = nil
        autoScroll?.cancel()
        autoScroll = nil
    }

    /// Everything between the first photo touched and the one under the finger, in grid order.
    private func applyDrag() {
        guard let drag, let current = index(at: drag.point, clamp: true) else { return }
        var next = drag.base
        for i in min(drag.start, current)...max(drag.start, current) {
            let id = assets[i].localIdentifier
            if drag.adding { next.insert(id) } else { next.remove(id) }
        }
        if next != selection { selection = next }
    }

    /// Points per frame to scroll when the finger is near the top or bottom edge.
    private func autoScrollSpeed() -> CGFloat {
        guard let y = drag?.point.y else { return 0 }
        let zone: CGFloat = 80, maxSpeed: CGFloat = 22
        // The scroll view's on-screen frame already excludes the nav bar and bottom bars.
        let top = scrollFrame.minY
        let bottom = scrollFrame.maxY
        if y < top + zone { return -maxSpeed * min(1, (top + zone - y) / zone) }
        if y > bottom - zone { return maxSpeed * min(1, (y - (bottom - zone)) / zone) }
        return 0
    }

    private func runAutoScroll() async {
        defer { autoScroll = nil }
        while !Task.isCancelled, drag != nil {
            let speed = autoScrollSpeed()
            if speed == 0 { return }
            let minOffset = -metrics.insetTop
            let maxOffset = max(minOffset, metrics.contentHeight - metrics.viewportHeight + metrics.insetBottom)
            let target = min(max(metrics.offset + speed, minOffset), maxOffset)
            if target != metrics.offset {
                // scrollTo(y:) is measured from the top of the content, without the top inset.
                scrollPosition.scrollTo(y: target + metrics.insetTop)
                metrics.offset = target
            }
            // The finger is still, but the photos under it moved.
            applyDrag()
            try? await Task.sleep(for: .milliseconds(16))
        }
    }
}

/// A one-finger pan that only starts on a mostly-horizontal swipe, so vertical swipes still
/// scroll the grid (the same split the Photos app uses).
private struct DragSelectRecognizer: UIGestureRecognizerRepresentable {
    var isEnabled: Bool
    var onBegin: (CGPoint) -> Void
    var onChange: (CGPoint) -> Void
    var onEnd: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let location = context.converter.location(in: .global)
        switch recognizer.state {
        case .began:
            // Start from where the finger first went down, not where the pan was recognised.
            let moved = recognizer.translation(in: recognizer.view)
            onBegin(CGPoint(x: location.x - moved.x, y: location.y - moved.y))
            onChange(location)
        case .changed:
            onChange(location)
        default:
            onEnd()
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }
    }
}
