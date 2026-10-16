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
const debuggerCalls = [];
const debuggerEvent = makeEvent();
const debuggerDetached = makeEvent();
let dialogOnClick = false;
const attachedTabs = new Set();

globalThis.chrome = {
  debugger: {
    onEvent: debuggerEvent, onDetach: debuggerDetached,
    async attach(source, version) { assert.equal(version, '1.3'); attachedTabs.add(source.tabId); },
    async detach(source) { attachedTabs.delete(source.tabId); debuggerDetached.fire(source); },
    async sendCommand(source, method, params) {
      debuggerCalls.push({tabId: source.tabId, method, params});
      if (method === 'Runtime.enable') debuggerEvent.fire(source, 'Runtime.executionContextCreated', {context: {id: 3, origin: 'chrome-extension://test-extension'}});
      if (dialogOnClick && method === 'Input.dispatchMouseEvent' && params.type === 'mouseReleased') {
        debuggerEvent.fire(source, 'Page.javascriptDialogOpening', {type: 'prompt', message: 'Name?', defaultPrompt: ''});
      }
      if (method === 'Page.handleJavaScriptDialog') debuggerEvent.fire(source, 'Page.javascriptDialogClosed', {});
      if (method === 'Page.getFrameTree') return {frameTree: {frame: {id: 'frame'}}};
      if (method === 'Page.createIsolatedWorld') return {executionContextId: 3};
      if (method === 'Runtime.evaluate') {
        if (params.expression.startsWith('(function pageOperation')) return {result: {value: {url: tabs.get(source.tabId).url, elements: []}}};
        if (params.expression.startsWith('(function settlePoll')) return {result: {value: {pending: 0, idle: 1000}}};
        return {result: {objectId: 'file-object', value: 42}};
      }
      if (method === 'DOM.describeNode') return {node: {nodeName: 'INPUT', attributes: ['type', 'file'], backendNodeId: 19}};
      return {};
    },
  },
  downloads: {
    async download(options) { assert.ok(!options.filename.startsWith('/')); return 21; },
    async search({id}) { return [{id, state: 'complete', filename: '/tmp/Downloads/mac-use/test'}]; },
  },
  runtime: {
    id: 'test-extension',
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
  scripting: {async executeScript({func, args = []}) {
    if (func.name === 'pageQuery') return [{result: args[0].action === 'get_text' ? 'page text' : [{tag: 'a', attributes: {href: '/next'}}]}];
    if (func.name === 'resolveTarget') return [{result: {x: args[0].x ?? 10, y: args[0].y ?? 20, href: 'https://example.com/file'}}];
    if (activateOnScript) activated.fire({tabId: currentTabId});
    return [{result: {url: tabs.get(currentTabId).url, elements: []}}];
  }},
};

const {handleRequest, pageOperation, resolveTarget, settleBegin, settlePoll, settle} = await import('../chrome-extension/background.js');

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

function withPage(elements, {top = () => undefined, innerHeight = 800} = {}, run) {
  const previous = {document: globalThis.document, getComputedStyle: globalThis.getComputedStyle, location: globalThis.location,
    snapshot: globalThis.__macUseSnapshot, innerHeight: globalThis.innerHeight, innerWidth: globalThis.innerWidth,
    HTMLSelectElement: globalThis.HTMLSelectElement};
  try {
    globalThis.document = {
      visibilityState: 'hidden', readyState: 'complete', title: 'test', body: {innerText: ''},
      querySelectorAll() { return elements; },
      elementFromPoint(x, y) { return top(x, y); },
    };
    globalThis.getComputedStyle = () => ({visibility: 'visible', display: 'block', opacity: '1'});
    globalThis.location = {href: 'https://example.test/'};
    globalThis.innerHeight = innerHeight;
    globalThis.innerWidth = 1000;
    return run();
  } finally {
    for (const [key, value] of Object.entries({document: previous.document, getComputedStyle: previous.getComputedStyle,
      location: previous.location, __macUseSnapshot: previous.snapshot, innerHeight: previous.innerHeight,
      innerWidth: previous.innerWidth, HTMLSelectElement: previous.HTMLSelectElement})) {
      if (value === undefined) delete globalThis[key];
      else globalThis[key] = value;
    }
  }
}

function fakeElement(tagName, extra = {}) {
  const attributes = new Map(Object.entries(extra.attributes ?? {}));
  const element = {
    tagName, type: '', disabled: false, readOnly: false, value: '', innerText: '', labels: [], isConnected: true,
    getAttribute(name) { return attributes.get(name) ?? null; },
    hasAttribute(name) { return attributes.has(name); },
    contains(other) { return other === this; },
    getBoundingClientRect: () => ({left: 10, top: 10, right: 110, bottom: 30, width: 100, height: 20}),
    getRootNode() { return {}; },
    focus() {},
    dispatchEvent(event) { (this.events ??= []).push(event.type); },
    ...extra,
  };
  delete element.attributes;
  return element;
}

function fakeSelect(optionList, selectedIndex = 0) {
  const select = fakeElement('SELECT');
  select.options = optionList.map(([value, text, disabled = false], index) => ({value, text, disabled, index}));
  select.selectedIndex = selectedIndex;
  Object.defineProperty(select, 'value', {get() { return this.options[this.selectedIndex]?.value ?? ''; }, configurable: true});
  return select;
}

test('snapshot lists select options capped at 50 with the selected value', () => {
  const select = fakeSelect(Array.from({length: 60}, (_, i) => [`v${i}`, ` Option ${i} `]), 2);
  withPage([select], {}, () => {
    const [item] = pageOperation('browser_snapshot', {}).elements;
    assert.equal(item.options.length, 50);
    assert.deepEqual(item.options[1], {value: 'v1', text: 'Option 1'});
    assert.equal(item.selected, 'v2');
  });
});

test('snapshot marks covered elements and acting on them fails', () => {
  let clicks = 0;
  const button = fakeElement('BUTTON', {click() { clicks++; }});
  const overlay = fakeElement('DIV');
  let covering = overlay;
  withPage([button], {top: () => covering}, () => {
    const [item] = pageOperation('browser_snapshot', {}).elements;
    assert.equal(item.covered, true);
    assert.throws(() => pageOperation('browser_act', {action: 'click', ref: item.ref}), /element is covered/);
    assert.equal(clicks, 0);
    covering = button;
    const [free] = pageOperation('browser_snapshot', {}).elements;
    assert.equal(free.covered, undefined);
    pageOperation('browser_act', {action: 'click', ref: free.ref});
    assert.equal(clicks, 1);
  });
});

test('snapshot keeps off-screen live regions and flags them', () => {
  const offscreen = {left: 0, top: 5000, right: 100, bottom: 5020, width: 100, height: 20};
  const status = fakeElement('DIV', {attributes: {role: 'status'}, getBoundingClientRect: () => offscreen});
  const polite = fakeElement('SPAN', {attributes: {'aria-live': 'polite'}, getBoundingClientRect: () => offscreen});
  const alert = fakeElement('DIV', {attributes: {role: 'alert'}});
  withPage([status, polite, alert], {}, () => {
    const items = pageOperation('browser_snapshot', {}).elements;
    assert.equal(items.length, 3);
    assert.equal(items[0].offscreen, true);
    assert.equal(items[1].offscreen, true);
    assert.equal(items[2].offscreen, undefined);
  });
});

test('fill on a select picks an option by value or text and dispatches input and change', () => {
  const select = fakeSelect([['a', 'Alpha'], ['b', 'Beta'], ['c', 'Gamma', true]]);
  withPage([select], {}, () => {
    let ref = pageOperation('browser_snapshot', {}).elements[0].ref;
    pageOperation('browser_act', {action: 'fill', ref, text: 'b'});
    assert.equal(select.value, 'b');
    assert.deepEqual(select.events, ['input', 'change']);
    ref = pageOperation('browser_snapshot', {}).elements[0].ref;
    pageOperation('browser_act', {action: 'fill', ref, text: 'Alpha'});
    assert.equal(select.value, 'a');
  });
});

test('fill on a select fails without changing it when no option matches', () => {
  const select = fakeSelect([['a', 'Alpha'], ['c', 'Gamma', true]]);
  withPage([select], {}, () => {
    for (const text of ['missing', 'c']) {
      const ref = pageOperation('browser_snapshot', {}).elements[0].ref;
      assert.throws(() => pageOperation('browser_act', {action: 'fill', ref, text}), /No enabled option matches/);
    }
    assert.equal(select.value, 'a');
    assert.equal(select.events, undefined);
  });
});

test('settle counters ignore requests open before the action and track new ones', async () => {
  const previous = {fetch: globalThis.fetch, XMLHttpRequest: globalThis.XMLHttpRequest, MutationObserver: globalThis.MutationObserver,
    document: globalThis.document, net: globalThis.__macUseNet};
  const resolvers = [];
  globalThis.fetch = () => new Promise(resolve => resolvers.push(resolve));
  globalThis.XMLHttpRequest = class { send() {} addEventListener() {} };
  globalThis.MutationObserver = class { observe() {} disconnect() {} };
  globalThis.document = {};
  delete globalThis.__macUseNet;
  try {
    settleBegin();
    const wrapped = globalThis.fetch;
    globalThis.fetch();
    assert.equal(settlePoll().pending, 1);
    settleBegin();
    assert.equal(globalThis.fetch, wrapped, 'wrapper installs once');
    assert.equal(settlePoll().pending, 0, 'older request ignored after a new marker');
    globalThis.fetch();
    assert.equal(settlePoll().pending, 1);
    resolvers[1]();
    await new Promise(resolve => setTimeout(resolve, 0));
    assert.equal(settlePoll().pending, 0);
  } finally {
    for (const [key, value] of Object.entries({fetch: previous.fetch, XMLHttpRequest: previous.XMLHttpRequest,
      MutationObserver: previous.MutationObserver, document: previous.document, __macUseNet: previous.net})) {
      if (value === undefined) delete globalThis[key];
      else globalThis[key] = value;
    }
  }
});

test('browser_act reports settle_ms and settled; settle caps when requests stay pending', async () => {
  const {session} = await openSession(21);
  const result = await handleRequest({operation: 'browser_act', session, arguments: {action: 'scroll'}});
  assert.equal(result.settled, true);
  assert.equal(typeof result.settle_ms, 'number');
  const original = chrome.scripting.executeScript;
  chrome.scripting.executeScript = async ({world}) => [{result: world === 'MAIN' ? {pending: 1, idle: 0} : {url: 'https://example.com/', elements: []}}];
  try {
    const capped = await settle(session, {pollMs: 5, quietMs: 150, idleCapMs: 2000, pendingCapMs: 40});
    assert.equal(capped.settled, false);
    assert.ok(capped.settle_ms >= 40);
  } finally {
    chrome.scripting.executeScript = original;
  }
  await handleRequest({operation: 'browser_close', session});
});

test('settle stops when the user selects the tab', async () => {
  const {session, tabId} = await openSession(22);
  activeTabId = tabId;
  activated.fire({tabId});
  await assert.rejects(settle(session), /human_activity/);
  activeTabId = undefined;
  await handleRequest({operation: 'browser_close', session});
});


test('navigate refuses unsafe schemes and returns fresh page for allowed navigation', async () => {
  const {session, tabId} = await openSession(101);
  for (const url of ['javascript:alert(1)', 'file:///tmp/a', 'data:text/html,hi', 'chrome://settings']) {
    await assert.rejects(handleRequest({operation: 'browser_navigate', session, arguments: {url}}), /Only HTTP, HTTPS and about/);
  }
  for (const url of ['https://example.com/new', 'http://example.com/', 'about:blank']) {
    const result = await handleRequest({operation: 'browser_navigate', session, arguments: {url}});
    assert.equal(tabs.get(tabId).url, url);
    assert.equal(result.url, url);
  }
  await handleRequest({operation: 'browser_close', session});
});

test('trusted click and typing dispatch debugger input and detach after calls', async () => {
  const {session, tabId} = await openSession(102);
  debuggerCalls.length = 0;
  await handleRequest({operation: 'browser_click', session, arguments: {x: 31, y: 42, button: 'right', click_count: 2}});
  assert.deepEqual(debuggerCalls.filter(c => c.method === 'Input.dispatchMouseEvent').map(c => c.params), [
    {type: 'mousePressed', x: 31, y: 42, button: 'right', clickCount: 1},
    {type: 'mouseReleased', x: 31, y: 42, button: 'right', clickCount: 1},
    {type: 'mousePressed', x: 31, y: 42, button: 'right', clickCount: 2},
    {type: 'mouseReleased', x: 31, y: 42, button: 'right', clickCount: 2},
  ]);
  assert.equal(attachedTabs.has(tabId), false);
  await assert.rejects(handleRequest({operation: 'browser_click', session, arguments: {x: 1, y: 2, button: 'bad'}}), /Invalid button/);
  await handleRequest({operation: 'browser_type', session, arguments: {ref: 'ref', text: 'hello', mode: 'insert_text'}});
  assert.deepEqual(debuggerCalls.find(c => c.method === 'Input.insertText').params, {text: 'hello'});
  debuggerCalls.length = 0;
  await handleRequest({operation: 'browser_type', session, arguments: {text: 'a😀', mode: 'keystrokes'}});
  assert.deepEqual(debuggerCalls.filter(c => c.method === 'Input.dispatchKeyEvent').map(c => c.params), [
    {type: 'keyDown', key: 'a', text: 'a'}, {type: 'keyUp', key: 'a'},
    {type: 'keyDown', key: '😀', text: '😀'}, {type: 'keyUp', key: '😀'},
  ]);
  assert.equal(attachedTabs.has(tabId), false);
  await handleRequest({operation: 'browser_close', session});
});

test('dialog listener retains debugger until accept or dismiss', async () => {
  const {session, tabId} = await openSession(103);
  for (const action of ['accept', 'dismiss']) {
    dialogOnClick = true;
    const clicked = await handleRequest({operation: 'browser_click', session, arguments: {x: 10, y: 20}});
    dialogOnClick = false;
    assert.equal(clicked.dialog.type, 'prompt');
    assert.equal(attachedTabs.has(tabId), true);
    const inspected = await handleRequest({operation: 'browser_dialog', session, arguments: {action: 'inspect'}});
    assert.equal(inspected.dialog.message, 'Name?');
    await handleRequest({operation: 'browser_dialog', session, arguments: {action, prompt_text: 'Ada'}});
    assert.deepEqual(debuggerCalls.filter(c => c.method === 'Page.handleJavaScriptDialog').at(-1).params, {accept: action === 'accept', promptText: 'Ada'});
    assert.equal(attachedTabs.has(tabId), false);
  }
  await handleRequest({operation: 'browser_close', session});
});

test('all new operations refuse a user-selected owned tab before dispatch', async () => {
  const {session, tabId} = await openSession(104);
  activeTabId = tabId;
  debuggerCalls.length = 0;
  for (const operation of ['browser_navigate', 'browser_click', 'browser_type', 'browser_pointer', 'browser_dialog', 'browser_set_input_files', 'browser_download', 'page']) {
    await assert.rejects(handleRequest({operation, session, arguments: {}}), /human_activity/);
  }
  assert.equal(debuggerCalls.length, 0);
  await handleRequest({operation: 'browser_close', session});
  activeTabId = undefined;
});

test('file input uses isolated ref object and backend node id; invalid paths refused', async () => {
  const {session} = await openSession(105);
  await assert.rejects(handleRequest({operation: 'browser_set_input_files', session, arguments: {ref: 'ref', paths: ['relative']}}), /absolute paths/);
  await handleRequest({operation: 'browser_set_input_files', session, arguments: {ref: 'ref', paths: ['/tmp/file.txt']}});
  assert.deepEqual(debuggerCalls.filter(c => c.method === 'DOM.setFileInputFiles').at(-1).params, {backendNodeId: 19, files: ['/tmp/file.txt']});
  await handleRequest({operation: 'browser_close', session});
});


test('pointer dispatch supports hover, wheel and drag destination', async () => {
  const {session} = await openSession(106);
  debuggerCalls.length = 0;
  for (const action of ['hover', 'right_click', 'double_click', 'scroll', 'drag']) {
    await handleRequest({operation: 'browser_pointer', session, arguments: {action, x: 1, y: 2, to_x: 30, to_y: 40, delta_x: 3, delta_y: -4}});
  }
  const events = debuggerCalls.filter(c => c.method === 'Input.dispatchMouseEvent').map(c => c.params);
  assert.ok(events.some(p => p.type === 'mouseMoved' && p.x === 1 && p.y === 2));
  assert.ok(events.some(p => p.type === 'mouseWheel' && p.deltaX === 3 && p.deltaY === -4));
  assert.ok(events.some(p => p.type === 'mouseMoved' && p.x === 30 && p.y === 40 && p.buttons === 1));
  await assert.rejects(handleRequest({operation: 'browser_pointer', session, arguments: {action: 'unknown'}}), /Unsupported pointer/);
  await handleRequest({operation: 'browser_close', session});
});

test('page reads DOM, executes JavaScript, clicks and types with selectors', async () => {
  const {session} = await openSession(107);
  assert.equal((await handleRequest({operation: 'page', session, arguments: {action: 'get_text'}})).result, 'page text');
  const query = await handleRequest({operation: 'page', session, arguments: {action: 'query_dom', css_selector: 'a', attributes: ['href']}});
  assert.deepEqual(query.result, [{tag: 'a', attributes: {href: '/next'}}]);
  assert.equal((await handleRequest({operation: 'page', session, arguments: {action: 'execute_javascript', javascript: '6 * 7'}})).result, 42);
  for (const action of ['click_element', 'insert_text', 'type_keystrokes']) {
    const result = await handleRequest({operation: 'page', session, arguments: {action, selector: '#field', text: 'a'}});
    assert.ok(Array.isArray(result.elements));
  }
  await handleRequest({operation: 'browser_close', session});
});

test('download uses relative Chrome filename and reports completed absolute source', async () => {
  const {session} = await openSession(108);
  const result = await handleRequest({operation: 'browser_download', session, arguments: {ref: 'ref', directory: '/tmp'}});
  assert.equal(result.download_path, '/tmp/Downloads/mac-use/test');
  assert.ok(Array.isArray(result.elements));
  await handleRequest({operation: 'browser_close', session});
});


test('trusted input ref resolution refuses changed elements and coordinates outside viewport', () => {
  const button = fakeElement('BUTTON', {innerText: 'Original', scrollIntoView() {}});
  withPage([button], {}, () => {
    const {ref} = pageOperation('browser_snapshot', {}).elements[0];
    assert.deepEqual(resolveTarget({ref}), {x: 60, y: 20, href: undefined});
    button.innerText = 'Changed';
    assert.throws(() => resolveTarget({ref}), /stale_reference/);
    for (const args of [{x: -1, y: 0}, {x: 1000, y: 0}, {x: 0, y: Infinity}, {}]) {
      assert.throws(() => resolveTarget(args), /finite viewport/);
    }
  });
});
