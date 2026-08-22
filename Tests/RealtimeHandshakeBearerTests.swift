import Foundation
import XCTest
import Darwin
@testable import WristAgentCore

/// ESS-885 protocol-level regression: the iPhone Realtime WSS upgrade must
/// carry the `Authorization: Bearer <token>` header all the way into the
/// socket upgrade — not merely on the `URLRequest` object.
///
/// `URLSessionWebSocketTask` historically dropped custom HTTP headers during
/// the WebSocket handshake, which surfaced on real devices as
/// `Gateway ws_upgrade_rejected ERR_TOKEN_INVALID reason=missing_bearer`.
/// These tests bind a loopback TCP listener, run the REAL
/// `AudioRealtimeAgentTransport` (a real `URLSessionWebSocketTask`) against it,
/// and assert on the bytes the server actually received. That is the protocol
/// contract, independent of how Foundation chooses to implement the handshake.
@MainActor
final class RealtimeHandshakeBearerTests: XCTestCase {
    private let sessionId = "885a1000-0000-4000-8000-000000000001"
    private let requestId = "885a2000-0000-4000-8000-000000000002"

    /// The development universal token the iPhone ships today. It contains an
    /// underscore, which is exactly the shape that exposed the Gateway-side
    /// `missing_bearer` admission bug (ESS-885) — keep the literal realistic.
    private let devToken = "rtk_dev_universal"

    // MARK: - Positive: the real upgrade carries the Bearer

    func testClientHandshakeCarriesAuthorizationBearer() throws {
        let server = HandshakeCaptureServer()
        server.start()
        defer { server.stop() }

        let config = AudioRealtimeAgentConfig(
            gatewayURL: URL(string: "ws://127.0.0.1:\(server.port)/api/realtime")!,
            authToken: devToken,
            deviceId: "dut"
        )
        let transport = AudioRealtimeAgentTransport.create(
            config: config, sessionId: sessionId,
            requestId: requestId, generation: 1
        )
        XCTAssertNotNil(transport, "transport must be created for a non-empty bearer")
        defer { transport?.close(reason: "test_done") }

        let head = server.requestHead(timeout: 5)
        let requestHead = try XCTUnwrap(head, "server never saw the WebSocket upgrade request")

        // The protocol contract under test: the Authorization header, with a
        // Bearer scheme and the exact token, must be present in the wire bytes.
        XCTAssertTrue(
            requestHead.contains("Authorization: Bearer \(devToken)"),
            "WebSocket upgrade must carry Authorization Bearer; received:\n\(requestHead)"
        )
        // The upgrade must target the realtime path and bind scope via query.
        XCTAssertTrue(requestHead.hasPrefix("GET /api/realtime"), "unexpected request line: \(requestHead)")
        XCTAssertTrue(requestHead.contains("device_id=dut"), "scope query must carry device_id")
        XCTAssertTrue(requestHead.contains("session_id=\(sessionId)"), "scope query must carry session_id")
        XCTAssertTrue(requestHead.contains("request_id=\(requestId)"), "scope query must carry request_id")
        XCTAssertTrue(requestHead.contains("generation=1"), "scope query must carry generation")
    }

    // MARK: - Negative: a missing bearer cannot produce a handshake

    func testTransportRefusesMissingBearerToken() {
        // `AudioRealtimeAgentConfig.validate` already rejects an empty token
        // (see AudioRealtimeAgentSessionTests), and the transport factory must
        // fail closed as well so no caller can build a socket that would send
        // an empty `Authorization: Bearer ` header.
        let config = AudioRealtimeAgentConfig(
            gatewayURL: URL(string: "wss://agent.example/api/realtime")!,
            authToken: "",
            deviceId: "dut"
        )
        let transport = AudioRealtimeAgentTransport.create(
            config: config, sessionId: sessionId,
            requestId: requestId, generation: 1
        )
        XCTAssertNil(transport, "transport creation must fail when the bearer token is missing")
    }
}

/// Minimal loopback TCP listener that captures the first HTTP request head
/// (everything up to `\r\n\r\n`) and then closes. It deliberately does NOT
/// complete the WebSocket handshake — the test only needs the bytes the client
/// sent, not a successful socket.
final class HandshakeCaptureServer: @unchecked Sendable {
    private let lock = NSLock()
    private var _port: UInt16 = 0
    private var _requestHead: String?
    private var serverFD: Int32 = -1
    private var connFD: Int32 = -1
    private let queue = DispatchQueue(label: "ess885.handshake-capture")
    private let ready = DispatchSemaphore(value: 0)

    var port: UInt16 {
        lock.lock(); defer { lock.unlock() }
        return _port
    }

    func start() {
        queue.async { self.run() }
        ready.wait()
    }

    func requestHead(timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let head = _requestHead
            lock.unlock()
            if head != nil { return head }
            Thread.sleep(forTimeInterval: 0.02)
        }
        lock.lock()
        let head = _requestHead
        lock.unlock()
        return head
    }

    func stop() {
        if connFD >= 0 { Darwin.close(connFD); connFD = -1 }
        if serverFD >= 0 { Darwin.close(serverFD); serverFD = -1 }
    }

    private func run() {
        serverFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard serverFD >= 0 else { return }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(serverFD, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        var actual = sockaddr_in()
        _ = withUnsafeMutablePointer(to: &actual) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.getsockname(serverFD, sa, &len)
            }
        }
        lock.lock()
        _port = actual.sin_port.bigEndian
        lock.unlock()

        _ = Darwin.listen(serverFD, 1)
        ready.signal()

        connFD = Darwin.accept(serverFD, nil, nil)
        guard connFD >= 0 else { return }

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while data.range(of: Data("\r\n\r\n".utf8)) == nil && data.count < 65_536 {
            let n = Darwin.read(connFD, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        lock.lock()
        _requestHead = String(data: data, encoding: .utf8)
        lock.unlock()
    }
}
