import Photos
import UIKit
import AVFoundation

/// Turns library assets into formats an older TV can actually play:
/// photos → upright 1080p-class JPEG (no HEIC, no EXIF rotation), videos → H.264 MP4.
enum MediaPreparer {
    enum PrepError: LocalizedError {
        case imageUnavailable, videoUnavailable, exportFailed(String?)
        var errorDescription: String? {
            switch self {
            case .imageUnavailable: return "Couldn't load that photo."
            case .videoUnavailable: return "Couldn't load that video."
            case .exportFailed(let reason): return "Couldn't convert the video\(reason.map { ": \($0)" } ?? ".")"
            }
        }
    }

    /// Recently loaded high-res photos, so panning around a zoomed photo doesn't re-fetch it each time.
    private static let sourceCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 2
        return cache
    }()

    /// A JPEG of the photo for the TV. `crop` is a normalized rect (0–1) of the photo to send
    /// instead of the whole thing — used when you zoom in on the phone.
    static func jpeg(for asset: PHAsset, crop: CGRect? = nil, maxSide: CGFloat = 1920) async throws -> Data {
        let crop = (crop ?? CGRect(x: 0, y: 0, width: 1, height: 1))
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !crop.isEmpty else { throw PrepError.imageUnavailable }

        // Zoomed in, fetch enough pixels that the cropped area is still sharp on the TV.
        let wanted = maxSide / max(crop.width, crop.height)
        let sourceSide = [maxSide, 2880, 4096].first { $0 >= wanted } ?? 4096
        let key = "\(asset.localIdentifier)|\(Int(sourceSide))" as NSString
        let image: UIImage
        if let cached = sourceCache.object(forKey: key) {
            image = cached
        } else {
            guard let loaded = await ImageLoader.image(for: asset, maxSide: sourceSide) else {
                throw PrepError.imageUnavailable
            }
            sourceCache.setObject(loaded, forKey: key)
            image = loaded
        }

        // Redraw (cropped) so the pixels are upright — old TVs ignore the EXIF orientation flag.
        let full = image.size
        let area = CGRect(x: crop.minX * full.width, y: crop.minY * full.height,
                          width: crop.width * full.width, height: crop.height * full.height)
        let scale = min(1, maxSide / max(area.width, area.height))
        let size = CGSize(width: max(1, (area.width * scale).rounded()), height: max(1, (area.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let upright = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(x: -area.minX * scale, y: -area.minY * scale,
                                  width: full.width * scale, height: full.height * scale))
        }
        guard let data = upright.jpegData(compressionQuality: 0.88) else { throw PrepError.imageUnavailable }
        return data
    }

    static var cacheDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("CastCache", isDirectory: true)
    }

    static func clearCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    /// Exports the video as 1080p H.264 MP4 (cached per asset). `progress` is called on the main actor.
    static func mp4(for asset: PHAsset, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let name = asset.localIdentifier.replacingOccurrences(of: "/", with: "_")
        let destination = cacheDirectory.appendingPathComponent("\(name).mp4")
        if fm.fileExists(atPath: destination.path) { return destination }

        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current

        let session: AVAssetExportSession = try await withCheckedThrowingContinuation { cont in
            PHImageManager.default().requestExportSession(forVideo: asset, options: options,
                                                          exportPreset: AVAssetExportPreset1920x1080) { session, _ in
                if let session { cont.resume(returning: session) } else { cont.resume(throwing: PrepError.videoUnavailable) }
            }
        }

        let temp = cacheDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        session.outputURL = temp
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true

        let ticker = Task {
            while !Task.isCancelled {
                await progress(Double(session.progress))
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { ticker.cancel() }

        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously { cont.resume() }
            }
        } onCancel: {
            session.cancelExport()
        }

        guard session.status == .completed else {
            try? fm.removeItem(at: temp)
            if Task.isCancelled { throw CancellationError() }
            throw PrepError.exportFailed(session.error?.localizedDescription)
        }
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: temp, to: destination)
        return destination
    }
}

enum ImageLoader {
    private static let manager = PHCachingImageManager()

    static func image(for asset: PHAsset, maxSide: CGFloat) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        options.version = .current
        let scale = min(1, maxSide / CGFloat(max(asset.pixelWidth, asset.pixelHeight, 1)))
        let target = CGSize(width: CGFloat(asset.pixelWidth) * scale, height: CGFloat(asset.pixelHeight) * scale)
        return await request(asset, target: target, mode: .aspectFit, options: options)
    }

    static func thumbnail(for asset: PHAsset, side: CGFloat) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return await request(asset, target: CGSize(width: side, height: side), mode: .aspectFill, options: options)
    }

    private static func request(_ asset: PHAsset, target: CGSize, mode: PHImageContentMode,
                                options: PHImageRequestOptions) async -> UIImage? {
        await withCheckedContinuation { cont in
            // With .highQualityFormat the handler is called exactly once.
            manager.requestImage(for: asset, targetSize: target, contentMode: mode, options: options) { image, _ in
                cont.resume(returning: image)
            }
        }
    }
}
