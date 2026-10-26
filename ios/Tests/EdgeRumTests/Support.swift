import Foundation
import XCTest
import zlib

/// URLProtocol stand-in for the collector: replies from a queue, records every request.
final class StubProtocol: URLProtocol {
    enum Reply {
        case status(Int, [String: String] = [:])
        case networkError
    }

    struct Recorded {
        let request: URLRequest
        let body: Data
    }

    static var replies: [Reply] = []
    static var requests: [Recorded] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        replies = []
        requests = []
    }

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return requests.count
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        // URLSession hands protocols the body as a stream, never as httpBody.
        var body = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 8192)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
            stream.close()
        }
        Self.lock.lock()
        Self.requests.append(Recorded(request: request, body: body))
        let reply = Self.replies.isEmpty ? .networkError : Self.replies.removeFirst()
        Self.lock.unlock()

        switch reply {
        case .networkError:
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        case let .status(code, headers):
            let res = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: res, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

func gunzip(_ data: Data) -> String {
    var stream = z_stream()
    XCTAssertEqual(inflateInit2_(&stream, 47, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)), Z_OK)
    defer { inflateEnd(&stream) }
    var input = [UInt8](data)
    var out = Data()
    var buf = [UInt8](repeating: 0, count: 16384)
    var status = Z_OK
    input.withUnsafeMutableBufferPointer { inp in
        stream.next_in = inp.baseAddress
        stream.avail_in = uInt(inp.count)
        repeat {
            buf.withUnsafeMutableBufferPointer { b in
                stream.next_out = b.baseAddress
                stream.avail_out = uInt(b.count)
                status = inflate(&stream, Z_NO_FLUSH)
                out.append(b.baseAddress!, count: b.count - Int(stream.avail_out))
            }
        } while status == Z_OK
    }
    XCTAssertEqual(status, Z_STREAM_END, "not a complete gzip stream")
    return String(decoding: out, as: UTF8.self)
}

func json(_ text: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
}

/// Golden file with whitespace outside strings removed: the envelope is written compact and in a
/// fixed key order, so the snapshot is compared byte for byte.
func golden(_ name: String) -> String {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../golden/\(name)").standardized
    let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    var out = ""
    var inString = false
    var escaped = false
    for c in text {
        if inString {
            out.append(c)
            if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
        } else if c == "\"" {
            inString = true
            out.append(c)
        } else if !c.isWhitespace {
            out.append(c)
        }
    }
    return out
}
