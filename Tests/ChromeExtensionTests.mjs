import assert from 'node:assert/strict';
import {test} from 'node:test';

function makeEvent() {
  const listeners = [];
  return {
    addListener(listener) { listeners.push(listener); },
    fire(...args) { for (const listener of listeners) listener(...args); },
  };
}

let activeTabId;
let nextTabId = 7;
let activatedDuringCreation = false;
let activateOnScript = false;
let currentTabId;
let getGate;
const tabs = new Map([[1, {id: 1, active: true, status: 'complete', url: 'https://user.example/'}]]);
const removedTabIds = [];
const activated = makeEvent();
const removed = makeEvent();
const installed = makeEvent();
const updated = makeEvent();
let connection;
const noopEvent = makeEvent();
const clicked = makeEvent();
const alarm = makeEvent();
let connectCount = 0;
const groupCalls = [];
const groupUpdateCalls = [];
let groupQueryResult = [];
let groupThrow = false;
let nextGroupId = 100;

globalThis.chrome = {
  runtime: {
    lastError: undefined,
    onInstalled: installed,
    onStartup: noopEvent,
    connectNative() {
      connectCount++;
      connection = {onMessage: makeEvent(), onDisconnect: makeEvent(), postMessage() {}, disconnect() { this.onDisconnect.fire(); }};
      return connection;
    },
  },
  alarms: {create() {}, onAlarm: alarm},
  action: {onClicked: clicked, setBadgeText() {}, setTitle() {}},
  tabs: {
    onActivated: activated,
    onRemoved: removed,
    onUpdated: updated,
    async group({groupId, tabIds, createProperties}) {
      if (groupThrow) throw new Error('group failed');
      groupCalls.push({groupId, tabIds, createProperties});
      if (groupId !== undefined) return groupId;
      return nextGroupId++;
    },
    async create({active: requestedActive, url}) {
      assert.equal(requestedActive, false);
      const tab = {id: nextTabId++, active: false, status: 'complete', url, windowId: 1};
      currentTabId = tab.id;
      tabs.set(tab.id, tab);
      if (activatedDuringCreation) activated.fire({tabId: tab.id});
      return {...tab};
    },
    async get(id) {
      if (getGate) {
        const gate = getGate;
        getGate = undefined;
        gate.started();
        await gate.wait;
      }
      const tab = tabs.get(id);
      if (!tab) throw new Error('No tab with id');
      return {...tab, active: activeTabId === id};
    },
    async update(id, changes) { Object.assign(tabs.get(id), changes); return tabs.get(id); },
    async remove(id) {
      if (!tabs.has(id)) throw new Error('No tab with id');
      removedTabIds.push(id);
      tabs.delete(id);
      if (activeTabId === id) activeTabId = undefined;
      removed.fire(id);
    },
  },
  windows: {async getLastFocused() { return {id: 1, incognito: false}; }},
  tabGroups: {
    async query({windowId, title}) {
      assert.equal(title, 'mac-use');
      return groupQueryResult.filter(g => windowId === undefined || g.windowId === windowId);
    },
    async update(groupId, changes) { groupUpdateCalls.push({groupId, changes}); return {id: groupId, ...changes}; },
  },
  scripting: {async executeScript() {
    if (activateOnScript) activated.fire({tabId: currentTabId});
    return [{result: {url: tabs.get(currentTabId).url, elements: []}}];
  }},
};

const {handleRequest, pageOperation} = await import('../chrome-extension/background.js');

test('browser_act rejects a reused element whose label changes after its snapshot', () => {
  let label = 'Save';
  let isVisible = true;
  let newHandlerCalls = 0;
  const attributes = new Map();
  const button = {
    tagName: 'BUTTON', type: 'button', disabled: false, readOnly: false, value: '', innerText: '', labels: [],
    isConnected: true,
    getAttribute(name) { return name === 'aria-label' ? label : (attributes.get(name) ?? null); },
    click() { newHandlerCalls++; },
  };
  const previous = {
    document: globalThis.document,
    getComputedStyle: globalThis.getComputedStyle,
    location: globalThis.location,
    snapshot: globalThis.__macUseSnapshot,
  };
  try {
    globalThis.document = {
      visibilityState: 'hidden', readyState: 'complete', title: 'test', body: {innerText: ''},
      querySelectorAll() { return [button]; },
    };
    globalThis.getComputedStyle = () => ({visibility: 'visible', display: 'block', opacity: isVisible ? '1' : '0'});
    globalThis.location = {href: 'https://example.test/'};
    button.getBoundingClientRect = () => ({width: 50, height: 20});
    const snapshot = pageOperation('browser_snapshot', {});
    const ref = snapshot.elements[0].ref;
    label = 'Delete';
    assert.throws(() => pageOperation('browser_act', {action: 'click', ref}), /stale_reference/);
    assert.equal(newHandlerCalls, 0);
    label = 'Save';
    const refreshedRef = pageOperation('browser_snapshot', {}).elements[0].ref;
    isVisible = false;
    assert.throws(() => pageOperation('browser_act', {action: 'click', ref: refreshedRef}), /stale_reference/);
    assert.equal(newHandlerCalls, 0);
  } finally {
    for (const [key, value] of Object.entries({
      document: previous.document,
      getComputedStyle: previous.getComputedStyle,
      location: previous.location,
      __macUseSnapshot: previous.snapshot,
    })) {
      if (value === undefined) delete globalThis[key];
      else globalThis[key] = value;
    }
  }
});

