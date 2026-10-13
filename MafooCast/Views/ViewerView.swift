import Photos
import SwiftUI

/// Full-screen viewer. Swipe through a list of photos; each one is sent to the TV as you land on it.
/// Pinch, drag or double-tap to zoom — when you let go, the TV zooms to the same spot.
struct ViewerView: View {
    let assets: AssetList
    /// Wrap back to the first photo when a slideshow reaches the end (used for collections).
    let loops: Bool
    @EnvironmentObject private var cast: CastController
    @Environment(\.dismiss) private var dismiss

    @State private var index: Int
    @State private var image: UIImage?
    @State private var dragOffset: CGFloat = 0
    @State private var slideshow = false
    @State private var showChrome = true
    @State private var showPicker = false

    // Zoom (pan is the image centre's offset from the screen centre, in points)
    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var basePan: CGSize = .zero
    @State private var pinchContentPoint: CGPoint?
    @State private var screenFrame: CGRect = .zero     // the full-screen image area, global coordinates
    @State private var gestureFrame: CGRect = .zero    // the view the gestures are attached to, global
    @State private var zoomCast: Task<Void, Never>?
    @AppStorage("slideshowSeconds") private var slideshowSeconds = 6

    init(assets: AssetList, startIndex: Int, slideshow: Bool = false, loops: Bool = false) {
        self.assets = assets
        self.loops = loops
        _index = State(initialValue: startIndex)
        _slideshow = State(initialValue: slideshow)
    }

    private var asset: PHAsset? {
        index < assets.count ? assets[index] : nil
    }

    private var isOnTV: Bool {
        asset.map { cast.castingAssetID == $0.localIdentifier } ?? false
    }

    var body: some View {
        ZStack {
            // Measured with a GeometryReader so the frame includes the area under the status bar,
            // matching the full-screen image.
            GeometryReader { geo in
                Color.black
                    .onAppear { screenFrame = geo.frame(in: .global) }
                    .onChange(of: geo.frame(in: .global)) { _, frame in screenFrame = frame }
            }
            .ignoresSafeArea()

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(zoom)
                    .offset(x: pan.width + dragOffset, y: pan.height)
                    .ignoresSafeArea()
            } else {
                ProgressView().tint(.white)
            }

            if asset?.isVideo == true, !isOnTV, cast.busy == nil {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.white.opacity(0.85))
                    .allowsHitTesting(false)
            }

