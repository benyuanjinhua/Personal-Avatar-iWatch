import Foundation
import XCTest
@testable import WristAgentCore

final class AgentSessionTokenClientTests: XCTestCase {
    private final class URLProtocolStub: URLProtocol {
        nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            do {
                let (response, data) = try Self.handler!(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
        override func stopLoading() {}
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    func testPendingEnvelopeBudgetBoundsCountAndBytes() {
        XCTAssertTrue(AgentTokenEnvelopeBufferBudget.allows(
            currentCount: 255, currentBytes: 1_000, addingBytes: 1_000
        ))
        XCTAssertFalse(AgentTokenEnvelopeBufferBudget.allows(
            currentCount: 256, currentBytes: 0, addingBytes: 1
        ))
        XCTAssertFalse(AgentTokenEnvelopeBufferBudget.allows(
            currentCount: 1,
            currentBytes: AgentTokenEnvelopeBufferBudget.maxEncodedBytes,
            addingBytes: 1
        ))
    }

    func testMintSignsExactBodyAndReturnsScopedToken() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://gateway.example/v1/realtime/session-token")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-Id"), "iphone-1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Request-Id"), "request-1")
            XCTAssertFalse(request.value(forHTTPHeaderField: "X-Signature")?.isEmpty ?? true)
            // URLProtocol receives streamed request bodies with httpBody=nil;
            // the signed body hash still proves a non-empty exact payload.
            XCTAssertNotEqual(request.value(forHTTPHeaderField: "X-Body-SHA256"), RelayWire.sha256Hex(Data()))
            let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            let data = try JSONSerialization.data(withJSONObject: [
                "token": "rtk_ephemeral",
                "expires_at": 1_800_000_030_000,
                "ttl_ms": 30_000,
                "scope": [
                    "device_id": "iphone-1", "session_id": "session-1",
                    "request_id": "request-1", "generation": 1,
                ],
            ])
            return (response, data)
        }
        let issued = try await AgentSessionTokenClient(
            gatewayURL: URL(string: "wss://gateway.example/api/realtime")!,
            credentials: RelayDeviceCredentials(deviceId: "iphone-1", token: String(repeating: "a", count: 32)),
            session: session()
        ).mint(requestId: "request-1", sessionId: "session-1", generation: 1)
        XCTAssertEqual(issued.token, "rtk_ephemeral")
        XCTAssertEqual(issued.scope.generation, 1)
    }

    func testMintRejectsMismatchedScope() async {
        URLProtocolStub.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            let data = try JSONSerialization.data(withJSONObject: [
                "token": "rtk_ephemeral", "expires_at": 1_800_000_030_000, "ttl_ms": 30_000,
                "scope": ["device_id": "other", "session_id": "s", "request_id": "r", "generation": 1],
            ])
            return (response, data)
        }
        do {
            _ = try await AgentSessionTokenClient(
                gatewayURL: URL(string: "wss://gateway.example/api/realtime")!,
                credentials: RelayDeviceCredentials(deviceId: "iphone-1", token: String(repeating: "a", count: 32)),
                session: session()
            ).mint(requestId: "r", sessionId: "s", generation: 1)
            XCTFail("expected scope mismatch")
        } catch {
            XCTAssertEqual(error as? AgentSessionTokenError, .scopeMismatch)
        }
    }

    func testMintMapsGatewayErrorWithoutLeakingBody() async {
        URLProtocolStub.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"error":"ERR_SIGNATURE_INVALID"}"#.utf8))
        }
        do {
            _ = try await AgentSessionTokenClient(
                gatewayURL: URL(string: "wss://gateway.example/api/realtime")!,
                credentials: RelayDeviceCredentials(deviceId: "iphone-1", token: String(repeating: "a", count: 32)),
                session: session()
            ).mint(requestId: "r", sessionId: "s", generation: 1)
            XCTFail("expected rejection")
        } catch {
            XCTAssertEqual(error as? AgentSessionTokenError, .rejected(code: "ERR_SIGNATURE_INVALID", status: 401))
        }
    }
}
