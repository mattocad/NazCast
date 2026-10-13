import Foundation

/// Finds Samsung TVs without multicast by asking every host on the local /24 for the
/// well-known Samsung renderer description URLs over plain HTTP.
///
/// Samsung's renderer only answers *multicast* SSDP searches, and iOS blocks multicast unless
/// Apple has granted the app the multicast entitlement — so this is what finds the TV on a
/// normally-signed build.
enum DMRProbe {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        config.httpMaximumConnectionsPerHost = 2
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// Description-document URLs that look like renderers. `onlyHost` limits the probe to one IP.
    static func discover(onlyHost: String? = nil) async -> Set<URL> {
        let hosts: [String]
        if let onlyHost {
            hosts = [onlyHost]
        } else {
            hosts = Array(Set(NetworkInfo.interfaces().flatMap(\.probeHosts))).map(IPv4.string)
        }

        return await withTaskGroup(of: URL?.self) { group in
            var found = Set<URL>()
            var iterator = hosts.makeIterator()
            var running = 0
            func next() -> Bool {
                guard let host = iterator.next() else { return false }
                group.addTask { await probe(host) }
                running += 1
                return true
            }
            for _ in 0..<64 where next() {}
            while running > 0, let result = await group.next() {
                running -= 1
                if let result { found.insert(result) }
                _ = next()
            }
            return found
        }
    }

    private static func probe(_ host: String) async -> URL? {
        await withTaskGroup(of: URL?.self) { group in
            // 2014+ models (incl. MU/KU/JU/HU series)
            group.addTask { await check("http://\(host):9197/dmr") }
            // 2010–2013 C/D/E/F series
            group.addTask { await check("http://\(host):52235/dmr/SamsungMRDesc.xml") }
            // Some 2013–2015 models serve it at 7676/smp_N_ where N varies
            group.addTask {
                guard await reachable("http://\(host):7676/") else { return nil }
                for n in 2...30 {
                    if let url = await check("http://\(host):7676/smp_\(n)_") { return url }
                }
                return nil
            }
            for await url in group where url != nil {
                group.cancelAll()
                return url
            }
            return nil
        }
    }

    private static func check(_ string: String) async -> URL? {
        guard let url = URL(string: string),
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let text = String(decoding: data.prefix(16_384), as: UTF8.self)
        return text.contains("AVTransport") ? url : nil
    }

    private static func reachable(_ string: String) async -> Bool {
        guard let url = URL(string: string) else { return false }
        return (try? await session.data(from: url)) != nil
    }
}
