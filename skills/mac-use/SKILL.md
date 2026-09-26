---
name: mac-use
description: Use the mac-use MCP for macOS windows or Chrome background tabs. Apply before calling its tools to track ownership, close resources the agent opens, restore temporary state, and verify cleanup without disturbing the user's existing work.
---

# mac-use

Complete the requested task and leave no unrequested resources or changes behind. Cleanup is part of completion, including after errors. Preserve the user's requested output and anything the user explicitly asks to keep open.

## Own only what you create

- Before opening anything, identify the relevant existing state: `browser_status` for this browser session, or `list_windows` for native windows. Record resources you create and how to close them in the task context, using exact returned identities or session handles. A matching title, URL, or process name does not prove ownership.
- Open the minimum resources needed and close each as soon as its purpose is complete. Choose a supported, targeted cleanup method before creating a resource. Keep a browser open/use/close cycle on the same MCP connection; a new server session cannot release an old session's tab.
- Existing tabs, windows, applications, processes, and user files are borrowed. Do not close them as cleanup. A resource the user takes over becomes user-owned, even if you created it.
- Treat cleanup as a `finally` step: run it on success, failure, blocked work, and cancellation while tools remain available, before handing off or sending the final response. Carry unresolved resource identities into a handoff. Do not rely on MCP exit or extension disconnect to clean up.

## Chrome: open, use, close, verify

Use the browser tools for HTTP(S) work through the connected Chrome extension. They operate on one owned background tab per MCP server session; they do not accept arbitrary tab IDs.

1. Call `browser_status` with `{}`. Require `connected: true`. If `hasTab: true`, reconcile it with this task's tracked resources before using or releasing it; do not close an unfamiliar session's work.
2. Call `browser_open` with `{"url":"https://example.com"}`. Record the cleanup obligation as soon as you attempt creation: an error or timeout can occur after a tab was created. Do not open another until this session's previous tab is released.
3. Use `browser_snapshot` with `{}` and `browser_act` with the current snapshot's `ref`. Use fresh observations after mutations or stale-reference errors. Avoid links/actions that spawn extra tabs or windows unless required; the browser tools cannot enumerate or close arbitrary popups.
4. As soon as you have the needed result, call `browser_close` with `{}` on the same connection, including when snapshot, navigation, or an action fails. If an open attempt failed ambiguously, inspect `browser_status` and reconcile ownership before cleanup or another open.
5. Inspect the close result and call `browser_status` again. `closed: true` confirms removal; `released: true` and `hasTab: false` confirm only that the session released its handle. They do **not** prove that the tab disappeared. `closed: false` may mean user takeover, an already removed tab, or failed removal. Never report all tabs closed from release alone.

On `human_activity`, stop acting on the tab and release it through `browser_close`; preserve the tab selected by the user. Do not switch the user's tab away, force-close it through native automation, or reconnect just to regain ownership. Only open a replacement if the task still requires it and doing so will not interfere with the user.

The extension makes a best-effort activity check before removal; selection and removal are not atomic. If cleanup is uncertain, do not manufacture proof or accumulate replacement sessions. Use a safe, supported inspection/recovery path for the exact owned resource, or report what remains unverified. Never quit Chrome, close all tabs, or disconnect the shared extension as cleanup.

## Native macOS windows

- Select the exact `target_pid` and `target_window_id` from `list_windows`. Obtain a fresh `get_ui_tree` or `screenshot` observation and pass its token as `expected_state_token` for mutations. Reobserve after each mutation. Use `doctor` with the target for permission diagnostics.
- Prefer Accessibility actions such as `click_element` using the observed role and label. `jev_decide` offers advice or local candidates; it neither authorizes nor executes an action. Without Jev, reason from available observations.
- Pointer/keyboard fallbacks require the exact window already focused. Do not activate another window merely to bypass that guard. `restore_window` changes focus and is only for an explicit user request; use the fresh token it returns. Stop when human activity or target validation rejects an action.
- Close a task-created native window through its freshly observed close control, or a supported exact-window close action. There is no generic native `close_window` MCP tool. Do not quit an application that also contains the user's windows, discard the user's unsaved work, or use blind global shortcuts.

## Other resources and final cleanup

- Close task-created dialogs, windows, and tabs. Stop only task-owned processes, servers, recordings, or automation sessions, using their exact identities. Do not stop shared MCP/native hosts or pre-existing applications.
- Remove only disposable downloads, screenshots, profiles, and temporary files created for this task. Keep requested deliverables. Do not clear shared history, cookies, caches, or other user data to simulate isolation.
- Avoid changing clipboard, focus, window geometry, settings, or permissions for convenience. If an authorized temporary change is necessary, record its prior value and restore it only while it remains your change; never overwrite intervening user activity. If safe restoration is unavailable, choose an isolated environment or stop before changing it.
- Verify cleanup with close results and fresh observations appropriate to the resource, such as `browser_status`, `list_windows`, or exact process/file checks. Check both that owned temporary resources are gone and that borrowed resources remain. Report unresolved cleanup and intentional handoffs briefly.

This skill is an agent workflow, not an automatic sandbox. The current Chrome profile retains normal browsing side effects such as history, cookies, and site state. If the task requires zero persistent browser/desktop state, use an authorized isolated environment; this MCP's shared-profile mode cannot provide that guarantee. Do not undo the actual user-requested changes in the name of cleanup.
