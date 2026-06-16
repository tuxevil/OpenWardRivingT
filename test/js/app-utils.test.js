// Unit tests for openwrt_files/www/wardriving/app-utils.js.
//
// Run with:  node --test test/js/app-utils.test.js
// or via test/run_js_tests.sh
//
// We use Node's built-in test runner (no jest, no vitest) so the
// project doesn't grow a node_modules tree just for one test file.
// The helpers are pure string/object manipulation, so we don't need
// jsdom or any DOM emulation.

'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

// Set up a fake window before requiring app-utils.js. The module's
// UMD wrapper checks `typeof window !== 'undefined'` and attaches to
// it. In Node we set global.window to a minimal stub; functions that
// read window.API_TOKEN (withApiAuth, apiUrl) close over `root` which
// is this stub.
const fakeWindow = { API_TOKEN: '' };
global.window = fakeWindow;
global.AbortController = global.AbortController || class AbortController {
  constructor() { this.signal = { aborted: false }; }
  abort() { this.signal.aborted = true; }
};

const utils = require('../../openwrt_files/www/wardriving/app-utils.js');

test('esc: null and undefined become empty string', () => {
  assert.equal(utils.esc(null), '');
  assert.equal(utils.esc(undefined), '');
});

test('esc: numbers, booleans and strings pass through', () => {
  assert.equal(utils.esc(42), '42');
  assert.equal(utils.esc(true), 'true');
  assert.equal(utils.esc('hello'), 'hello');
});

test('esc: escapes HTML special chars', () => {
  assert.equal(utils.esc('<script>'), '&lt;script&gt;');
  assert.equal(utils.esc('"quoted"'), '&quot;quoted&quot;');
  assert.equal(utils.esc("it's"), 'it&#39;s');
  assert.equal(utils.esc('a & b'), 'a &amp; b');
  assert.equal(utils.esc('<a href="x">\'y\'</a>'),
               '&lt;a href=&quot;x&quot;&gt;&#39;y&#39;&lt;/a&gt;');
});

test('esc: handles empty string', () => {
  assert.equal(utils.esc(''), '');
});

test('dim: wraps esc output in dim span', () => {
  assert.equal(utils.dim('hello'),
               '<span style="color:var(--c-dim)">hello</span>');
  // dim must also escape; XSS regression.
  assert.equal(utils.dim('<bad>'),
               '<span style="color:var(--c-dim)">&lt;bad&gt;</span>');
});

test('withApiAuth: no token returns options unchanged', () => {
  fakeWindow.API_TOKEN = '';
  const result = utils.withApiAuth({ method: 'POST' });
  assert.equal(result.method, 'POST');
  assert.equal(result.headers, undefined);
});

test('withApiAuth: adds Bearer header when token is set', () => {
  fakeWindow.API_TOKEN = 'secret123';
  const result = utils.withApiAuth({ method: 'GET' });
  assert.equal(result.headers.Authorization, 'Bearer secret123');
});

test('withApiAuth: does not overwrite existing Authorization header', () => {
  fakeWindow.API_TOKEN = 'secret123';
  const result = utils.withApiAuth({ headers: { Authorization: 'Basic xyz' } });
  assert.equal(result.headers.Authorization, 'Basic xyz');
});

test('withApiAuth: tolerates undefined and null options', () => {
  fakeWindow.API_TOKEN = 'tok';
  assert.equal(utils.withApiAuth().headers.Authorization, 'Bearer tok');
  assert.equal(utils.withApiAuth(null).headers.Authorization, 'Bearer tok');
});

test('withApiAuth: does not mutate the caller options', () => {
  fakeWindow.API_TOKEN = 'tok';
  const original = { method: 'GET' };
  utils.withApiAuth(original);
  assert.equal(original.headers, undefined);
});

test('apiUrl: basic action URL with no token', () => {
  fakeWindow.API_TOKEN = '';
  assert.equal(utils.apiUrl('status'),
               '/cgi-bin/wardriving_api?action=status');
});

test('apiUrl: includes token in query string', () => {
  fakeWindow.API_TOKEN = 'abc';
  assert.equal(utils.apiUrl('status'),
               '/cgi-bin/wardriving_api?action=status&token=abc');
});

test('apiUrl: encodes action and params', () => {
  fakeWindow.API_TOKEN = '';
  assert.equal(utils.apiUrl('set mode', { 'a b': 'x&y' }),
               '/cgi-bin/wardriving_api?action=set%20mode&a%20b=x%26y');
});

test('apiUrl: encodes token value', () => {
  fakeWindow.API_TOKEN = 'a/b c';
  const out = utils.apiUrl('status');
  assert.ok(out.includes('token=a%2Fb%20c'),
            'token must be percent-encoded, got: ' + out);
});

test('apiUrl: token comes after params, regardless of key order', () => {
  fakeWindow.API_TOKEN = 't';
  const out = utils.apiUrl('save', { foo: '1', bar: '2' });
  // Token is appended last so CGI's QUERY_STRING parser sees it cleanly.
  assert.ok(out.endsWith('&token=t'), 'token must be last param, got: ' + out);
});
