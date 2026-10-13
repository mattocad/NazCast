import Foundation
import Darwin

/// An IPv4 address on one of the phone's Wi-Fi / Ethernet / hotspot interfaces.
struct IPv4Interface {
    let name: String
    let address: UInt32   // host byte order
    let netmask: UInt32   // host byte order

    var addressString: String { IPv4.string(address) }

    func contains(_ other: UInt32) -> Bool {
        (address & netmask) == (other & netmask)
    }

    /// Every other host on this network, capped to the /24 around our own address
    /// so a big subnet doesn't turn into thousands of probe packets.
    var probeHosts: [UInt32] {
        let mask = max(netmask, 0xFFFF_FF00)
        let network = address & mask
        let broadcast = network | ~mask
        guard broadcast > network + 1 else { return [] }
        return (network + 1 ..< broadcast).filter { $0 != address }
    }
}

enum IPv4 {
    static func string(_ a: UInt32) -> String {
        "\(a >> 24 & 255).\(a >> 16 & 255).\(a >> 8 & 255).\(a & 255)"
    }

    static func parse(_ s: String) -> UInt32? {
        var addr = in_addr()
        guard inet_pton(AF_INET, s, &addr) == 1 else { return nil }
        return UInt32(bigEndian: addr.s_addr)
    }
}

enum NetworkInfo {
    static func interfaces() -> [IPv4Interface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [IPv4Interface] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  let nm = ifa.ifa_netmask else { continue }
            let name = String(cString: ifa.ifa_name)
            // en* = Wi-Fi / Ethernet, bridge* = Personal Hotspot. Skip cellular, VPN, AWDL.
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let mask = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            result.append(IPv4Interface(name: name, address: UInt32(bigEndian: addr), netmask: UInt32(bigEndian: mask)))
        }
        return result
    }

    /// The phone's address on the same network as `host` — what the TV must use to reach us.
    static func localAddress(toward host: String) -> String? {
        let all = interfaces()
        if let target = IPv4.parse(host), let match = all.first(where: { $0.contains(target) }) {
            return match.addressString
        }
        return (all.first(where: { $0.name == "en0" }) ?? all.first)?.addressString
    }
}
