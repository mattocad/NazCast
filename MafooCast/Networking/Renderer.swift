import Foundation

struct UPnPService: Hashable {
    let type: String       // e.g. urn:schemas-upnp-org:service:AVTransport:1
    let controlURL: URL
}

/// A TV (or any DLNA media renderer) we can push media to.
struct Renderer: Identifiable, Hashable {
    let id: String         // UDN
    let name: String
    let model: String
    let location: URL
    let avTransport: UPnPService
    let renderingControl: UPnPService?

    var host: String { location.host ?? "" }
}

enum RendererError: LocalizedError {
    case notARenderer
    case upnp(code: Int, message: String)
    case badResponse(Int)

    var errorDescription: String? {
        switch self {
        case .notARenderer:
            return "That device can't play media."
        case .upnp(let code, let message):
            switch code {
            case 714, 715: return "The TV doesn't support this file type (\(code))."
            case 716: return "The TV couldn't find the file (\(code))."
            default: return "The TV said no (\(code)\(message.isEmpty ? "" : ": \(message)"))."
            }
        case .badResponse(let status):
            return "The TV returned HTTP \(status)."
        }
    }
}

// MARK: - Loading the device description

extension Renderer {
    static func load(from location: URL) async throws -> Renderer {
        let (data, _) = try await URLSession.shared.data(for: URLRequest(url: location, timeoutInterval: 5))
        let parser = DescriptionParser()
        let xml = XMLParser(data: data)
        xml.shouldProcessNamespaces = true
        xml.delegate = parser
        xml.parse()

        let base = parser.fields["URLBase"].flatMap { URL(string: $0) } ?? location
        func service(_ kind: String) -> UPnPService? {
            guard let entry = parser.services.first(where: { ($0["serviceType"] ?? "").contains(":service:\(kind):") }),
                  let type = entry["serviceType"], let control = entry["controlURL"],
                  let url = URL(string: control, relativeTo: base)?.absoluteURL else { return nil }
            return UPnPService(type: type, controlURL: url)
        }

        guard let av = service("AVTransport") else { throw RendererError.notARenderer }
        let model = [parser.fields["manufacturer"], parser.fields["modelName"]]
            .compactMap { $0 }.joined(separator: " ")
        return Renderer(
            id: parser.fields["UDN"] ?? location.absoluteString,
            name: parser.fields["friendlyName"] ?? location.host ?? "TV",
            model: model,
            location: location,
            avTransport: av,
            renderingControl: service("RenderingControl")
        )
    }
}

private final class DescriptionParser: NSObject, XMLParserDelegate {
    var fields: [String: String] = [:]          // first occurrence of each top-level field wins
    var services: [[String: String]] = []
    private var currentService: [String: String]?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if name == "service" { currentService = [:] }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "service", let service = currentService {
            services.append(service)
            currentService = nil
        } else if currentService != nil {
            currentService?[name] = value
        } else if fields[name] == nil, !value.isEmpty {
            fields[name] = value
        }
        text = ""
    }
}

// MARK: - Controlling playback (SOAP)

extension Renderer {
    func load(url: String, metadata: String) async throws {
        let args = [("InstanceID", "0"), ("CurrentURI", url), ("CurrentURIMetaData", metadata)]
        do {
            _ = try await invoke(avTransport, "SetAVTransportURI", args)
        } catch {
            // Some Samsung models refuse a new URI while something is showing. Stop, then retry.
            try? await stop()
            _ = try await invoke(avTransport, "SetAVTransportURI", args)
        }
    }

    func play() async throws {
        // Samsung answers 705 "Transport is locked" while it's still loading the new URI. Retry briefly.
        for attempt in 0..<6 {
            do {
                _ = try await invoke(avTransport, "Play", [("InstanceID", "0"), ("Speed", "1")])
                return
            } catch RendererError.upnp(let code, _) where code == 705 && attempt < 5 {
                try await Task.sleep(for: .milliseconds(500))
            } catch RendererError.upnp(let code, _) where code == 701 {
                // "Transition not available": Samsung already started showing it (photos auto-play).
                return
            }
        }
    }

    func pause() async throws {
        _ = try await invoke(avTransport, "Pause", [("InstanceID", "0")])
    }

