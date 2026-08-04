// ESS-175: source gate must accept LAN exact IPs and IPv4 CIDR entries in
// allowed_peer_ips, while preserving loopback and the existing Tailscale
// CGNAT peers that used to depend on the CGNAT-range special case.

import { describe, it } from 'node:test'
import assert from 'node:assert/strict'

import { makeSourceGate, parseCidr, parseIPv4 } from '../auth.mjs'

describe('parseIPv4', () => {
  it('accepts canonical dotted-quad addresses', () => {
    assert.equal(parseIPv4('0.0.0.0'), 0)
    assert.equal(parseIPv4('127.0.0.1'), 0x7f000001)
    assert.equal(parseIPv4('192.168.1.42'), 0xc0a8012a)
    assert.equal(parseIPv4('255.255.255.255'), 0xffffffff)
  })
  it('rejects malformed input', () => {
    for (const bad of ['', '1.2.3', '1.2.3.4.5', '256.0.0.0', '192.168.1.', 'foo', '::1', null, 42]) {
      assert.equal(parseIPv4(bad), null, `expected null for ${JSON.stringify(bad)}`)
    }
  })
})

describe('parseCidr', () => {
  it('parses canonical CIDR blocks', () => {
    assert.deepEqual(parseCidr('0.0.0.0/0'), { base: 0, mask: 0, bits: 0 })
    assert.deepEqual(parseCidr('192.168.0.0/16'), { base: 0xc0a80000, mask: 0xffff0000, bits: 16 })
    assert.deepEqual(parseCidr('100.64.0.0/10'), { base: 0x64400000, mask: 0xffc00000, bits: 10 })
    assert.deepEqual(parseCidr('10.0.0.5/32'), { base: 0x0a000005, mask: 0xffffffff, bits: 32 })
  })
  it('rejects non-canonical or malformed CIDRs', () => {
    // host bits set: caller almost certainly meant .0/24, not .5/24
    assert.equal(parseCidr('192.168.1.5/24'), null)
    for (const bad of ['192.168.1.0/33', '192.168.1.0/-1', '192.168.1.0/', '192.168.1.0/abc', '256.0.0.0/8', '192.168.1.0']) {
      assert.equal(parseCidr(bad), null, `expected null for ${JSON.stringify(bad)}`)
    }
  })
})

describe('makeSourceGate — loopback and regressions', () => {
  it('accepts loopback even when the list is empty', () => {
    const allow = makeSourceGate([])
    assert.equal(allow('127.0.0.1'), true)
    assert.equal(allow('::1'), true)
    assert.equal(allow('192.168.1.10'), false)
  })
  it('preserves existing Tailscale CGNAT peers via exact IP match', () => {
    const allow = makeSourceGate(['100.80.229.218', '100.80.125.22'])
    assert.equal(allow('100.80.229.218'), true)
    assert.equal(allow('100.80.125.22'), true)
    assert.equal(allow('100.80.229.219'), false) // adjacent CGNAT IP not listed
    assert.equal(allow('127.0.0.1'), true)
  })
})

describe('makeSourceGate — LAN exact IPs', () => {
  it('allows LAN peers listed by exact IP and denies anyone else in the same subnet', () => {
    const allow = makeSourceGate(['192.168.1.42'])
    assert.equal(allow('192.168.1.42'), true)
    assert.equal(allow('192.168.1.43'), false)
    assert.equal(allow('192.168.2.42'), false)
    assert.equal(allow('10.0.0.1'), false)
  })
})

describe('makeSourceGate — LAN CIDR', () => {
  it('accepts every host inside a listed IPv4 CIDR', () => {
    const allow = makeSourceGate(['192.168.1.0/24'])
    assert.equal(allow('192.168.1.0'), true)   // network base
    assert.equal(allow('192.168.1.1'), true)
    assert.equal(allow('192.168.1.42'), true)
    assert.equal(allow('192.168.1.255'), true) // broadcast — still matches the mask
    assert.equal(allow('192.168.2.1'), false)  // adjacent /24 is not covered
    assert.equal(allow('192.167.1.42'), false)
  })
  it('handles wider CIDRs and mixes with exact IPs and CGNAT peers', () => {
    const allow = makeSourceGate(['192.168.0.0/16', '10.0.0.5', '100.80.229.218'])
    assert.equal(allow('192.168.0.1'), true)
    assert.equal(allow('192.168.250.99'), true)
    assert.equal(allow('192.169.0.1'), false)
    assert.equal(allow('10.0.0.5'), true)
    assert.equal(allow('10.0.0.6'), false)
    assert.equal(allow('100.80.229.218'), true)
    assert.equal(allow('100.80.229.219'), false)
    assert.equal(allow('127.0.0.1'), true)
  })
  it('supports /32 host CIDRs as an equivalent to an exact IP', () => {
    const allow = makeSourceGate(['192.168.5.10/32'])
    assert.equal(allow('192.168.5.10'), true)
    assert.equal(allow('192.168.5.11'), false)
  })
})

describe('makeSourceGate — default deny and boot-time validation', () => {
  it('denies anything not on the list, including CGNAT IPs that used to slip through', () => {
    const allow = makeSourceGate(['192.168.10.0/24'])
    assert.equal(allow('100.80.229.218'), false, 'CGNAT no longer implicitly allowed')
    assert.equal(allow('8.8.8.8'), false)
    assert.equal(allow('192.168.11.1'), false)
    assert.equal(allow(''), false)
  })
  it('rejects malformed IP entries at construction time', () => {
    assert.throws(() => makeSourceGate(['not-an-ip']), /invalid IP/)
    assert.throws(() => makeSourceGate(['999.0.0.1']), /invalid IP/)
    assert.throws(() => makeSourceGate(['']), /invalid allowed_peer_ips entry/)
    assert.throws(() => makeSourceGate([null]), /invalid allowed_peer_ips entry/)
  })
  it('rejects malformed CIDR entries at construction time', () => {
    assert.throws(() => makeSourceGate(['192.168.1.0/33']), /invalid CIDR/)
    assert.throws(() => makeSourceGate(['192.168.1.5/24']), /invalid CIDR/) // host bits set
    assert.throws(() => makeSourceGate(['foo/24']), /invalid CIDR/)
  })
})
