import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
import { RealtimeMediaSession } from '../realtime-media-session.mjs'

function fixture() {
  const upstream = []
  const downstream = []
  const completed = []
  const firstAudio = []
  const session = new RealtimeMediaSession({
    requestId: '019fcac2-20ce-75b6-a665-24eb965a32a9',
    sessionId: 'watch-session-1',
    sendUpstream: event => upstream.push(event),
    sendDownstream: event => downstream.push(event),
    onFirstAudio: event => firstAudio.push(event),
    onResponseComplete: result => completed.push(result),
  })
  return { session, upstream, downstream, completed, firstAudio }
}

describe('ESS-265 realtime media plane', () => {
  it('forwards input frames immediately and commits without whole-turn buffering', () => {
    const { session, upstream } = fixture()
    session.appendInput({ sequence: 0, audio: Buffer.from([1, 2]) })
    assert.deepEqual(upstream, [{ type: 'audio.append', audio: 'AQI=' }])
    session.appendInput({ sequence: 1, audio: Buffer.from([3, 4]) })
    assert.equal(upstream.length, 2)
    session.endInput()
    assert.deepEqual(upstream.at(-1), { type: 'audio.commit' })
  })

  it('rejects gaps, duplicates, invalid formats and oversized frames', () => {
    const { session } = fixture()
    assert.throws(() => session.appendInput({ sequence: 1, audio: Buffer.from([1]) }), /sequence/)
    assert.throws(() => session.appendInput({ sequence: 0, audio: Buffer.from([1]), sampleRate: 24_000 }), /format/)
    assert.throws(() => session.appendInput({ sequence: 0, audio: Buffer.alloc(70_000) }), /frame size/)
  })

  it('forwards each agent audio delta immediately and deduplicates sequence retries', () => {
    const { session, downstream, firstAudio } = fixture()
    assert.equal(session.handleAgentEvent({
      type: 'audio.delta', responseId: 'resp-1', sequence: 0,
      sampleRate: 24_000, audio: Buffer.from([7, 8]).toString('base64'),
    }), true)
    assert.equal(downstream.length, 1)
    assert.deepEqual(firstAudio, [{ responseId: 'resp-1', bytes: 2 }])
    assert.equal(downstream[0].audio, 'Bwg=')
    assert.equal(session.handleAgentEvent({
      type: 'audio.delta', responseId: 'resp-1', sequence: 0,
      audio: Buffer.from([7, 8]).toString('base64'),
    }), false)
    assert.equal(downstream.length, 1)
    assert.equal(firstAudio.length, 1)
  })

  it('uses real player receipts instead of acknowledging on delta receipt', () => {
    const { session, upstream } = fixture()
    session.handleAgentEvent({ type: 'audio.delta', responseId: 'resp-1', audio: 'AQI=' })
    assert.equal(upstream.length, 0)
    session.playbackStarted('resp-1')
    session.playbackEnded('resp-1')
    assert.deepEqual(upstream, [
      { type: 'playback.started', responseId: 'resp-1' },
      { type: 'playback.ended', responseId: 'resp-1' },
    ])
  })

  it('normalizes audio.done metadata for the Watch completion barrier', () => {
    const { session, downstream } = fixture()
    session.handleAgentEvent({
      type: 'audio.delta', responseId: 'resp-1', sequence: 0,
      audio: Buffer.from([1, 2]).toString('base64'),
    })
    session.handleAgentEvent({
      type: 'audio.delta', responseId: 'resp-1', sequence: 1,
      audio: Buffer.from([3, 4]).toString('base64'),
    })

    assert.equal(session.handleAgentEvent({
      type: 'audio.done', responseId: 'resp-1', turnGeneration: 3,
    }), true)
    assert.deepEqual(downstream.at(-1), {
      type: 'audio.done', request_id: '019fcac2-20ce-75b6-a665-24eb965a32a9',
      session_id: 'watch-session-1', response_id: 'resp-1',
      generation: 3, final_sequence: 1,
    })
  })

  it('marks a zero-audio response with final_sequence -1', () => {
    const { session, downstream } = fixture()
    session.handleAgentEvent({ type: 'audio.done', responseId: 'resp-empty' })
    assert.equal(downstream.at(-1).response_id, 'resp-empty')
    assert.equal(downstream.at(-1).final_sequence, -1)
  })

  it('reports direct and delegated turn completion only when the voice turn is idle', () => {
    const direct = fixture()
    direct.session.handleAgentEvent({ type: 'transcript.final', role: 'assistant', content: '直接结果' })
    direct.session.handleAgentEvent({ type: 'audio.done', responseId: 'resp-direct' })
    assert.equal(direct.completed.length, 0)
    direct.session.handleAgentEvent({ type: 'voice.state', state: 'idle', responseId: 'resp-direct' })
    assert.deepEqual(direct.completed, [{ responseId: 'resp-direct', assistantTranscript: '直接结果', taskId: null }])

    const delegated = fixture()
    delegated.session.handleAgentEvent({ type: 'task.accepted', task: { id: 'task-1' } })
    delegated.session.handleAgentEvent({ type: 'voice.state', state: 'idle' })
    assert.equal(delegated.completed[0].taskId, 'task-1')
  })

  it('retains ownership when task.completed is the first task lifecycle event', () => {
    const delayed = fixture()
    assert.equal(delayed.session.handleAgentEvent({
      type: 'task.completed', task: { id: 'task-late' },
    }), true)
    delayed.session.handleAgentEvent({ type: 'voice.state', state: 'idle' })
    assert.equal(delayed.completed[0].taskId, 'task-late')
  })

  it('barge-in cancels the active response and clears client playback', () => {
    const { session, upstream, downstream } = fixture()
    session.handleAgentEvent({ type: 'audio.delta', responseId: 'resp-1', audio: 'AQI=' })
    session.bargeIn()
    assert.deepEqual(upstream, [{ type: 'response.cancel', responseId: 'resp-1' }])
    assert.equal(downstream.at(-1).type, 'playback.clear')
    assert.equal(downstream.at(-1).response_id, 'resp-1')
  })

  it('stops forwarding after terminal close', () => {
    const { session, downstream } = fixture()
    assert.equal(session.close(), true)
    assert.equal(session.close(), false)
    assert.equal(session.handleAgentEvent({ type: 'audio.delta', audio: 'AQI=' }), false)
    assert.equal(downstream.length, 0)
    assert.throws(() => session.appendInput({ sequence: 0, audio: Buffer.from([1]) }), /not open/)
  })
})