    func stop() async throws {
        _ = try await invoke(avTransport, "Stop", [("InstanceID", "0")])
    }

    func seek(to seconds: Double) async throws {
        _ = try await invoke(avTransport, "Seek", [("InstanceID", "0"), ("Unit", "REL_TIME"), ("Target", Self.timeString(seconds))])
    }

    func position() async throws -> (position: Double, duration: Double) {
        let xml = try await invoke(avTransport, "GetPositionInfo", [("InstanceID", "0")])
        return (Self.seconds(Self.value("RelTime", in: xml)), Self.seconds(Self.value("TrackDuration", in: xml)))
    }

    func transportState() async throws -> String {
        let xml = try await invoke(avTransport, "GetTransportInfo", [("InstanceID", "0")])
        return Self.value("CurrentTransportState", in: xml) ?? ""
    }

    func volume() async throws -> Int? {
        guard let rc = renderingControl else { return nil }
        let xml = try await invoke(rc, "GetVolume", [("InstanceID", "0"), ("Channel", "Master")])
        return Self.value("CurrentVolume", in: xml).flatMap { Int($0) }
    }

    func setVolume(_ volume: Int) async throws {
        guard let rc = renderingControl else { return }
        _ = try await invoke(rc, "SetVolume", [("InstanceID", "0"), ("Channel", "Master"), ("DesiredVolume", String(volume))])
    }

    private func invoke(_ service: UPnPService, _ action: String, _ args: [(String, String)]) async throws -> String {
        var body = #"<?xml version="1.0" encoding="utf-8"?>"#
        body += #"<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>"#
        body += "<u:\(action) xmlns:u=\"\(service.type)\">"
        for (key, value) in args { body += "<\(key)>\(XML.escape(value))</\(key)>" }
        body += "</u:\(action)></s:Body></s:Envelope>"

        var request = URLRequest(url: service.controlURL, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue(#"text/xml; charset="utf-8""#, forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service.type)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = Data(body.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let text = String(decoding: data, as: UTF8.self)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if let code = Self.value("errorCode", in: text).flatMap({ Int($0) }) {
                throw RendererError.upnp(code: code, message: Self.value("errorDescription", in: text) ?? "")
            }
            throw RendererError.badResponse(status)
        }
        return text
    }

    // MARK: Helpers

    static func value(_ tag: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(tag)>") ?? xml.range(of: ":\(tag)>"),
              let close = xml.range(of: "</", range: open.upperBound..<xml.endIndex) else { return nil }
        return String(xml[open.upperBound..<close.lowerBound])
    }

    static func seconds(_ time: String?) -> Double {
        guard let time else { return 0 }
        let parts = time.split(separator: ":").map { Double($0) ?? 0 }
        guard parts.count == 3 else { return 0 }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    static func timeString(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }
}

enum XML {
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

/// DLNA metadata the TV needs alongside the URL. Samsung TVs are picky about protocolInfo.
enum DIDL {
    static let photoFeatures = "DLNA.ORG_PN=JPEG_LRG;DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=00D00000000000000000000000000000"
    static let videoFeatures = "DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"

    static func photo(url: String, size: Int) -> String {
        item(title: "Photo", url: url, upnpClass: "object.item.imageItem.photo",
             protocolInfo: "http-get:*:image/jpeg:\(photoFeatures)", size: size)
    }

    static func video(url: String, size: Int, duration: Double) -> String {
        item(title: "Video", url: url, upnpClass: "object.item.videoItem",
             protocolInfo: "http-get:*:video/mp4:\(videoFeatures)", size: size,
             duration: Renderer.timeString(duration) + ".000")
    }

    private static func item(title: String, url: String, upnpClass: String, protocolInfo: String,
                             size: Int, duration: String? = nil) -> String {
        let durationAttr = duration.map { " duration=\"\($0)\"" } ?? ""
        return #"<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/">"#
            + #"<item id="1" parentID="0" restricted="1">"#
            + "<dc:title>\(XML.escape(title))</dc:title>"
            + "<upnp:class>\(upnpClass)</upnp:class>"
            + "<res protocolInfo=\"\(protocolInfo)\" size=\"\(size)\"\(durationAttr)>\(XML.escape(url))</res>"
            + "</item></DIDL-Lite>"
    }
}
