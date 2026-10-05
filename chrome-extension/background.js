const hostName = 'io.macuse.computer_use';
const sessions = new Map();
let creatingTab = false;
const activatedDuringCreation = new Set();
let port;
let requests = Promise.resolve();

// Runs in this extension's isolated world, without changing page attributes
// or exposing references to page scripts. Every action checks visibility again
// inside the tab to close the race with the background service worker.
export function pageOperation(operation, args) {
  const elementVisible = element => {
    const rect = element.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) return false;
    for (let current = element; current; current = current.parentElement) {
      const style = getComputedStyle(current);
      if (style.visibility === 'hidden' || style.display === 'none' || Number(style.opacity) === 0) return false;
    }
    return true;
  };
  const elementCovered = element => {
    const rect = element.getBoundingClientRect();
    const top = document.elementFromPoint?.(rect.left + rect.width / 2, rect.top + rect.height / 2);
    if (!top || top === element || element.contains(top)) return false;
    // A shadow host is how elementFromPoint reports its own shadow content.
    return element.getRootNode?.().host !== top;
  };
  const liveRegion = element => ['status', 'alert'].includes(element.getAttribute('role')) || element.getAttribute('aria-live') !== null;
  const elementSignature = element => ({
    role: element.getAttribute('role') || element.tagName.toLowerCase(),
    name: (element.getAttribute('aria-label') || element.labels?.[0]?.innerText || element.innerText || element.getAttribute('name') || '').trim().slice(0, 500),
    type: element.type || '',
    disabled: Boolean(element.disabled || element.getAttribute('aria-disabled') === 'true'),
    readOnly: Boolean(element.readOnly),
    href: element.getAttribute('href') || '',
    value: element.type === 'password' ? '' : String(element.value ?? '').slice(0, 1000)
  });
  if (document.visibilityState !== 'hidden') {
    throw new Error('human_activity: the tab is visible; select another tab before continuing.');
  }
  if (operation === 'browser_act') {
    const snapshot = globalThis.__macUseSnapshot;
    const entry = snapshot?.get(args.ref);
    const element = entry?.element;
    if (args.action !== 'scroll' || args.ref) {
      if (!element?.isConnected || !elementVisible(element)
          || JSON.stringify(elementSignature(element)) !== JSON.stringify(entry.signature)) {
        throw new Error('stale_reference: take a new browser_snapshot.');
      }
    }
    if (element && (element.disabled || element.getAttribute('aria-disabled') === 'true')) {
      throw new Error('The element is disabled.');
    }
    if (element && args.action !== 'scroll' && elementCovered(element)) throw new Error('element is covered');
    switch (args.action) {
      case 'click':
        element.click();
        break;
      case 'fill':
      case 'type': {
        const text = String(args.text ?? '');
        element.focus({preventScroll: true});
        if (element.tagName === 'SELECT') {
          if (args.action !== 'fill') throw new Error('Use fill to choose an option of a select.');
          const option = Array.from(element.options).find(item => item.value === text)
            || Array.from(element.options).find(item => item.text.trim() === text.trim());
          if (!option || option.disabled) throw new Error('No enabled option matches the given value or text.');
          element.selectedIndex = option.index;
        } else if (element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement || element instanceof HTMLSelectElement) {
          if (element.readOnly) throw new Error('The field is read-only.');
          const prototype = element instanceof HTMLInputElement ? HTMLInputElement.prototype
            : element instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLSelectElement.prototype;
          const value = args.action === 'type' ? element.value + text : text;
          Object.getOwnPropertyDescriptor(prototype, 'value').set.call(element, value);
        } else if (element.isContentEditable) {
          element.textContent = (args.action === 'type' ? element.textContent : '') + text;
        } else {
          throw new Error('The element is not an editable field.');
        }
        element.dispatchEvent(new Event('input', {bubbles: true}));
        element.dispatchEvent(new Event('change', {bubbles: true}));
        break;
      }
      case 'scroll':
        (element || window).scrollBy({left: args.delta_x ?? 0, top: args.delta_y ?? 600, behavior: 'instant'});
        break;
      default:
        throw new Error('Unsupported browser action.');
    }
  }
  const token = crypto.randomUUID();
  const refs = new Map();
  let extraLive = 0;
  const elements = Array.from(document.querySelectorAll('a,button,input,textarea,select,[role],[tabindex],[contenteditable],[aria-live]'))
    .filter(elementVisible)
    .filter((element, index) => index < 200 || (liveRegion(element) && ++extraLive <= 20)).map((element, index) => {
      const ref = `${token}.${index}`;
      const signature = elementSignature(element);
      refs.set(ref, {element, signature});
      const item = {ref, role: signature.role, name: signature.name, value: signature.value};
      if (element.tagName === 'SELECT') {
        item.options = Array.from(element.options).slice(0, 50).map(option => ({value: option.value, text: option.text.trim()}));
        item.selected = element.value;
      }
      if (elementCovered(element)) item.covered = true;
      if (liveRegion(element)) {
        const rect = element.getBoundingClientRect();
        if (rect.bottom <= 0 || rect.right <= 0 || rect.top >= globalThis.innerHeight || rect.left >= globalThis.innerWidth) item.offscreen = true;
      }
      return item;
    });
  globalThis.__macUseSnapshot = refs;
  return {url: location.href, title: document.title, ready: document.readyState === 'complete',
    text: (document.body?.innerText || '').slice(0, 16000), elements};
}

