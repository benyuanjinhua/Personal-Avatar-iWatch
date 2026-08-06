import Foundation
import XCTest

/// ESS-498: shared gate for tests that touch real audio HW.
///
/// Background: GitHub Actions hosted `macos-15` runners have no audio hardware.
/// Any watchOS test that drives `AudioRecorder.start()` gets stuck in an async
/// path that never resolves (`requestRecordPermission` callback / session
/// activation / recorder init — the exact frame is still being triaged in
/// ESS-499). The first symptom hit `testFinishedDurationIsBoundedAndSelfConsistent`
/// on `main@a731383` run `31058623043` (60min hard-cancel); the same class of
/// hang re-surfaced on PR #197 run `31076606561` after that one test was skipped,
/// implicating the whole family of `recorder.start()`-using tests.
///
/// This gate skips the test only when the test bundle was **built** with the
/// `-D ESS_498_HOSTED_CI` Swift compile flag (set by the CI workflow via
/// `OTHER_SWIFT_FLAGS`). We use a compile-time flag rather than a runtime env
/// var because xcodebuild's test-host launch does not reliably forward host
/// env vars through simctl into the watchOS test process (verified locally:
/// `RUNNER_ENVIRONMENT`, `SIMCTL_CHILD_*`, and `TEST_RUNNER_*` prefixes all
/// silently drop). Local developer builds and real-device sim CI never pass
/// this flag, so those envs run the full test body — the end-to-end coverage
/// that ESS-360 / G9 装机 rely on is preserved.
enum HostedCITestGate {

    /// True iff this test bundle was built with `-D ESS_498_HOSTED_CI`.
    /// The CI workflow sets that flag on the `xcodebuild test` step; local /
    /// real-device sim builds omit it and this reads false.
    static var isGitHubHosted: Bool {
        #if ESS_498_HOSTED_CI
        true
        #else
        false
        #endif
    }

    /// Throws `XCTSkip` (with an ESS-498 prefix) when the current process is on
    /// GitHub hosted CI. No-op on local + real-device sim.
    ///
    /// Callers should place `try HostedCITestGate.skipIfHostedCI(...)` at the
    /// top of the test body, before any `await Task.sleep`, `player.play`, or
    /// `recorder.start` call.
    static func skipIfHostedCI(
        _ reason: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        if isGitHubHosted {
            throw XCTSkip(
                "ESS-498: \(reason) (hangs on GitHub hosted CI — no audio HW; runs on local mac + real-device sim)",
                file: file, line: line
            )
        }
    }
}
