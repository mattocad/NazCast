import Photos
import SwiftUI

/// Owns the selected TV, the media server, and what's currently on screen.
@MainActor
final class CastController: ObservableObject {
    @Published private(set) var renderers: [Renderer] = []
    @Published private(set) var selected: Renderer?
    @Published private(set) var isScanning = false

    @Published private(set) var castingAssetID: String?
    @Published private(set) var isVideo = false
    @Published private(set) var isPlaying = false
    @Published var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var isScrubbing = false
    @Published private(set) var volume: Int?

    /// Non-nil while a photo/video is being prepared and sent. `progress` is only set for video export.
    @Published private(set) var busy: (message: String, progress: Double?)?
    @Published var errorMessage: String?

    private let server = MediaServer()
    private var castTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private static let savedLocationKey = "lastRendererLocation"

    func start() {
        MediaPreparer.clearCache()
        Task { _ = try? await server.ensureRunning() }
        Task {
            if let saved = UserDefaults.standard.url(forKey: Self.savedLocationKey),
               let renderer = try? await Renderer.load(from: saved) {
                merge([renderer])
                if selected == nil { select(renderer) }
            }
        }
        Task { await scan() }
    }

    // MARK: - Finding TVs

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        // Show TVs as soon as either method finds them; the HTTP probe takes several seconds.
        await withTaskGroup(of: [Renderer].self) { group in
            group.addTask { await Self.loadRenderers(await SSDP.discover()) }
            group.addTask { await Self.loadRenderers(await DMRProbe.discover()) }
            for await found in group { merge(found) }
        }
    }

    /// For when discovery doesn't find the TV: probe a typed-in IP directly.
    func addTV(ip: String) async -> Bool {
        let ip = ip.trimmingCharacters(in: .whitespaces)
        guard IPv4.parse(ip) != nil else {
            errorMessage = "That doesn't look like an IP address."
            return false
        }
        let found = await Self.loadRenderers(await DMRProbe.discover(onlyHost: ip))
        guard let first = found.first else {
            errorMessage = "No TV answered at \(ip). Make sure it's on and on the same Wi-Fi."
            return false
        }
        merge(found)
        select(first)
        return true
    }

    private static func loadRenderers(_ locations: Set<URL>) async -> [Renderer] {
        await withTaskGroup(of: Renderer?.self) { group in
            for url in locations { group.addTask { try? await Renderer.load(from: url) } }
            var result: [Renderer] = []
            for await r in group { if let r { result.append(r) } }
            return result
        }
    }

    private func merge(_ found: [Renderer]) {
        for r in found {
            if let i = renderers.firstIndex(where: { $0.id == r.id }) { renderers[i] = r } else { renderers.append(r) }
        }
        renderers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func select(_ renderer: Renderer?) {
        if selected != nil, selected?.id != renderer?.id { stop() }
        selected = renderer
        UserDefaults.standard.set(renderer?.location, forKey: Self.savedLocationKey)
        UIApplication.shared.isIdleTimerDisabled = renderer != nil
        volume = nil
        if let renderer {
            Task { volume = try? await renderer.volume() }
        }
    }

    // MARK: - Casting

    /// Puts `asset` on the TV. For photos, `crop` (normalized 0–1) sends just that part — used
    /// when zoomed in on the phone.
    func cast(_ asset: PHAsset, crop: CGRect? = nil) {
        castTask?.cancel()
        castTask = Task { await performCast(asset, crop: crop) }
    }

    private func performCast(_ asset: PHAsset, crop: CGRect?) async {
        guard let tv = selected else {
            errorMessage = "Choose a TV first."
            return
        }
        errorMessage = nil
        defer { if !Task.isCancelled { busy = nil } }
        do {
            let port = try await server.ensureRunning()
            guard let ip = NetworkInfo.localAddress(toward: tv.host) else {
                throw URLError(.notConnectedToInternet)
            }
            let base = "http://\(ip):\(port)"

            if asset.isVideo {
                busy = ("Preparing video…", 0)
                let file = try await MediaPreparer.mp4(for: asset) { [weak self] p in
                    self?.busy = ("Preparing video…", p)
                }
                try Task.checkCancellation()
                busy = ("Starting on TV…", nil)
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let path = server.publish(.file(file), mime: "video/mp4", ext: "mp4",
                                          contentFeatures: DIDL.videoFeatures, transferMode: "Streaming")
                let url = base + path
                try await tv.load(url: url, metadata: DIDL.video(url: url, size: size, duration: asset.duration))
                try await tv.play()
                isVideo = true
                isPlaying = true
                position = 0
                duration = asset.duration
                startPolling()
            } else {
                busy = (crop == nil ? "Sending to TV…" : "Zooming on TV…", nil)
                let jpeg = try await MediaPreparer.jpeg(for: asset, crop: crop)
                try Task.checkCancellation()
                let path = server.publish(.data(jpeg), mime: "image/jpeg", ext: "jpg",
                                          contentFeatures: DIDL.photoFeatures, transferMode: "Interactive")
                let url = base + path
                try await tv.load(url: url, metadata: DIDL.photo(url: url, size: jpeg.count))
                try await tv.play()
                stopPolling()
                isVideo = false
                isPlaying = false
            }
            castingAssetID = asset.localIdentifier
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func stop() {
        castTask?.cancel()
        stopPolling()
        busy = nil
        castingAssetID = nil
        isVideo = false
        isPlaying = false
        if let tv = selected { Task { try? await tv.stop() } }
    }

    func togglePlayPause() {
        guard let tv = selected else { return }
        let wasPlaying = isPlaying
        isPlaying.toggle()
        Task {
            do { if wasPlaying { try await tv.pause() } else { try await tv.play() } }
            catch { errorMessage = Self.describe(error) }
        }
    }

    func seek(to seconds: Double) {
        guard let tv = selected else { return }
        position = seconds
        Task { try? await tv.seek(to: seconds) }
    }

    func changeVolume(by delta: Int) {
        guard let tv = selected else { return }
        let next = min(100, max(0, (volume ?? 10) + delta))
        volume = next
        Task { try? await tv.setVolume(next) }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let tv = self.selected, !Task.isCancelled else { return }
                if let info = try? await tv.position(), !self.isScrubbing {
                    self.position = info.position
                    if info.duration > 0 { self.duration = info.duration }
                }
                if let state = try? await tv.transportState(), !state.isEmpty {
                    self.isPlaying = state == "PLAYING" || state == "TRANSITIONING"
                }
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - App lifecycle

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            UIApplication.shared.isIdleTimerDisabled = selected != nil
            endBackgroundTask()
            Task { _ = try? await server.ensureRunning() }
        case .background:
            // Keep serving for as long as iOS allows so a playing video doesn't cut out instantly.
            backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in self?.endBackgroundTask() }
        default:
            break
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotConnectToHost, .notConnectedToInternet, .networkConnectionLost:
                return "Couldn't reach the TV. Check it's on, on the same Wi-Fi, and that Local Network access is allowed in Settings › NazCast."
            default: break
            }
        }
        return error.localizedDescription
    }
}