            if showChrome {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    bottomBar
                }
                .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { gestureFrame = $0 }
        .gesture(swipe)
        .simultaneousGesture(pinch)
        .onTapGesture(count: 2, coordinateSpace: .global) { toggleZoom(at: $0) }
        .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { showChrome.toggle() } }
        .statusBarHidden(!showChrome)
        .preferredColorScheme(.dark)
        .task(id: index) { await show() }
        .task(id: slideshow) { await runSlideshow() }
        .sheet(isPresented: $showPicker) { DevicePickerView() }
    }

    // MARK: - Chrome

    private var topBar: some View {
        VStack(spacing: 6) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.headline).padding(10).background(.ultraThinMaterial, in: Circle())
                }
                Spacer()
                if let date = asset?.creationDate {
                    Text(date.formatted(date: .abbreviated, time: .omitted)).font(.subheadline.weight(.medium))
                }
                Spacer()
                Button { showPicker = true } label: {
                    Image(systemName: cast.selected == nil ? "tv" : "tv.fill")
                        .font(.headline).padding(10).background(.ultraThinMaterial, in: Circle())
                }
            }
            statusLine
        }
        .foregroundStyle(.white)
        .padding(.horizontal)
    }

    @ViewBuilder
    private var statusLine: some View {
        Group {
            if let error = cast.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            } else if let busy = cast.busy {
                if let progress = busy.progress {
                    HStack {
                        Text(busy.message)
                        ProgressView(value: progress).frame(width: 100).tint(.white)
                    }
                } else {
                    Label(busy.message, systemImage: "arrow.up.circle")
                }
            } else if let tv = cast.selected {
                Label(isOnTV ? "On \(tv.name)" : tv.name, systemImage: isOnTV ? "checkmark.circle.fill" : "tv")
            } else {
                Text("Not connected to a TV")
            }
        }
        .font(.caption)
        .lineLimit(2)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 14) {
            if asset?.isVideo == true {
                if isOnTV && cast.isVideo {
                    PlaybackControls()
                } else {
                    Button {
                        if let asset { cast.cast(asset) }
                    } label: {
                        Label("Play on TV", systemImage: "play.tv.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(cast.selected == nil || cast.busy != nil)
                }
            }

            HStack(spacing: 28) {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(index == 0)

                Menu {
                    ForEach([3, 6, 10, 20], id: \.self) { seconds in
                        Button("\(seconds) seconds") { slideshowSeconds = seconds }
                    }
                } label: {
                    Image(systemName: "timer")
                } primaryAction: {
                    slideshow.toggle()
                }
                .overlay(alignment: .topTrailing) {
                    if slideshow { Circle().fill(.tint).frame(width: 8, height: 8).offset(x: 6, y: -4) }
                }
                .accessibilityLabel(slideshow ? "Stop slideshow" : "Start slideshow")

                Button {
                    if let asset { cast.cast(asset) }
                } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(cast.selected == nil)
                    .accessibilityLabel("Send to TV again")

                Button { cast.stop() } label: { Image(systemName: "stop.fill") }
                    .disabled(cast.castingAssetID == nil)
                    .accessibilityLabel("Stop casting")

                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(index >= assets.count - 1)
            }
            .font(.title3)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .foregroundStyle(.white)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    // MARK: - Behaviour

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard pinchContentPoint == nil else { return }
                if zoom > 1 {
                    pan = clamped(CGSize(width: basePan.width + value.translation.width,
                                         height: basePan.height + value.translation.height), zoom: zoom)
                } else {
                    dragOffset = value.translation.width
                }
            }
            .onEnded { value in
                if zoom > 1 || pinchContentPoint != nil {
                    basePan = pan
                    sendZoomToTV()
                    return
                }
                let dx = value.translation.width, dy = value.translation.height
                if dy > 140, abs(dy) > abs(dx) {
                    dismiss()
                } else if dx < -80 {
                    step(1)
                } else if dx > 80 {
                    step(-1)
                }
                withAnimation(.spring(duration: 0.3)) { dragOffset = 0 }
            }
    }

    // MARK: - Zoom

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchContentPoint == nil {
                    // The photo point under the fingers stays under them as you pinch.
                    let p = relativeToCenter(CGPoint(x: value.startLocation.x + gestureFrame.minX,
                                                     y: value.startLocation.y + gestureFrame.minY))
                    pinchContentPoint = CGPoint(x: (p.x - basePan.width) / baseZoom, y: (p.y - basePan.height) / baseZoom)
                    dragOffset = 0
                }
                guard let anchor = pinchContentPoint else { return }
                let p = CGPoint(x: anchor.x * baseZoom + basePan.width, y: anchor.y * baseZoom + basePan.height)
                zoom = min(max(baseZoom * value.magnification, 1), 8)
                pan = clamped(CGSize(width: p.x - anchor.x * zoom, height: p.y - anchor.y * zoom), zoom: zoom)
            }
            .onEnded { _ in
                pinchContentPoint = nil
                if zoom < 1.05 {
                    withAnimation(.spring(duration: 0.3)) { resetZoom() }
                } else {
                    baseZoom = zoom
                    basePan = pan
                }
                sendZoomToTV()
            }
    }

    private func toggleZoom(at location: CGPoint) {
        withAnimation(.spring(duration: 0.35)) {
            if zoom > 1 {
                resetZoom()
            } else {
                let p = relativeToCenter(location)
                zoom = 2.5
                pan = clamped(CGSize(width: -p.x * (zoom - 1), height: -p.y * (zoom - 1)), zoom: zoom)
                baseZoom = zoom
                basePan = pan
            }
        }
        sendZoomToTV()
    }

    private func resetZoom() {
        zoom = 1
        baseZoom = 1
        pan = .zero
        basePan = .zero
    }

    private func relativeToCenter(_ global: CGPoint) -> CGPoint {
        CGPoint(x: global.x - screenFrame.midX, y: global.y - screenFrame.midY)
    }

    /// Size of the photo on screen at zoom 1.
    private var fittedSize: CGSize {
        guard let image, image.size.width > 0, image.size.height > 0, screenFrame.width > 0 else { return .zero }
        let scale = min(screenFrame.width / image.size.width, screenFrame.height / image.size.height)
        return CGSize(width: image.size.width * scale, height: image.size.height * scale)
    }

    /// Keeps the zoomed photo covering the screen (no panning past its edges).
    private func clamped(_ offset: CGSize, zoom: CGFloat) -> CGSize {
        let fit = fittedSize
        let maxX = max(0, (fit.width * zoom - screenFrame.width) / 2)
        let maxY = max(0, (fit.height * zoom - screenFrame.height) / 2)
        return CGSize(width: min(max(offset.width, -maxX), maxX), height: min(max(offset.height, -maxY), maxY))
    }

    /// The part of the photo to show on the TV (normalized 0–1): the TV zooms by the same amount
    /// as the phone, centred on the same spot. nil = the whole photo.
    private func tvCrop() -> CGRect? {
        let fit = fittedSize
        guard zoom > 1.01, fit.width > 0, let image else { return nil }
        // Centre of what's on the phone screen, in normalized photo coordinates.
        let cx = 0.5 - pan.width / (fit.width * zoom)
        let cy = 0.5 - pan.height / (fit.height * zoom)

        // What a 16:9 TV shows of the photo at zoom 1 (it may overhang = black bars), divided by zoom.
        let px = image.size.width, py = image.size.height
        let tv: CGFloat = 16 / 9
        var vw = px > py * tv ? px : py * tv
        var vh = px > py * tv ? px / tv : py
        vw /= zoom
        vh /= zoom
        let cw = min(vw, px), ch = min(vh, py)
        let left = min(max(cx * px - cw / 2, 0), px - cw)
        let top = min(max(cy * py - ch / 2, 0), py - ch)
        return CGRect(x: left / px, y: top / py, width: cw / px, height: ch / py)
    }

    /// After a zoom/pan settles, show the same view on the TV (or the whole photo when zoomed out).
    private func sendZoomToTV() {
        guard cast.selected != nil, let asset, !asset.isVideo else { return }
        let crop = tvCrop()
        zoomCast?.cancel()
        zoomCast = Task {
            try? await Task.sleep(for: .milliseconds(250))
            if !Task.isCancelled { cast.cast(asset, crop: crop) }
        }
    }

    private func step(_ delta: Int) {
        let next = index + delta
        guard next >= 0, next < assets.count else { return }
        index = next
    }

    private func show() async {
        resetZoom()
        guard let asset else { return }
        if let thumb = await ImageLoader.thumbnail(for: asset, side: 400), !Task.isCancelled {
            image = thumb
        }
        async let full = ImageLoader.image(for: asset, maxSide: 2000)

        // Photos follow you onto the TV automatically (debounced so fast swiping doesn't spam it).
        // Videos need converting first, so they wait for "Play on TV".
        if cast.selected != nil, !asset.isVideo, !isOnTV {
            try? await Task.sleep(for: .milliseconds(350))
            if !Task.isCancelled { cast.cast(asset) }
        }
        if let loaded = await full, !Task.isCancelled { image = loaded }
    }

    /// The next photo after the current one (slideshows skip videos), wrapping if `loops`.
    private func nextPhotoIndex() -> Int? {
        guard assets.count > 1 else { return nil }
        var next = index
        for _ in 0..<assets.count {
            next += 1
            if next >= assets.count {
                guard loops else { return nil }
                next = 0
            }
            if !assets[next].isVideo { return next }
        }
        return nil
    }

    private func runSlideshow() async {
        while slideshow, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(slideshowSeconds))
            guard slideshow, !Task.isCancelled else { return }
            guard let next = nextPhotoIndex() else { slideshow = false; return }
            index = next
        }
    }
}

struct PlaybackControls: View {
    @EnvironmentObject private var cast: CastController

    var body: some View {
        VStack(spacing: 8) {
            Slider(value: $cast.position, in: 0...max(cast.duration, 1)) { editing in
                cast.isScrubbing = editing
                if !editing { cast.seek(to: cast.position) }
            }
            .tint(.white)

            HStack {
                Text(Self.format(cast.position))
                Spacer()
                Text(Self.format(cast.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack(spacing: 36) {
                Button { cast.changeVolume(by: -2) } label: { Image(systemName: "speaker.minus.fill") }
                Button { cast.seek(to: max(0, cast.position - 10)) } label: { Image(systemName: "gobackward.10") }
                Button { cast.togglePlayPause() } label: {
                    Image(systemName: cast.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 48))
                }
                Button { cast.seek(to: min(cast.duration, cast.position + 10)) } label: { Image(systemName: "goforward.10") }
                Button { cast.changeVolume(by: 2) } label: { Image(systemName: "speaker.plus.fill") }
            }
            .font(.title3)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    static func format(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
