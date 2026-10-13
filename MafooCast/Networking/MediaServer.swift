import Foundation
import Network

/// A tiny HTTP server the TV pulls photos and videos from. Supports HEAD and byte ranges,
/// which TVs use to seek in videos.
final class MediaServer: @unchecked Sendable {
    enum Body {
        case data(Data)
        case file(URL)
    }

    private struct Item {
        let body: Body
        let mime: String
        let contentFeatures: String
        let transferMode: String
    }

    private let queue = DispatchQueue(label: "NazCast.MediaServer")
    private var listener: NWListener?
    private var items: [String: Item] = [:]    // only touched on `queue`
    private var order: [String] = []

    enum ServerError: LocalizedError {
        case couldNotStart
        var errorDescription: String? { "Couldn't start the media server." }
    }

    /// Starts (or restarts, e.g. after the app was backgrounded) the listener and returns its port.
    func ensureRunning() async throws -> UInt16 {
        if let listener, listener.state == .ready, let port = listener.port?.rawValue {
            return port
        }
        listener?.cancel()
        listener = nil
        var lastError: Error = ServerError.couldNotStart
        for port: UInt16 in [8790, 8791, 8792, 0] {
            do { return try await start(port: port) } catch { lastError = error }
        }
        throw lastError
    }

    private func start(port: UInt16) async throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        l.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        listener = l
        return try await withCheckedThrowingContinuation { cont in
            let once = Once()
            l.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run { cont.resume(returning: l.port?.rawValue ?? port) }
                case .failed(let error):
                    l.cancel()
                    once.run { cont.resume(throwing: error) }
                default:
                    break
                }
            }
            l.start(queue: queue)
        }
    }

    /// Makes `body` downloadable and returns its path, e.g. `/m/3fa1b2c4.jpg`.
    /// Every call gets a fresh path so the TV never shows a cached copy.
    func publish(_ body: Body, mime: String, ext: String, contentFeatures: String, transferMode: String) -> String {
        let path = "/m/\(UUID().uuidString.prefix(8).lowercased()).\(ext)"
        queue.sync {
            items[path] = Item(body: body, mime: mime, contentFeatures: contentFeatures, transferMode: transferMode)
            order.append(path)
            while order.count > 6 { items.removeValue(forKey: order.removeFirst()) }
        }
        return path
    }

    // MARK: - HTTP

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        readHead(connection, buffer: Data())
    }

    private func readHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, done, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(connection, head: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if done || error != nil || buffer.count > 64 * 1024 {
                connection.cancel()
            } else {
                self.readHead(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return sendStatus(connection, "400 Bad Request") }
        let method = String(requestLine[0])
        let path = String(requestLine[1].split(separator: "?").first ?? "")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        guard method == "GET" || method == "HEAD" else { return sendStatus(connection, "405 Method Not Allowed") }
        guard let item = items[path] else { return sendStatus(connection, "404 Not Found") }

        let total: Int
        switch item.body {
        case .data(let data): total = data.count
        case .file(let url): total = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }

        var range = 0...max(0, total - 1)
        var partial = false
        if let header = headers["range"] {
            guard let requested = Self.parseRange(header, total: total) else {
                return sendStatus(connection, "416 Range Not Satisfiable", extra: "Content-Range: bytes */\(total)\r\n")
            }
            range = requested
            partial = true
        }
        let length = total == 0 ? 0 : range.count

        var h = "HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\n"
        h += "Content-Type: \(item.mime)\r\n"
        h += "Content-Length: \(length)\r\n"
        h += "Accept-Ranges: bytes\r\n"
        if partial { h += "Content-Range: bytes \(range.lowerBound)-\(range.upperBound)/\(total)\r\n" }
        h += "contentFeatures.dlna.org: \(item.contentFeatures)\r\n"
        h += "transferMode.dlna.org: \(item.transferMode)\r\n"
        h += "Server: iOS/17 UPnP/1.0 NazCast/1.0\r\n"
        h += "Connection: close\r\n\r\n"
        let header = Data(h.utf8)

        if method == "HEAD" || length == 0 { return sendFinal(connection, header) }

        switch item.body {
        case .data(let data):
            sendFinal(connection, header + data.subdata(in: range.lowerBound..<range.upperBound + 1))
        case .file(let url):
            guard let file = try? FileHandle(forReadingFrom: url) else {
                return sendStatus(connection, "500 Internal Server Error")
            }
            try? file.seek(toOffset: UInt64(range.lowerBound))
            connection.send(content: header, completion: .contentProcessed { [weak self] error in
                guard error == nil, let self else { try? file.close(); connection.cancel(); return }
                self.stream(connection, file: file, remaining: length)
            })
        }
    }

    private func stream(_ connection: NWConnection, file: FileHandle, remaining: Int) {
        guard let chunk = try? file.read(upToCount: min(remaining, 256 * 1024)), !chunk.isEmpty else {
            try? file.close()
            connection.cancel()
            return
        }
        let left = remaining - chunk.count
        connection.send(content: chunk, isComplete: left <= 0, completion: .contentProcessed { [weak self] error in
            if error != nil || left <= 0 {
                try? file.close()
                connection.cancel()
                return
            }
            self?.stream(connection, file: file, remaining: left)
        })
    }

    private func sendStatus(_ connection: NWConnection, _ status: String, extra: String = "") {
        sendFinal(connection, Data("HTTP/1.1 \(status)\r\n\(extra)Content-Length: 0\r\nConnection: close\r\n\r\n".utf8))
    }

    private func sendFinal(_ connection: NWConnection, _ data: Data) {
        connection.send(content: data, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Parses `bytes=start-end`, `bytes=start-` and `bytes=-suffix`. Only the first range is honoured.
    static func parseRange(_ value: String, total: Int) -> ClosedRange<Int>? {
        guard total > 0, value.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = value.dropFirst(6).split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty {
            guard let suffix = Int(parts[1]), suffix > 0 else { return nil }
            return max(0, total - suffix)...(total - 1)
        }
        guard let start = Int(parts[0]), start < total else { return nil }
        let end = parts[1].isEmpty ? total - 1 : min(Int(parts[1]) ?? total - 1, total - 1)
        guard end >= start else { return nil }
        return start...end
    }
}

/// Runs a closure at most once, from any thread.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}