test('a newly selected tab cannot be read or mutated during the script race', () => {
  globalThis.document = {visibilityState: 'visible'};
  assert.throws(() => pageOperation('browser_snapshot', {}), /human_activity/);
  assert.throws(() => pageOperation('browser_act', {action: 'click', ref: 'any'}), /human_activity/);
  delete globalThis.document;
});

async function openSession(id) {
  const session = `00000000-0000-0000-0000-${String(id).padStart(12, '0')}`;
  await handleRequest({operation: 'browser_open', session, arguments: {url: 'https://example.com/'}});
  return {session, tabId: currentTabId};
}

test('browser_close removes an owned tab that is still inactive', async () => {
  const {session, tabId} = await openSession(1);
  assert.deepEqual(await handleRequest({operation: 'browser_close', session}), {closed: true, released: true});
  assert.deepEqual(removedTabIds, [tabId]);
  assert.equal(tabs.has(1), true);
});

test('browser_close leaves a tab selected by the user open', async () => {
  const {session, tabId} = await openSession(2);
  activeTabId = tabId;
  activated.fire({tabId});
  assert.deepEqual(await handleRequest({operation: 'browser_close', session}), {closed: false, released: true});
  assert.equal(tabs.has(tabId), true);
  activeTabId = undefined;
});

test('activation during tab creation transfers ownership to the user', async () => {
  activatedDuringCreation = true;
  const {session, tabId} = await openSession(3);
  activatedDuringCreation = false;
  assert.deepEqual(await handleRequest({operation: 'browser_close', session}), {closed: false, released: true});
  assert.equal(tabs.has(tabId), true);
});

test('selection during the activity lookup preserves the tab after it becomes inactive', async () => {
  const {session, tabId} = await openSession(8);
  let startLookup;
  let finishLookup;
  const lookupStarted = new Promise(resolve => { startLookup = resolve; });
  const lookupGate = new Promise(resolve => { finishLookup = resolve; });
  getGate = {started: startLookup, wait: lookupGate};
  const closing = handleRequest({operation: 'browser_close', session});
  await lookupStarted;
  activeTabId = tabId;
  activated.fire({tabId});
  activeTabId = undefined;
  finishLookup();
  assert.deepEqual(await closing, {closed: false, released: true});
  assert.equal(tabs.has(tabId), true);
});

test('browser_close releases a session if its tab was already removed', async () => {
  const {session, tabId} = await openSession(4);
  await chrome.tabs.remove(tabId);
  assert.deepEqual(await handleRequest({operation: 'browser_close', session}), {closed: false, released: false});
  assert.equal(removedTabIds.filter(id => id === tabId).length, 1);
});

test('disconnect best-effort closes owned inactive tabs and leaves selected tabs open', async () => {
  const unattended = await openSession(5);
  const selected = await openSession(6);
  activeTabId = selected.tabId;
  activated.fire({tabId: selected.tabId});
  installed.fire();
  connection.onDisconnect.fire();
  await new Promise(resolve => setTimeout(resolve, 0));
  assert.equal(tabs.has(unattended.tabId), false);
  assert.equal(tabs.has(selected.tabId), true);
  activeTabId = undefined;
});

test('activation while a snapshot is in flight prevents the result from being returned', async () => {
  const {session} = await openSession(7);
  activateOnScript = true;
  await assert.rejects(handleRequest({operation: 'browser_snapshot', session}), /human_activity/);
  activateOnScript = false;
  await handleRequest({operation: 'browser_close', session});
});

test('browser_open groups tabs in a collapsed mac-use group', async () => {
  groupQueryResult = [];
  groupCalls.length = 0;
  groupUpdateCalls.length = 0;
  const first = await openSession(11);
  assert.equal(groupUpdateCalls.length, 1);
  assert.deepEqual(groupUpdateCalls[0].changes, {title: 'mac-use', color: 'grey', collapsed: true});
  const groupId = groupUpdateCalls[0].groupId;
  groupQueryResult = [{id: groupId, windowId: 1, title: 'mac-use'}];
  const collapsedUpdates = groupUpdateCalls.length;
  const second = await openSession(12);
  assert.equal(groupCalls[groupCalls.length - 1].groupId, groupId);
  assert.deepEqual(groupCalls[groupCalls.length - 1].tabIds, [second.tabId]);
  assert.equal(groupUpdateCalls.length, collapsedUpdates);
  await handleRequest({operation: 'browser_close', session: first.session});
  await handleRequest({operation: 'browser_close', session: second.session});
  groupQueryResult = [];
});

test('moving a tab out of the group transfers ownership to the user', async () => {
  groupQueryResult = [];
  const {session, tabId} = await openSession(13);
  updated.fire(tabId, {groupId: -1});
  await assert.rejects(handleRequest({operation: 'browser_snapshot', session}), /human_activity/);
  await handleRequest({operation: 'browser_close', session});
  groupQueryResult = [];
});

test('grouping failure still lets browser_open succeed', async () => {
  groupThrow = true;
  const {session} = await openSession(14);
  groupThrow = false;
  await handleRequest({operation: 'browser_snapshot', session});
  await handleRequest({operation: 'browser_close', session});
});

test('alarm reconnects after a drop and clicking while connected keeps the connection', () => {
  connection.onDisconnect.fire();
  const dropped = connection;
  const before = connectCount;
  alarm.fire({name: 'other'});
  assert.equal(connectCount, before);
  alarm.fire({name: 'keep-connected'});
  assert.equal(connectCount, before + 1);
  assert.notEqual(connection, dropped);
  let disconnects = 0;
  connection.disconnect = () => { disconnects++; };
  clicked.fire();
  alarm.fire({name: 'keep-connected'});
  assert.equal(disconnects, 0);
  assert.equal(connectCount, before + 1);
});
