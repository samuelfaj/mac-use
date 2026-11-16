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

## Stealth first, then escalate

Do the work without disturbing the user whenever a route for it exists, and do not stop when none does.

1. Start with the routes that never take focus or move the pointer: a background Chrome tab through the browser tools, Accessibility actions (`click_element`, `set_value`, `menu_shortcut`), and background delivery. For anything on the web, open your own background tab instead of acting on the Chrome window the user is looking at.
2. `human_activity` means the user is on the target: they typed in that app or moved the pointer over that window in the last two seconds, or they selected your tab. First look for a route around them, such as another background tab or a short wait and one retry.
3. If no quiet route can do the work, escalate instead of stopping. Retry the refused call with `allow_while_user_active: true`, and use `delivery_mode: "foreground"`, `bring_to_front` or `restore_window` when the app ignores background input. Do the minimum, then tell the user what you interrupted.
4. Never escalate when the user said they do not want to be interrupted, in this conversation or in their standing instructions. Stop and report what is still pending.

Escalation is about focus and timing only. A consequential action still needs the user's authorization.

## Jev-first decisions and verification

1. Start with structured text: native window metadata/Accessibility labels where supported, or `browser_snapshot` for the owned tab. Use filtered labels, roles and goal text; never send screenshots, field values or secrets to Jev.
2. Prefer `jev_decide` for the next authorized step; use `browser: true` for the owned Chrome tab. Use `run_subtask` with a Jev key for bounded native multi-step goals. Jev is faster and cheaper than screenshot reasoning, not a substitute for user authorization. Without a key, use returned local candidates/evidence; do not invent a Jev result or silently ignore a configured Jev error.
3. Verify results with `verify_state` and natural-language `expect.criteria`, evaluated by Jev over filtered text. Treat `fail` or `unknown` as unverified, not completion. Use screenshots only when structured text is unavailable or insufficient; never send those fallback images to Jev.

## Sessions, recordings and temporary state

- Before creating a named identity with `start_session`, inspect `get_session_state` and track the returned session and capture scope under the ownership rules above. Do not reuse or end an unfamiliar session. The agent cursor overlay is visual only, click-through and non-focusing; it never moves the real pointer.
- Track every recording you start and its output directory. In the `finally` cleanup, call `stop_recording` for your recording, then `end_session` for each session you started; inspect `get_recording_state` and `get_session_state` to verify cleanup. Do not stop another task's recording. Replay repeats real actions; authorize and verify them as live actions.
- Use `kill_app` only for an exact application PID you launched and still own, never a pre-existing application or one the user took over. Prefer closing the owned window when an application contains borrowed windows.
- If you overwrite the clipboard, first capture enough prior content to restore it safely. Track the overwrite, restore the prior clipboard only if it is still your change, and verify restoration. Never overwrite intervening user activity; if safe restoration is unavailable, do not overwrite it for convenience.
- Keep input in background mode by default. `delivery_mode: "foreground"` temporarily activates the target and restores the prior app; `bring_to_front` is a separate persistent activation. Both, and `allow_while_user_active`, are escalations: follow "Stealth first, then escalate" before using them. Window-scope `move_cursor` changes only the overlay; desktop scope moves the real pointer and is an escalation too.

## Chrome: open, use, close, verify

Use the browser tools for HTTP(S) work through the connected Chrome extension. They operate on one owned background tab per MCP server session; they do not accept arbitrary tab IDs. Tabs opened by mac-use are placed in a collapsed "mac-use" tab group; moving a tab out of the group or selecting it gives control back to the user. The owned tab keeps rendering while it stays in the background, so dialogs, menus and animated pages work there as they do in a visible tab.

All browser actions, including `browser_navigate`, `browser_click`, `browser_type`, `browser_pointer`, `browser_dialog`, `browser_set_input_files`, `browser_download` and `page`, act only on that owned tab. Do not click through a Chrome window with the native tools when a background tab can do the work: web content answers snapshot refs reliably and pixel clicks poorly. Use fresh snapshot refs after mutations. The extension needs `"debugger"` and `"downloads"` permissions; Chrome shows its yellow debugging bar from `browser_open` until `browser_close`.

