import Foundation
import Darwin

/// Finds DLNA/UPnP media renderers with a standard multicast M-SEARCH.
///
/// On iOS, sending multicast needs Apple's `com.apple.developer.networking.multicast` entitlement;
/// without it this finds nothing and `DMRProbe` does the work instead. (We deliberately don't
/// follow up with a unicast sweep: Samsung's renderer ignores unicast searches, and the burst of
/// packets makes the TV drop its multicast replies.)
enum SSDP {
    private static let multicastGroup: UInt32 = 0xEFFF_FFFA // 239.255.255.250
    private static let searchTargets = [
        "urn:schemas-upnp-org:device:MediaRenderer:1",
        "urn:schemas-upnp-org:service:AVTransport:1",
    ]

    /// Returns the description-document URLs (`LOCATION:` headers) of every renderer that answered.
    static func discover(duration: TimeInterval = 3) async -> Set<URL> {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: search(duration: duration))
            }
        }
    }

    private static func search(duration: TimeInterval) -> Set<URL> {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var ttl: UInt8 = 4
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let deadline = Date().addingTimeInterval(duration)
        var locations = Set<URL>()
        // UDP is lossy; repeat the search a few times.
        for attempt in 0..<3 {
            for st in searchTargets {
                send(fd, message(searchTarget: st, host: multicastGroup), to: multicastGroup)
            }
            wait(fd, until: min(deadline, Date().addingTimeInterval(attempt < 2 ? 0.5 : duration)), into: &locations)
        }
        wait(fd, until: deadline, into: &locations)
        return locations
    }

    private static func message(searchTarget: String, host: UInt32) -> String {
        "M-SEARCH * HTTP/1.1\r\n" +
        "HOST: \(IPv4.string(host)):1900\r\n" +
        "MAN: \"ssdp:discover\"\r\n" +
        "MX: 2\r\n" +
        "ST: \(searchTarget)\r\n" +
        "USER-AGENT: iOS/17 UPnP/1.1 NazCast/1.0\r\n\r\n"
    }

    private static func send(_ fd: Int32, _ text: String, to ip: UInt32) {
        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = UInt16(1900).bigEndian
        dest.sin_addr.s_addr = ip.bigEndian
        let bytes = Array(text.utf8)
        _ = withUnsafePointer(to: &dest) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    private static func wait(_ fd: Int32, until deadline: Date, into locations: inout Set<URL>) {
        while Date() < deadline {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ms = Int32(max(1, min(200, deadline.timeIntervalSinceNow * 1000)))
            if poll(&pfd, 1, ms) > 0 { drain(fd, into: &locations) }
        }
    }

    private static func drain(_ fd: Int32, into locations: inout Set<URL>) {
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            guard n > 0 else { return }
            let text = String(decoding: buf[0..<n], as: UTF8.self)
            if let url = location(in: text) { locations.insert(url) }
        }
    }

    private static func location(in response: String) -> URL? {
        for line in response.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("location:") {
            let value = line.dropFirst("location:".count).trimmingCharacters(in: .whitespaces)
            return URL(string: value)
        }
        return nil
    }
}
