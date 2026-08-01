// Signed-protocol test client — same wire protocol as the iPhone RelayClient
// (ESS-23 RelayClient.swift): pairing, HMAC-signed requests, WSS events.

import crypto from 'node:crypto'
import https from 'node:https'
import WebSocket from 'ws'
import { canonicalString, sha256hex } from '../auth.mjs'

export class BridgeClient {
  constructor({ baseUrl, deviceId = null, token = null, rejectUnauthorized = false }) {
    this.baseUrl = baseUrl.replace(/\/$/, '')
    this.deviceId = deviceId
    this.token = token
    this.agent = new https.Agent({ rejectUnauthorized })
  }

  async raw(method, path, { headers = {}, body = null } = {}) {
    const response = await fetch(this.baseUrl + path, {
      method,
      headers,
      body,
      dispatcher: undefined,
      // Node fetch does not take an https.Agent; use NODE_TLS_REJECT_UNAUTHORIZED in tests.
    })
    const text = await response.text()
    let json = null
    try { json = JSON.parse(text) } catch { /* leave raw */ }
    return { status: response.status, json, text }
  }

  signHeaders(method, path, rawBody, requestId = '') {
    const timestamp = String(Date.now())
    const nonce = crypto.randomBytes(12).toString('hex')
    const bodySha = sha256hex(rawBody)
    const signature = crypto
      .createHmac('sha256', Buffer.from(sha256hex(this.token), 'hex'))
      .update(canonicalString(this.deviceId, method, path, requestId, timestamp, nonce, bodySha))
      .digest('hex')
    return {
      'x-device-id': this.deviceId,
      'x-request-timestamp': timestamp,
      'x-nonce': nonce,
      'x-body-sha256': bodySha,
      'x-signature': signature,
      ...(requestId ? { 'x-request-id': requestId } : {}),
    }
  }

  async pair(pairingCode, deviceName = 'test-iphone') {
    const body = JSON.stringify({ pairing_code: pairingCode, device_name: deviceName })
    const r = await this.raw('POST', '/v1/pair', {
      headers: { 'content-type': 'application/json' },
      body,
    })
    if (r.status === 201) {
      this.deviceId = r.json.device_id
      this.token = r.json.token
    }
    return r
  }

  async signed(method, path, { requestId = '', json = null, tamper = null } = {}) {
    const rawBody = json !== null ? Buffer.from(JSON.stringify(json)) : Buffer.alloc(0)
    const headers = this.signHeaders(method, path, rawBody, requestId)
    if (tamper) tamper(headers)
    return this.raw(method, path, {
      headers: { ...headers, ...(json !== null ? { 'content-type': 'application/json' } : {}) },
      body: json !== null ? rawBody : null,
    })
  }

  createTurn(requestId, audioBuf, { codec = 'pcm16le_16k', durationMs = 1000, protocolVersion = 1, sha256 = null } = {}) {
    return this.signed('POST', '/v1/voice/turns', {
      requestId,
      json: {
        protocol_version: protocolVersion,
        request_id: requestId,
        audio: {
          codec,
          sample_rate: 16000,
          channels: 1,
          duration_ms: durationMs,
          sha256: sha256 ?? sha256hex(audioBuf),
        },
        audio_base64: audioBuf.toString('base64'),
      },
    })
  }

  getTurn(requestId) { return this.signed('GET', `/v1/voice/turns/${requestId}`) }

  // 结果语音下载（ESS-38）：签名 GET，可带 Range 断点续传；返回原始字节。
  async downloadAudio(requestId, { range = null } = {}) {
    const path = `/v1/voice/turns/${requestId}/audio`
    const headers = this.signHeaders('GET', path, Buffer.alloc(0), requestId)
    if (range) headers.range = range
    const response = await fetch(this.baseUrl + path, { method: 'GET', headers })
    const body = Buffer.from(await response.arrayBuffer())
    return {
      status: response.status,
      body,
      headers: Object.fromEntries(response.headers.entries()),
    }
  }
  cancelTurn(requestId) { return this.signed('POST', `/v1/voice/turns/${requestId}/cancel`, { json: {} }) }
  permission(requestId, permissionId, decision) {
    return this.signed('POST', `/v1/voice/turns/${requestId}/permission`, {
      json: { permission_id: permissionId, decision },
    })
  }

  events() {
    const path = '/v1/voice/events'
    const headers = this.signHeaders('GET', path, Buffer.alloc(0))
    const ws = new WebSocket(this.baseUrl.replace(/^http/, 'ws') + path, {
      headers,
      rejectUnauthorized: false,
    })
    const received = []
    ws.on('message', raw => {
      try { received.push(JSON.parse(raw.toString())) } catch { /* ignore */ }
    })
    return { ws, received }
  }
}

export const waitFor = async (predicate, { timeoutMs = 15_000, intervalMs = 100 } = {}) => {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const value = await predicate()
    if (value) return value
    await new Promise(r => setTimeout(r, intervalMs))
  }
  throw new Error('waitFor timeout')
}