// Runs in the page's MAIN world, the only world that sees the page's fetch/XHR.
// Counts requests started after this call; older ones (polling, streams) are ignored.
export function settleBegin() {
  const g = globalThis;
  if (!g.__macUseNet) {
    const net = {seq: 0, marker: 0, open: new Set(), lastMutation: 0, observer: undefined};
    const track = () => {
      const id = ++net.seq;
      net.open.add(id);
      return () => net.open.delete(id);
    };
    const nativeFetch = g.fetch;
    if (typeof nativeFetch === 'function') {
      g.fetch = function (...fetchArgs) {
        const done = track();
        let promise;
        try { promise = nativeFetch.apply(this, fetchArgs); } catch (error) { done(); throw error; }
        promise.then(done, done);
        return promise;
      };
    }
    const nativeSend = g.XMLHttpRequest?.prototype?.send;
    if (nativeSend) {
      g.XMLHttpRequest.prototype.send = function (...sendArgs) {
        const done = track();
        this.addEventListener('loadend', done, {once: true});
        try { return nativeSend.apply(this, sendArgs); } catch (error) { done(); throw error; }
      };
    }
    g.__macUseNet = net;
  }
  const net = g.__macUseNet;
  net.marker = net.seq;
  net.lastMutation = performance.now();
  net.observer?.disconnect();
  net.observer = new MutationObserver(() => { net.lastMutation = performance.now(); });
  net.observer.observe(document, {subtree: true, childList: true, attributes: true, characterData: true});
}

export function settlePoll() {
  const net = globalThis.__macUseNet;
  if (!net) return {pending: 0, idle: 1e9};
  let pending = 0;
  for (const id of net.open) if (id > net.marker) pending++;
  return {pending, idle: performance.now() - net.lastMutation};
}

const settleLimits = {pollMs: 50, quietMs: 150, idleCapMs: 2000, pendingCapMs: 10000};

