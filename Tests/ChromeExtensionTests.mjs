import assert from 'node:assert/strict';
import {test} from 'node:test';

let active = false;
let removed = false;
let created = 0;
let activated;
let activateOnScript = false;
let activateDuringCreation = false;
const tab = {id: 7, active: false, status: 'complete', url: 'https://example.com/'};
const noop = {addListener() {}};
globalThis.chrome = {
  runtime: {connectNative() { throw new Error('no real Chrome'); }, onInstalled: noop, onStartup: noop},
  action: {onClicked: noop, setBadgeText() {}, setTitle() {}},
  tabs: {
    onActivated: {addListener(listener) { activated = listener; }}, onRemoved: noop,
    async create({active: requestedActive, url}) {
      assert.equal(requestedActive, false);
      created++; tab.url = url;
      if (activateDuringCreation) activated({tabId: tab.id});
      return {...tab};
    },
    async get() { return {...tab, active}; },
    async update(id, changes) { if (changes.url) tab.url = changes.url; return tab; },
    async remove() { removed = true; },
  },
  windows: {async getLastFocused() { return {id: 1, incognito: false}; }},
  scripting: {async executeScript() {
    if (activateOnScript) activated({tabId: tab.id});
    return [{result: {url: tab.url, elements: []}}];
  }},
};
const {handleRequest, pageOperation} = await import('../chrome-extension/background.js');
test('a newly selected tab cannot be read or mutated during the script race', () => {
  globalThis.document = {visibilityState: 'visible'};
  assert.throws(() => pageOperation('browser_snapshot', {}), /human_activity/);
  assert.throws(() => pageOperation('browser_act', {action: 'click', ref: 'any'}), /human_activity/);
  delete globalThis.document;
});
const session = '00000000-0000-0000-0000-000000000001';

test('only an owned inactive HTTP tab can be opened, observed, and closed', async () => {
  assert.equal((await handleRequest({operation: 'browser_status', session})).connected, true);
  await assert.rejects(handleRequest({operation: 'browser_open', session, arguments: {url: 'file:///private'}}), /Only HTTP/);
  await handleRequest({operation: 'browser_open', session, arguments: {url: 'https://example.com/'}});
  assert.equal(created, 1);
  assert.equal((await handleRequest({operation: 'browser_snapshot', session})).url, 'https://example.com/');
  await assert.rejects(handleRequest({operation: 'browser_open', session, arguments: {url: 'https://other.example/'}}), /Release/);
  assert.equal(created, 1);
  active = true;
  activated({tabId: tab.id});
  await assert.rejects(handleRequest({operation: 'browser_act', session, arguments: {action: 'click', ref: 'any'}}), /human_activity/);
  active = false;
  await assert.rejects(handleRequest({operation: 'browser_act', session, arguments: {action: 'click', ref: 'any'}}), /human_activity/);
  await assert.rejects(handleRequest({operation: 'browser_snapshot', session}), /human_activity/);
  assert.equal((await handleRequest({operation: 'browser_close', session})).closed, false);
  assert.equal(removed, false);
  assert.equal((await handleRequest({operation: 'browser_status', session})).hasTab, false);
});

test('activation before create resolves permanently transfers the new tab to the user', async () => {
  activateDuringCreation = true;
  const second = '00000000-0000-0000-0000-000000000002';
  await handleRequest({operation: 'browser_open', session: second, arguments: {url: 'https://example.com/'}});
  activateDuringCreation = false;
  await assert.rejects(handleRequest({operation: 'browser_snapshot', session: second}), /human_activity/);
  await handleRequest({operation: 'browser_close', session: second});
  assert.equal(removed, false);
});

test('activation while a snapshot is in flight prevents the result from being returned', async () => {
  const third = '00000000-0000-0000-0000-000000000003';
  await handleRequest({operation: 'browser_open', session: third, arguments: {url: 'https://example.com/'}});
  activateOnScript = true;
  await assert.rejects(handleRequest({operation: 'browser_snapshot', session: third}), /human_activity/);
  activateOnScript = false;
  await handleRequest({operation: 'browser_close', session: third});
});


test('browser_close releases the session without closing the Chrome tab', async () => {
  const fourth = '00000000-0000-0000-0000-000000000004';
  await handleRequest({operation: 'browser_open', session: fourth, arguments: {url: 'https://example.com/'}});
  const result = await handleRequest({operation: 'browser_close', session: fourth});
  assert.deepEqual(result, {closed: false, released: true});
  assert.equal(removed, false);
});
