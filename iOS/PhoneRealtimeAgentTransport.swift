import Foundation
import os

/// ESS-391 production transport adapter: wraps `AudioRealtimeAgentSession` so
/// it conforms to `PhoneRealtimeSession.Transport`, translating Watch-side
/// `RealtimeUplinkEnvelope`/`RealtimeDownlinkEnvelope` ↔ Agent
/// `AudioRealtimeAgentCodec.UplinkFrame`/`DownlinkEvent`.
///
/// The iPhone is the **sole generation owner** (ESS-391 §契约). When Watch
/// sends a `bargein.request` uplink, this transport advances generation,
/// sends `cancel(from_generation)` on the Agent WSS, and replies with a
/// `generation.open(new_gen)` downlink envelope.
///
/// Codec boundaries:
///   - Uplink: Watch envelope → Agent frame (stream.start, audio.append,
///     audio.commit, cancel). Playback receipts and fallback are no-ops
///     through the Agent path (the Agent does not consume Bridge receipts).
///   - Downlink: Agent event → Watch envelope (ready is logged; audio.delta
///     and audio.done carry generation+finalSequence per ESS-404).
@MainActor
final class PhoneRealtimeAgentTransport: PhoneRealtimeSession.Transport {
    private static let logger = Logger(
        subsystem: "com.benyuan.wristagent.phone",
        category: "AgentTransport"
    )

    /// Log module for `PhoneAgentClientLog` entries emitted by this
    /// enqueue-to-Watch adapter (ESS-525 §1 requires
    /// `downlink_enqueued` / `play_started` / `play_finished`).
    private static let logModule = "agent_bridge"

    /// Caller-provided sink that pushes decoded downlink envelopes back to
    /// `PhoneConnectivity.forwardRealtimeDownlink`.
    var onDownlink: ((RealtimeDownlinkEnvelope) -> Void)?

    /// Caller-provided sink so `PhoneRealtimeSession` can signal state
    /// changes to its coordinator (used for UI/log evidence).
    var onStateChange: ((PhoneRealtimeSession.State) -> Void)?

    private var agentSession: AudioRealtimeAgentSession
    private let replacementSession: (Int) async throws -> AudioRealtimeAgentSession
    private let requestId: String
    private let sessionId: String

    /// Current turn generation. iPhone owns this counter; Watch requests
    /// advancement via `bargein.request`.
    private var gate: BargeInGenerationCoordinator
    private var cancelTimeout: Task<Void, Never>?

    /// Pending completion for the latest `send` call — the Agent transport
    /// is asynchronous (WSS), so `send` reports completion via this pending
    /// closure on error or next success.
    private var pendingSendCompletion: (@MainActor (Error?) -> Void)?

    init(
        config: AudioRealtimeAgentConfig,
        agentSession: AudioRealtimeAgentSession,
        requestId: String,
        sessionId: String,
        generation: Int = 0,
        replacementSession: @escaping (Int) async throws -> AudioRealtimeAgentSession
    ) {
        self.agentSession = agentSession
        self.requestId = requestId
        self.sessionId = sessionId
        self.gate = BargeInGenerationCoordinator(generation: generation)
        self.replacementSession = replacementSession
        wireAgentSession()
        _ = agentSession.connect(requestId: requestId, generation: generation)
    }

    // MARK: - PhoneRealtimeSession.Transport

    func send(_ envelope: RealtimeUplinkEnvelope, completion: @escaping @MainActor (Error?) -> Void) {
        pendingSendCompletion = completion
        switch envelope.kind {
        case .streamStart:
            // Agent path: stream.start is already sent by `connect()`. If
            // Watch re-sends, it's idempotent — no WSS frame needed.
            Self.logger.debug("agent stream.start (idempotent) rid=\(self.requestId.prefix(8), privacy: .public)")
            completion(nil)

        case .audioAppend:
            guard let append = envelope.append else {
                completion(NSError(domain: "PhoneRealtimeAgentTransport", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "missing audio.append payload"]))
                return
            }
            agentSession.sendAudioChunk(append, requestId: requestId, generation: gate.generation)
            // Agent session handles send completion internally; report ack
            // synchronously to keep the PhoneRealtimeSession contract.
            completion(nil)

        case .audioCommit:
            guard let commit = envelope.commit else {
                completion(NSError(domain: "PhoneRealtimeAgentTransport", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "missing audio.commit payload"]))
                return
            }
            agentSession.commitUplink(requestId: requestId, generation: gate.generation,
                                      finalSequence: commit.sequence)
            completion(nil)