// Polled from the service worker because timers in a background tab are throttled.
export async function settle(session, limits = settleLimits) {
  const start = Date.now();
  let lastPending = start;
  for (;;) {
    await new Promise(resolve => setTimeout(resolve, limits.pollMs));
    const tab = await ownedTab(session);
    let poll;
    try {
      [{result: poll}] = await chrome.scripting.executeScript({target: {tabId: tab.id}, world: 'MAIN', func: settlePoll});
    } catch {
      poll = {pending: 1, idle: 0};
    }
    const now = Date.now();
    const pending = (poll?.pending ?? 0) + (tab.status === 'loading' ? 1 : 0);
    if (pending > 0) lastPending = now;
    if (pending === 0 && (poll?.idle ?? 1e9) >= limits.quietMs) return {settle_ms: now - start, settled: true};
    if (now - start >= limits.pendingCapMs || (pending === 0 && now - lastPending >= limits.idleCapMs)) {
      return {settle_ms: now - start, settled: false};
    }
  }
}

async function groupTab(tab) {
  const [existing] = await chrome.tabGroups.query({windowId: tab.windowId, title: 'mac-use'});
  if (existing) {
    return chrome.tabs.group({groupId: existing.id, tabIds: [tab.id]});
  }
  const groupId = await chrome.tabs.group({tabIds: [tab.id], createProperties: {windowId: tab.windowId}});
  await chrome.tabGroups.update(groupId, {title: 'mac-use', color: 'grey', collapsed: true});
  return groupId;
}

async function ownedTab(session) {
  const entry = sessions.get(session);
  if (!entry) throw new Error('No owned tab. Use browser_open first.');
  const tab = await chrome.tabs.get(entry.tabId);
  if (entry.takenOver || tab.active) {
    throw new Error('human_activity: you selected this tab. Use browser_close to release it, then browser_open for a new background tab.');
  }
  return tab;
}

function validURL(raw) {
  const url = new URL(raw);
  if (!['http:', 'https:'].includes(url.protocol)) throw new Error('Only HTTP and HTTPS URLs are supported.');
  return url.href;
}

export async function handleRequest(request) {
  const {operation, session, arguments: args = {}} = request;
  if (typeof session !== 'string' || !/^[a-f0-9-]{36}$/i.test(session)) throw new Error('Invalid browser session.');
  if (operation === 'browser_status') return {connected: true, mode: 'current_chrome_profile', hasTab: sessions.has(session)};
  if (operation === 'browser_close') {
    const entry = sessions.get(session);
    if (!entry) return {closed: false, released: false};
    let tab;
    try { tab = await chrome.tabs.get(entry.tabId); }
    catch {
      sessions.delete(session);
      return {closed: false, released: true};
    }
    if (entry.takenOver || tab.active) {
      sessions.delete(session);
      return {closed: false, released: true};
    }
    sessions.delete(session);
    try {
      await chrome.tabs.remove(entry.tabId);
      return {closed: true, released: true};
    } catch {
      return {closed: false, released: true};
    }
  }
  if (operation === 'browser_open') {
    const url = validURL(args.url);
    if (sessions.has(session)) throw new Error('Release the current tab with browser_close before opening another.');
    if (sessions.size >= 32) throw new Error('Release an existing mac-use browser session first.');
    const window = await chrome.windows.getLastFocused({windowTypes: ['normal']});
    if (window.incognito) throw new Error('Open a regular Chrome window in the profile you want to use.');
    // Navigate only as part of creating a new inactive tab; never update an existing one.
    activatedDuringCreation.clear();
    creatingTab = true;
    let tab;
    try { tab = await chrome.tabs.create({windowId: window.id, url, active: false}); }
    finally { creatingTab = false; }
    sessions.set(session, {tabId: tab.id, takenOver: tab.active || activatedDuringCreation.has(tab.id)});
    activatedDuringCreation.clear();
    if (!tab.active && !sessions.get(session)?.takenOver) {
      await chrome.tabs.update(tab.id, {muted: true});
      // Grouping is cosmetic; a failure must not fail browser_open.
      try { sessions.get(session).groupId = await groupTab(tab); } catch {}
    }
    return {url, loading: true, next: 'Use browser_snapshot to read the page after navigation.'};
  }
  if (!['browser_snapshot', 'browser_act'].includes(operation)) throw new Error('Unknown browser operation.');
  if (operation === 'browser_act') {
    if (!['click', 'fill', 'type', 'scroll'].includes(args.action)) throw new Error('Unsupported browser action.');
    if (args.action !== 'scroll' && typeof args.ref !== 'string') throw new Error('An element ref from browser_snapshot is required.');
    if (['delta_x', 'delta_y'].some(key => args[key] !== undefined && !Number.isFinite(args[key]))) throw new Error('Scroll distances must be finite.');
  }
  const tab = await ownedTab(session);
  if (tab.status === 'loading') throw new Error('The page is still loading. Take a browser_snapshot again shortly.');
  validURL(tab.url);
  const run = (world, func, funcArgs) => chrome.scripting.executeScript({target: {tabId: tab.id}, world, func, args: funcArgs});
  if (operation === 'browser_act') await run('MAIN', settleBegin);
  let results = await run('ISOLATED', pageOperation, [operation, args]);
  let settled = {};
  if (operation === 'browser_act') {
    if (!results[0]?.result) throw new Error('The page did not return a snapshot.');
    settled = await settle(session);
    // Refs from the pre-settle snapshot are replaced by one that shows the settled page.
    results = await run('ISOLATED', pageOperation, ['browser_snapshot', {}]);
  }
  if (sessions.get(session)?.takenOver || (await chrome.tabs.get(tab.id)).active) {
    throw new Error('human_activity: you selected this tab. No result will be returned.');
  }
  if (!results[0]?.result) throw new Error('The page did not return a snapshot.');
  return {...results[0].result, ...settled};
}

