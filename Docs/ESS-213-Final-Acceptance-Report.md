# ESS-213 / ESS-21 final acceptance report

- Date: 2026-08-04 (Asia/Shanghai)
- Executor: 毕玄
- Acceptance baseline: `76d08d69af34efbc16c71cca7a7ab25e03ef199e`
- Result: **BLOCKED** — the installed physical-Watch build and deployed Bridge do not match the locked baseline
- Test policy: test and report only; the system under test was not modified (R-03)

## Environment and baseline gates

| Check | Result | Evidence |
|---|---|---|
| Repository HEAD | PASS | `git rev-parse HEAD` → `76d08d69af34efbc16c71cca7a7ab25e03ef199e` |
| Physical iPhone / Watch availability | BLOCKED | `xcrun xctrace list devices`: `jackson_iPhone14` and `白梦林的Apple Watch` are both Offline |
| G8 installed build fingerprint | FAIL | `ERR_BUILD_STALE`: Watch `built_at=2026-08-03T17:36:36Z`, baseline commit time `2026-08-03T17:44:16Z` |
| G9 installed self-check | FAIL | `ERR_SELFCHECK_STALE`: newest self-check belongs to the same stale build |
| Deployed Bridge revision | FAIL | `/Users/jacksonmac/Services/Personal-Avatar-iWatch` HEAD is `a6e70d454490b358caad89e5089efca23e466fa1`, not `76d08d6` |

Gate command:

```text
node Scripts/preflight.mjs --log /Users/jacksonmac/Services/Personal-Avatar-iWatch/MacRemoteFrontendBridge/logs/bridge.log --rev 76d08d6 --repo .
G8 装机指纹：FAIL [ERR_BUILD_STALE] ...
G9 装机自检：FAIL [ERR_SELFCHECK_STALE] ...
```

The preflight contract says not to start manual acceptance when either gate fails. Therefore no evidence from the stale physical installation is counted as acceptance evidence for `76d08d6`.

## Executed tests

| Area | Result | Evidence |
|---|---|---|
| Repository standard verification | PASS | `./Scripts/verify.sh`, exit 0; mock gateway 6/6; Swift tests passed; iOS Simulator build succeeded |
| watchOS host tests | PASS with one SKIP | watchOS 26.5 simulator `CE420398-D737-41C3-9B75-A08A30EDF376`; 24 passed, 1 skipped, 0 failed; xcresult summary |
| Playback after recording handover | PASS | runtime events: `request_id=ess72-record-then-play`, `play_started`, then `play_finished successfully=true` |
| Speaker activation and successful playback | PASS (simulator only) | runtime events include `session_activated ... route=Speaker(Speaker)` and `play_finished successfully=true` for `ess73-replay-after-began` and `ess73-stale-flag` |
| SelfCheck yield barrier | PASS (host test) | 3/3 tests passed; runtime `selfcheck_session_yield` events for S1→S2 and S3→S3R |
| Bridge regression suite | PASS | after `npm ci`, `npm test`: 85 passed, 0 failed, 0 skipped |
| ACK/redelivery model | PASS (mock) | Bridge suite covers reconnect redelivery, ACK stop condition, duplicate ACK, and persisted ACK across restart |

The first Bridge test attempt was an environment setup failure (`ws` dependency absent: 35 pass / 6 module-load failures). After the lockfile-defined `npm ci`, the unchanged suite passed 85/85; this is not recorded as a product defect.

## ESS-21 acceptance matrix

| Acceptance item | Status | Reason / evidence |
|---|---|---|
| ESS-7 simulator critical matrix | PARTIAL PASS | automated Swift, build, Watch host, audio handover, interruption, error presentation and Bridge suites passed; interactive UI cases not executed |
| Five consecutive physical-Watch Chinese voice requests | NOT RUN | physical iPhone/Watch Offline and installed Watch build stale |
| Bare-Watch speaker playback on `76d08d6` | NOT RUN | simulator runtime passed; physical installed build is older than the baseline |
| Physical S2 / S4 self-check on `76d08d6` | NOT RUN | latest physical self-check is stale; its `ERR_PLAY_INCOMPLETE` must not be attributed to the new baseline |
| 100 ms empty-touch card + failure haptic + error voice within 5 s | NOT RUN | requires the locked physical installation and interactive observation |
| Four-state orb and five bundled Qwen error clips | NOT RUN | bundle was built in simulator, but final physical bundle/UI/audio observation was unavailable |
| R-02.2 play × record, both directions | PARTIAL PASS | host runtime proves record→play; physical play→record and audible output not run |
| R-02.2 notification × playback, both directions | NOT RUN | physical device unavailable |
| R-02.2 lock screen × recording, both directions | NOT RUN | physical device unavailable |
| R-02.2 background wake × result redelivery | PARTIAL PASS | Bridge mock passed; physical suspend/wake not run |
| R-02.2 recording × concurrent result arrival | NOT RUN | physical device unavailable |
| ESS-171 playback-success ACK closes redelivery loop | PARTIAL PASS | mock 85/85 covers ACK/redelivery semantics; no `76d08d6` physical request_id chain was produced |

## Runtime evidence boundary

The production log contains older runtime examples of `route=Speaker`, successful playback, and ACK, including request `019fc8b5-08e1-7ae3-8931-e38d3bccfc42`. Those events came from a build with `built_at=2026-08-03T17:36:36Z`, earlier than `76d08d6`, so they are historical evidence only and are not counted as this acceptance run.

## Required next run

1. Deploy the Bridge from `76d08d6` and verify its revision.
2. Sign and reinstall the iPhone and Watch apps from the same locked commit.
3. Bring both physical devices Online, cold-start the Watch app, and require G8/G9 PASS.
4. Execute every NOT RUN / PARTIAL item above, preserving request IDs and `watch_client_log` events.
5. Only if all blocking items pass should ESS-213 and ESS-21 move to review.