        case .bargeInRequest:
            guard let ask = envelope.bargeIn else {
                completion(NSError(domain: "PhoneRealtimeAgentTransport", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "missing bargein.request payload"]))
                return
            }
            handleBargeInRequest(fromGeneration: ask.fromGeneration)
            completion(nil)

        case .playbackStarted, .playbackEnded:
            // Playback receipts from Watch are forwarded to the Agent
            // Gateway as playback.started/playback.ended uplink frames.
            guard let receipt = envelope.playback else {
                completion(nil)
                return
            }
            if envelope.kind == .playbackStarted {
                agentSession.transport?.send(
                    .playbackStarted(sessionId: sessionId, requestId: requestId,
                                     responseId: receipt.requestId)
                ) { _ in }
                completion(nil)
            } else {
                agentSession.transport?.send(
                    .playbackEnded(sessionId: sessionId, requestId: requestId,
                                   responseId: receipt.requestId)
                ) { _ in }
                completion(nil)
            }

        case .fallback:
            let reason = envelope.fallback?.reason ?? "bridge_fallback"
            agentSession.disconnect(reason: reason)
            onStateChange?(.failed(reason: reason))
            completion(nil)
        }
    }

    func receive(handler: @escaping @MainActor (Result<RealtimeDownlinkEnvelope, Error>) -> Void) {
        // The Agent session delivers events via callbacks (onAudioDelta,
        // onAudioDone, etc.) wired in `wireAgentSession()`. The `receive`
        // contract in `PhoneRealtimeSession.Transport` is start-once +
        // continuous delivery — we satisfy it by keeping the Agent session
        // alive and pushing events through `onDownlink`.
        //
        // No additional receive-loop setup is needed; the callback wiring
        // is idempotent per `wireAgentSession`.
    }

    func close(reason: String) {
        cancelTimeout?.cancel()
        agentSession.disconnect(reason: reason)
    }

    // MARK: - Generation owner

    private func handleBargeInRequest(fromGeneration: Int) {
        Self.logger.info(
            "agent bargein.request from_gen=\(fromGeneration, privacy: .public) current=\(self.gate.generation, privacy: .public)"
        )
        guard case .cancel(let old) = gate.request(from: fromGeneration) else { return }
        agentSession.cancel(requestId: requestId, generation: old, reason: "barge-in") { [weak self] in
            self?.failReplacement("cancel_failed")
        }
        cancelTimeout?.cancel()
        cancelTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.settleCancel(old)
        }
    }

    private func settleCancel(_ old: Int) {
        guard case .mintAndConnect(let next) = gate.cancelSettled(generation: old) else { return }
        cancelTimeout?.cancel()
        Task { [weak self] in
            guard let self else { return }
            do {
                let fresh = try await replacementSession(next)
                agentSession.disconnect(reason: "generation_replaced")
                agentSession = fresh
                wireAgentSession()
                guard fresh.connect(requestId: requestId, generation: next) else {
                    failReplacement("wss_upgrade_failed")
                    return
                }
            } catch {
                failReplacement("token_mint_failed")
            }
        }
    }

    private func failReplacement(_ reason: String) {
        guard case .fallback = gate.fail(reason) else { return }
        agentSession.disconnect(reason: reason)
        onDownlink?(.bargeInFailed(
            requestId: requestId, sessionId: sessionId,
            fromGeneration: gate.generation, reason: reason
        ))
        onStateChange?(.failed(reason: reason))
    }

    // MARK: - Agent session wiring

    private func wireAgentSession() {
        agentSession.onAudioDelta = { [weak self] chunk, responseId, gen in
            guard let self else { return }
            guard gen == self.gate.generation else {
                PhoneAgentClientLog.info(
                    module: Self.logModule,
                    event: "downlink_audio_delta_stale_generation",
                    requestId: self.requestId, sessionId: self.sessionId,
                    detail: "seq=\(chunk.sequence) frame_gen=\(gen) current_gen=\(self.gate.generation)"
                )
                return
            }
            let envelope = RealtimeDownlinkEnvelope.audioDelta(
                chunk, responseId: responseId, generation: gen
            )
            PhoneAgentClientLog.info(
                module: Self.logModule,
                event: "downlink_enqueued",
                requestId: self.requestId, sessionId: self.sessionId,
                detail: "type=audio.delta seq=\(chunk.sequence) bytes=\(chunk.payload.count) gen=\(gen)"
            )
            self.onDownlink?(envelope)
        }
        agentSession.onAudioDone = { [weak self] rid, responseId, gen, finalSeq in
            guard let self else { return }
            guard gen == self.gate.generation else {
                PhoneAgentClientLog.info(
                    module: Self.logModule,
                    event: "downlink_audio_done_stale_generation",
                    requestId: rid, sessionId: self.sessionId,
                    detail: "final_seq=\(finalSeq) frame_gen=\(gen) current_gen=\(self.gate.generation)"
                )
                return
            }
            let envelope = RealtimeDownlinkEnvelope.audioDone(
                requestId: rid, sessionId: self.sessionId,
                responseId: responseId,
                generation: gen,
                finalSequence: finalSeq
            )
            PhoneAgentClientLog.info(
                module: Self.logModule,
                event: "downlink_enqueued",
                requestId: rid, sessionId: self.sessionId,
                detail: "type=audio.done final_seq=\(finalSeq) gen=\(gen)"
            )
            self.onDownlink?(envelope)
        }
        // ESS-971：段落屏障。与 `onAudioDone` 共用同一套 generation 门禁，
        // 但**不**触发任何回合终态——它只是「这一段完了」。
        agentSession.onAudioSegmentDone = { [weak self] rid, responseId, gen, segIdx, finalSeq in
            guard let self else { return }
            guard gen == self.gate.generation else {
                PhoneAgentClientLog.info(
                    module: Self.logModule,
                    event: "downlink_audio_segment_done_stale_generation",
                    requestId: rid, sessionId: self.sessionId,
                    detail: "segment_index=\(segIdx) final_seq=\(finalSeq) frame_gen=\(gen) current_gen=\(self.gate.generation)"
                )
                return
            }
            let envelope = RealtimeDownlinkEnvelope.audioSegmentDone(
                requestId: rid, sessionId: self.sessionId,
                responseId: responseId, generation: gen,
                segmentIndex: segIdx, finalSequence: finalSeq
            )
            PhoneAgentClientLog.info(
                module: Self.logModule,
                event: "downlink_enqueued",
                requestId: rid, sessionId: self.sessionId,
                detail: "type=audio.segment_done segment_index=\(segIdx) final_seq=\(finalSeq) gen=\(gen)"
            )
            self.onDownlink?(envelope)
        }
        agentSession.onError = { [weak self] code, rid, gen, retriable, detail in
            guard let self else { return }
            Self.logger.error(
                "agent gateway error code=\(code, privacy: .public) rid=\(rid.prefix(8), privacy: .public) gen=\(gen) retriable=\(retriable)"
            )
            if !retriable {
                self.onStateChange?(.failed(reason: "gateway_error_\(code)"))
            }
        }
        agentSession.onCancelAck = { [weak self] rid, gen, cancelledRespId in
            guard let self else { return }
            Self.logger.info(
                "agent cancel.ack rid=\(rid.prefix(8), privacy: .public) gen=\(gen) cancelled=\(cancelledRespId.prefix(8), privacy: .public)"
            )
            self.settleCancel(gen)
        }
        agentSession.onConnectionStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .connected(let sid, let rid, let gen):
                Self.logger.info(
                    "agent connected sid=\(sid.prefix(8), privacy: .public) rid=\(rid.prefix(8), privacy: .public) gen=\(gen)"
                )
                self.onStateChange?(.active(requestId: rid, sessionId: sid))
                if case .open(let opened) = self.gate.ready(generation: gen) {
                    self.onDownlink?(.generationOpen(requestId: rid, sessionId: sid, generation: opened))
                    Self.logger.info("agent generation.open rid=\(rid.prefix(8), privacy: .public) sid=\(sid.prefix(8), privacy: .public) gen=\(opened)")
                }
            case .failed(let sid, let reason):
                Self.logger.error(
                    "agent failed sid=\(sid.prefix(8), privacy: .public) reason=\(reason, privacy: .public)"
                )
                self.onStateChange?(.failed(reason: reason))
            case .connecting:
                self.onStateChange?(.connecting(requestId: self.requestId, sessionId: self.sessionId))
            default:
                break
            }
        }
    }
}