function badge(text, title) {
  chrome.action.setBadgeText({text});
  chrome.action.setTitle({title});
}

function disconnected(connection, error) {
  if (port !== connection) return;
  port = undefined;
  badge('OFF', error || 'mac-use disconnected. Reconnecting automatically; click to retry now.');
  // Let any running request settle before releasing session handles.
  requests = requests.then(async () => {
    for (const session of [...sessions.keys()]) {
      await handleRequest({operation: 'browser_close', session}).catch(() => {});
    }
  });
}

function connect() {
  if (port) return;
  const connection = chrome.runtime.connectNative(hostName);
  const connectedAt = Date.now();
  port = connection;
  badge('ON', 'mac-use connected. Reconnects automatically.');
  connection.onMessage.addListener(request => {
    requests = requests.then(async () => {
      if (port !== connection) return;
      let response;
      try { response = {id: request.id, ok: true, ...(await handleRequest(request))}; }
      catch (error) { response = {id: request.id, ok: false, error: String(error.message || error)}; }
      if (port === connection) connection.postMessage(response);
    }).catch(() => {});
  });
  connection.onDisconnect.addListener(() => {
    const error = chrome.runtime.lastError?.message;
    disconnected(connection, error);
    // A connection that fails at once is retried by the alarm, not in a tight loop.
    if (Date.now() - connectedAt >= 5000) setTimeout(connect, 1000);
  });
}

chrome.tabs.onActivated.addListener(({tabId}) => {
  if (creatingTab) activatedDuringCreation.add(tabId);
  for (const entry of sessions.values()) if (entry.tabId === tabId) entry.takenOver = true;
});
chrome.tabs.onRemoved.addListener(tabId => {
  for (const [session, entry] of sessions) if (entry.tabId === tabId) sessions.delete(session);
});
chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (changeInfo.groupId === undefined) return;
  for (const entry of sessions.values()) {
    if (entry.tabId === tabId && entry.groupId !== undefined && changeInfo.groupId !== entry.groupId) {
      entry.takenOver = true;
    }
  }
});
chrome.action.onClicked.addListener(() => {
  if (!port) connect();
});
chrome.runtime.onInstalled.addListener(connect);
chrome.runtime.onStartup.addListener(connect);
chrome.alarms.create('keep-connected', {periodInMinutes: 0.5});
chrome.alarms.onAlarm.addListener(alarm => {
  if (alarm.name === 'keep-connected') connect();
});
connect();
