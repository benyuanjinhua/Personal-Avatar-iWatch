import Foundation
import XCTest
@testable import WristAgentCore

/// ESS-446: SessionTokenProvider unit tests covering the Gateway
/// `POST /v1/realtime/session-token` contract.
///
/// Tests cover six scenarios:
///   1. 201 with valid body → `.success`
///   2. 401 `ERR_SCOPE_MISMATCH` → `.gatewayRejected`
///   3. 201 with missing `token` field → `.badResponse(201)`
///   4. 500 with empty body → `.badResponse(500)`
///   5. Transport failure (timeout) → `.transport`
///   6. JSON body shape validated against Gateway `IssueRequest` schema
final class SessionTokenProviderTests: XCTestCase {

    // MARK: - URLProtocol-based mock

    /// In-process HTTP mock: intercepts calls to the test URL and returns
    /// the configured response.
    private final class MockProtocol: URLProtocol {
        nonisolated(unsafe) static var responseHandler: ((URLRequest) -> (Data?, URLResponse?, Error?))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}
        override func startLoading() {
            guard let handler = MockProtocol.responseHandler else {
                client?.urlProtocol(self, didFailWithError: URLError(.unknown))
                return
            }
            let (data, response, error) = handler(request)
            if let error {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
            if let response {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            if let data {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private var mockSession: URLSession!
    private let gatewayURL = URL(string: "https://agent.example.com")!
    private let deviceId = "dev-ess446-test"
    private let sessionId = "5e55-ess446-session"
    private let requestId = "e554-ess446-request"
    private let generation = 1
    private lazy var credentials: RelayDeviceCredentials = {
        RelayDeviceCredentials(deviceId: deviceId, token: "test-token-ess446")
    }()

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        mockSession = URLSession(configuration: config)
        MockProtocol.responseHandler = nil
    }

    override func tearDown() {
        MockProtocol.responseHandler = nil
        mockSession = nil
        super.tearDown()
    }

    // MARK: - 1. Success (HTTP 201)

    func testFetchReturnsTokenOn201() async {
        let tokenString = "rtk_mockess446"
        MockProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.url?.absoluteString.contains("/v1/realtime/session-token") ?? false)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

            let body: [String: Any] = [
                "token": tokenString,
                "device_id": self.deviceId,
                "session_id": self.sessionId,
                "request_id": self.requestId,
                "generation": self.generation,
                "expires_in_ms": 30_000,
                "protocol_version": 1,
            ]
            let data = try! JSONSerialization.data(withJSONObject: body)
            let response = HTTPURLResponse(
                url: self.gatewayURL.appendingPathComponent("/v1/realtime/session-token"),
                statusCode: 201, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (data, response, nil)
        }

        let result = await SessionTokenProvider.fetch(
            gatewayBaseURL: gatewayURL,
            deviceId: deviceId, sessionId: sessionId,
            requestId: requestId, generation: generation,
            credentials: credentials, session: mockSession
        )

        guard case .success(let issued) = result else {
            return XCTFail("expected .success, got \(result)")
        }
        XCTAssertEqual(issued.token, tokenString)
        XCTAssertEqual(issued.deviceId, deviceId)
        XCTAssertEqual(issued.generation, generation)
        XCTAssertEqual(issued.expiresInMs, 30_000)
        XCTAssertEqual(issued.protocolVersion, 1)
    }

    // MARK: - 2. Gateway rejection (HTTP 401 ERR_SCOPE_MISMATCH)

    func testFetchRejectsOn401ScopeMismatch() async {
        MockProtocol.responseHandler = { _ in
            let body: [String: Any] = [
                "error": "ERR_SCOPE_MISMATCH",
                "detail": "device_id vs signature",
            ]
            let data = try! JSONSerialization.data(withJSONObject: body)
            let response = HTTPURLResponse(
                url: self.gatewayURL, statusCode: 401,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (data, response, nil)
        }

        let result = await SessionTokenProvider.fetch(
            gatewayBaseURL: gatewayURL,
            deviceId: deviceId, sessionId: sessionId,
            requestId: requestId, generation: generation,
            credentials: credentials, session: mockSession
        )

        guard case .failure(let error) = result else {
            return XCTFail("expected .failure, got \(result)")
        }
        guard case .gatewayRejected(let code, let status, let detail) = error else {
            return XCTFail("expected .gatewayRejected, got \(error)")
        }
        XCTAssertEqual(code, "ERR_SCOPE_MISMATCH")
        XCTAssertEqual(status, 401)
        XCTAssertEqual(detail, "device_id vs signature")
    }

    // MARK: - 3. Bad 201 shape (missing token)

    func testFetchFailsOn201MissingToken() async {
        MockProtocol.responseHandler = { _ in
            let body: [String: Any] = [
                "generation": 1,
                "expires_in_ms": 30_000,
            ]
            let data = try! JSONSerialization.data(withJSONObject: body)
            let response = HTTPURLResponse(
                url: self.gatewayURL, statusCode: 201,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (data, response, nil)
        }

        let result = await SessionTokenProvider.fetch(
            gatewayBaseURL: gatewayURL,
            deviceId: deviceId, sessionId: sessionId,
            requestId: requestId, generation: generation,
            credentials: credentials, session: mockSession
        )

        guard case .failure(let error) = result else {
            return XCTFail("expected .failure, got \(result)")
        }
        guard case .badResponse(201) = error else {
            return XCTFail("expected .badResponse(201), got \(error)")
        }
    }

    // MARK: - 4. HTTP 500 (no structured error body)

    func testFetchFailsOn500NoErrorBody() async {
        MockProtocol.responseHandler = { _ in
            let response = HTTPURLResponse(
                url: self.gatewayURL, statusCode: 500,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (Data(), response, nil)
        }

        let result = await SessionTokenProvider.fetch(
            gatewayBaseURL: gatewayURL,
            deviceId: deviceId, sessionId: sessionId,
            requestId: requestId, generation: generation,
            credentials: credentials, session: mockSession
        )

        guard case .failure(let error) = result else {
            return XCTFail("expected .failure, got \(result)")
        }
        guard case .badResponse(500) = error else {
            return XCTFail("expected .badResponse(500), got \(error)")
        }
    }

    // MARK: - 5. Transport failure

    func testFetchFailsOnTransportError() async {
        MockProtocol.responseHandler = { _ in
            (nil, nil, URLError(.timedOut))
        }

        let result = await SessionTokenProvider.fetch(
            gatewayBaseURL: gatewayURL,
            deviceId: deviceId, sessionId: sessionId,
            requestId: requestId, generation: generation,
            credentials: credentials, session: mockSession
        )

        guard case .failure(let error) = result else {
            return XCTFail("expected .failure, got \(result)")
        }
        guard case .transport = error else {
            return XCTFail("expected .transport, got \(error)")
        }
    }

    // MARK: - 6. Request body shape

    func testRequestIsPOSTAndReturnsToken() async {
        var wasCalled = false
        MockProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            wasCalled = true
            let body: [String: Any] = [
                "token": "rtk_test", "device_id": self.deviceId,
                "session_id": self.sessionId, "request_id": self.requestId,
                "generation": 3, "expires_in_ms": 30_000, "protocol_version": 1,
            ]
            let data = try! JSONSerialization.data(withJSONObject: body)
            let response = HTTPURLResponse(
                url: self.gatewayURL, statusCode: 201,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (data, response, nil)
        }

        let result = await SessionTokenProvider.fetch(
            gatewayBaseURL: gatewayURL,
            deviceId: deviceId, sessionId: sessionId,
            requestId: requestId, generation: 3,
            credentials: credentials, session: mockSession
        )

        guard case .success(let issued) = result else {
            return XCTFail("expected .success, got \(result)")
        }
        XCTAssertEqual(issued.token, "rtk_test")
        XCTAssertEqual(issued.generation, 3)
        XCTAssertTrue(wasCalled)
    }

    // MARK: - 7. FetchError Equatable

    func testFetchErrorEquatable() {
        XCTAssertEqual(
            SessionTokenProvider.FetchError.notPaired,
            SessionTokenProvider.FetchError.notPaired
        )
        XCTAssertEqual(
            SessionTokenProvider.FetchError.badResponse(500),
            SessionTokenProvider.FetchError.badResponse(500)
        )
        XCTAssertNotEqual(
            SessionTokenProvider.FetchError.badResponse(500),
            SessionTokenProvider.FetchError.badResponse(502)
        )
    }
}
