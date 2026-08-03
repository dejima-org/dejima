'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
require('../src/protocol.js');
const { endpoints } = globalThis.DEJIMA.protocol;

test('endpoints are relative to the page, so --base-path just works', () => {
  assert.deepEqual(
    endpoints({ protocol: 'https:', host: 'example.test', pathname: '/', search: '' }),
    { token: '/token', ws: 'wss://example.test/ws' }
  );
  assert.deepEqual(
    endpoints({ protocol: 'https:', host: 'example.test', pathname: '/dejima/', search: '' }),
    { token: '/dejima/token', ws: 'wss://example.test/dejima/ws' }
  );
});

test('an index.html in the path is stripped rather than treated as a directory', () => {
  assert.deepEqual(
    endpoints({ protocol: 'https:', host: 'h', pathname: '/dejima/index.html', search: '' }),
    { token: '/dejima/token', ws: 'wss://h/dejima/ws' }
  );
});

test('plain http gets ws:, not wss:', () => {
  assert.equal(
    endpoints({ protocol: 'http:', host: '127.0.0.1:7681', pathname: '/', search: '' }).ws,
    'ws://127.0.0.1:7681/ws'
  );
});

test("the query string rides along, because ttyd's --url-arg reads it off the WebSocket", () => {
  assert.equal(
    endpoints({
      protocol: 'https:',
      host: 'h',
      pathname: '/',
      search: '?arg=0123456789abcdef'
    }).ws,
    'wss://h/ws?arg=0123456789abcdef'
  );
  assert.equal(
    endpoints({ protocol: 'https:', host: 'h', pathname: '/', search: undefined }).ws,
    'wss://h/ws'
  );
});
