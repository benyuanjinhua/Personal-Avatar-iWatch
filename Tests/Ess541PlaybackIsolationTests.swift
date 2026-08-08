import XCTest
@testable import WristAgentCore

final class Ess541PlaybackIsolationTests: XCTestCase {
    func testFiveConsecutiveTurnsOnlyAdmitCurrentRequest() {
        var isolation = ResultPlaybackIsolation()
        var ids: [String] = []

        for round in 1...5 {
            let id = "request-\(round)"
            ids.append(id)
            let key = isolation.begin(requestId: id)
            XCTAssertEqual(key.generation, round)
            XCTAssertEqual(isolation.decide(requestId: id), .accept(key))

            for old in ids.dropLast() {
                guard case .drop(_, let incomingGeneration, let current, let reason) =
                        isolation.decide(requestId: old) else {
                    return XCTFail("old request \(old) entered round \(round)")
                }
                XCTAssertLessThan(incomingGeneration ?? .max, current?.generation ?? .min)
                XCTAssertEqual(reason, .staleGeneration)
            }
        }
    }

    func testLateUnknownRequestIsRejectedWithoutChangingCurrentOwner() {
        var isolation = ResultPlaybackIsolation()
        let current = isolation.begin(requestId: "new")

        XCTAssertEqual(
            isolation.decide(requestId: "redelivered-old"),
            .drop(incomingRequestId: "redelivered-old", incomingGeneration: nil,
                  current: current, reason: .staleRequest)
        )
        XCTAssertEqual(isolation.decide(requestId: "new"), .accept(current))
    }

    func testAnnouncementWithoutRequestIdIsRejected() {
        var isolation = ResultPlaybackIsolation()
        let current = isolation.begin(requestId: "current")

        XCTAssertEqual(
            isolation.decide(requestId: nil),
            .drop(incomingRequestId: nil, incomingGeneration: nil,
                  current: current, reason: .missingRequestId)
        )
        XCTAssertEqual(isolation.decide(requestId: "current"), .accept(current))
    }
}