1. Call `browser_status` with `{}`. It always answers with a `state`: `connected` means use the browser tools; `busy` means another call is running, so retry shortly; `outdated`, `not_connected` and `not_installed` come with a `hint` to act on or pass to the user. If `hasTab: true`, reconcile it with this task's tracked resources before using or releasing it; do not close an unfamiliar session's work.
2. Call `browser_open` with `{"url":"https://example.com"}`. Record the cleanup obligation as soon as you attempt creation: an error or timeout can occur after a tab was created. Do not open another until this session's previous tab is released.
3. Use `browser_snapshot` with `{}` and `browser_act` with the current snapshot's `ref`. Use fresh observations after mutations or stale-reference errors. Avoid links/actions that spawn extra tabs or windows unless required; the browser tools cannot enumerate or close arbitrary popups.
4. As soon as you have the needed result, call `browser_close` with `{}` on the same connection, including when snapshot, navigation, or an action fails. If an open attempt failed ambiguously, inspect `browser_status` and reconcile ownership before cleanup or another open.
5. Inspect the close result and call `browser_status` again. `closed: true` confirms removal; `released: true` and `hasTab: false` confirm only that the session released its handle. They do **not** prove that the tab disappeared. `closed: false` may mean user takeover, an already removed tab, or failed removal. Never report all tabs closed from release alone.

On `human_activity`, the user selected your tab. Release it through `browser_close`, which leaves the tab they selected open, then `browser_open` a new background tab and continue there. If the work cannot be redone in a new tab, pass `allow_while_user_active: true` on the calls for that tab, under "Stealth first, then escalate". Do not switch the user's tab away, force-close it through native automation, or reconnect just to regain ownership.

`tab_unresponsive` means the page did not answer within 30 seconds. Its tab was already released, and closed unless the user had selected it. Call `browser_open` again; other sessions were not affected.

The extension makes a best-effort activity check before removal; selection and removal are not atomic. If cleanup is uncertain, do not manufacture proof or accumulate replacement sessions. Use a safe, supported inspection/recovery path for the exact owned resource, or report what remains unverified. Never quit Chrome, close all tabs, or disconnect the shared extension as cleanup.

## Prefer a cua Space when it fits

Call `cua_status` before touching the user's Mac. If it reports `available: true` and the task does not need the user's own apps, windows, files or signed-in sessions, do the work in a cua Space through the `cua` MCP server instead (`list_spaces`, `create_space` with `reuse: true`, then its tools), name the Space in the answer, and delete any cloud Space you created. Use mac-use for work that must happen on the real Mac or in the user's Chrome profile.

## Native macOS windows

Work in this order; each step keeps the next one small.

1. **Find the window.** `list_windows` gives the exact `target_pid` and `target_window_id`. Use `doctor` with the target for permission diagnostics.
2. **Read narrowly.** `get_ui_tree` returns one row per element, `- [ax_12] AXButton "Save" (description) = "value" [Press]`, 250 rows by default. Pass `query` (a substring, `a|b` for alternatives) to get only the rows you need with their ancestors, and `max_elements` to change the limit. A browser or Electron window has hundreds of rows; never read it whole to find one control.
3. **Act on the element.** Use `click_element`, `set_value`, `click` or `type_text` with `element_id`, and pass the `state_token` of the read it came from as `expected_state_token`. The id keeps meaning the element you read while the rest of the window changes. `stale_state_token` now means that element changed or disappeared, or the read is more than eight reads old for that window: read again and use the new id. `role` plus `label` works without an id when exactly one element matches.
4. **Use pixels only for what the tree does not show.** `screenshot` returns the window scaled to `max_image_dimension` (1366 by default; `0` for the native frame) and states `image_size`. `click` and the other pixel tools take `x`,`y` in that image. `zoom` returns a native-detail crop of a region.
5. **Read the result before building on it.** `effect: "ui_changed"` means the app was seen to react. `effect: "unverified"` means the input was sent and nothing was observed, which is not proof either way: read the window again before repeating anything, above all a toggle. A `warning` about a covered window means a Chromium page that is not being shown took no input: use the browser tools for web pages, or foreground delivery.

More on acting:

- `set_value` fills fields, sliders, checkboxes and pop-ups. `menu_shortcut` and `hotkey` press the enabled menu item bound to a chord such as `MOD+S` without focusing the window.
- Keys go to whatever holds focus. Pass `element_id` to `press_key` or `hotkey` to give that element focus first. In `type_text`, a newline or tab is sent as a real Return or Tab key press, so `"query\n"` types and submits. A browser's own address bar is the exception: it does not submit in the background, so use `browser_navigate` in your tab, or foreground delivery.
- An accepted Accessibility action proves acceptance, not delivery. If `AXPress` is demonstrably ineffective, use `click` with the `element_id` and `action: "pointer"` for one explicit pointer route. Read back before retrying any send. `type_text` refuses an accepted AX insertion when its value cannot be verified, instead of retrying the text through another route.
- `run_steps` runs several calls in one round trip, stops at the first failure and can read the window once at the end (`observe`). Use it to act and re-read together.
- Minimized windows and hidden apps allow only the Accessibility tools (`get_ui_tree`, `click_element`, `set_value`, `menu_shortcut`); pointer and key input need `restore_window` first, which changes focus and is an escalation. When human activity rejects an action, follow "Stealth first, then escalate". Stop when target validation rejects it.
- An unknown argument is refused with the list of accepted ones; nothing is dropped in silence. The earlier `left_click`, `right_click`, `type`, `key`, `mouse_move` and `cursor_position` still run but are no longer listed: `click`, `type_text`, `press_key`, `move_cursor` and `get_cursor_position` do their jobs.
- Close a task-created native window through its freshly observed close control, or a supported exact-window close action. There is no generic native `close_window` MCP tool. Do not quit an application that also contains the user's windows, discard the user's unsaved work, or use blind global shortcuts.

## Jev and bounded subtasks

- Prefer Accessibility actions on the observed element. `jev_decide` offers advice or local candidates; it neither authorizes nor executes an action. Without Jev (`mode: llm`), choose from `candidates` using the user's goal.
- With Jev (`mode: jev`), check its choice against the goal, `alternatives` and `signals`. On `BLOCKED`, read `reason`: ask the user when a material action lacks authorization, otherwise observe again or pick a listed candidate only when the goal makes it unambiguous. A high `consequential` signal needs explicit user authorization no matter what Jev chose.
- `get_ui_tree` takes `ocr: auto|always|never`; OCR text follows the tree on an `ocr:` line and needs Screen Recording. `jev_decide` always reads without OCR.
- `jev_decide` accepts `allowed_risks` (`delete`, `send`, `purchase`, `close`), `min_confidence` and `min_margin`. Pass `allowed_risks` only for categories the user's goal explicitly authorizes; other risky controls are withheld.
- `run_subtask` (needs a Jev key) runs a bounded observe-decide-act loop. Fields: `goal`, `verification` (non-empty), `constraints`, `inputs`, `max_actions` (default 30), `shortcuts`, `allowed_risks`, `secret_inputs` (typed but never shown to Jev or returned), `dry_run`, `min_confidence`, `min_margin`. Statuses: `SUBTASK_COMPLETE`, `BLOCKED`, `NEEDS_INPUT` (supply the missing input), `NEEDS_AGENT` (take over, e.g. a risky control), `DRY_RUN`. Verify the result yourself before reporting completion.
- Chrome: `browser_act` waits for the page to settle and returns a fresh snapshot, so earlier `ref`s are stale. `browser_snapshot` takes `query` to return only matching controls. Select options and fill are supported, covered elements are refused, and live-region changes are reported.

## Other resources and final cleanup

- Close task-created dialogs, windows, and tabs. Stop only task-owned processes, servers, recordings, or automation sessions, using their exact identities. Do not stop shared MCP/native hosts or pre-existing applications.
- Remove only disposable downloads, screenshots, profiles, and temporary files created for this task. Keep requested deliverables. Do not clear shared history, cookies, caches, or other user data to simulate isolation.
- Avoid changing clipboard, focus, window geometry, settings, or permissions for convenience. If an authorized temporary change is necessary, record its prior value and restore it only while it remains your change; never overwrite intervening user activity. If safe restoration is unavailable, choose an isolated environment or stop before changing it.
- Verify cleanup with close results and fresh observations appropriate to the resource, such as `browser_status`, `list_windows`, or exact process/file checks. Check both that owned temporary resources are gone and that borrowed resources remain. Report unresolved cleanup and intentional handoffs briefly.

This skill is an agent workflow, not an automatic sandbox. The current Chrome profile retains normal browsing side effects such as history, cookies, and site state. If the task requires zero persistent browser/desktop state, use an authorized isolated environment; this MCP's shared-profile mode cannot provide that guarantee. Do not undo the actual user-requested changes in the name of cleanup.
