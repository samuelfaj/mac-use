# mac-use

A macOS 14+ computer-use [MCP](https://modelcontextprotocol.io/) server for Distill. It controls an exact, existing macOS window through Accessibility without activating the window or moving the physical pointer. An optional Chrome extension works in **new background tabs** in your current Chrome profile; it does not take over existing tabs. Selecting an automated tab transfers it to you and blocks further automation in that tab.

## Build and connect to Distill

Install Xcode Command Line Tools and Google Chrome (Chrome is needed only for browser tools). Clone this repository, then run:

```sh
git clone git@github.com:samuelfaj/mac-use.git
cd mac-use
swift build -c release
distill mcp add mac-use -- "$(pwd)/.build/release/mac-use-mcp"
distill mcp doctor mac-use
```

Use a different clone URL if you do not use GitHub SSH. The executable is a local, stdio MCP server; leave the repository and built executable in place after registration. Restart Distill if a running session does not discover the new tools. `distill mcp doctor` checks startup and tool discovery; it does **not** verify macOS permissions or a Chrome connection.

For native windows, grant **Accessibility** and **Screen Recording** to the application that starts Distill if macOS prompts for them. Use the MCP `doctor` tool on an exact window to check native permissions. No administrator password is needed.

### Optional Jev credentials

Set one of `JEV_API_KEY`, `TYPESAFE_API_KEY`, or `OPENROUTER_API_KEY` in the environment that launches Distill; do not commit credentials. Direct TypeSafe credentials take priority (`JEV_API_KEY` before `TYPESAFE_API_KEY`) and use `POST https://api.typesafe.ai/v1/systemone` with `jev-latest`. Otherwise `OPENROUTER_API_KEY` uses `POST https://openrouter.ai/api/alpha/decisions` with `typesafe/jev-1.13`. If all three are absent, `jev_decide` makes no Jev request and returns safe candidates for the **Distill session LLM** to decide. A failed authenticated Jev request is an error, not a silent fallback. The Jev model configured as a Distill model tier is separate; this MCP cannot call Distill's private Jev client.

## Install the Chrome extension

The extension lives in [`chrome-extension/`](chrome-extension/). It has its own native messaging host (`io.macuse.computer_use`) and registration; it does not overwrite RemoteCode's extension or native host. Google Chrome must be running in a regular, non-incognito profile. Loading the unpacked extension and choosing the Chrome profile are deliberate user actions:

1. In **the Chrome profile you intend to use**, open `chrome://extensions`, enable **Developer mode**, and select **Load unpacked**. Choose the `chrome-extension` folder inside this repository (the folder containing `manifest.json`, not the repository root).
2. Find **mac-use Computer Use** on that page and copy its 32-letter **ID**. From the repository root, run:

   ```sh
   .build/release/mac-use-mcp install-chrome-host YOUR_32_LETTER_EXTENSION_ID
   ```

   This registers a user-local Chrome native messaging host in `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/io.macuse.computer_use.json`. The host wrapper and private socket live under `~/Library/Application Support/mac-use/ChromeComputerUse/`. It does not install a system daemon. Keep the release binary at the same path; after rebuilding it, the wrapper uses the new binary automatically. If you move the checkout or Chrome gives the extension a different ID, rerun this command with its new ID.
3. Click the extension's toolbar icon to connect. Its badge should show **ON**. If the badge shows **OFF**, click again after checking that the ID and binary path are correct. A fresh Distill session can call `browser_status` to confirm `connected: true`.

Chrome's native messaging host is launched by Chrome when the extension connects; the MCP process communicates over a local user-only Unix socket. This integration uses Chrome's `nativeMessaging`, `tabs`, `scripting`, and HTTP(S) host permissions. It can read page text and form values (except password values), and can click, fill, type, or scroll **in tabs it created**. Install it only in a profile where you trust this access. Browser snapshots are not redacted and can be sent to your session's LLM; avoid sensitive pages. The extension does not export your cookies, launch a debugging browser, activate a tab, or use your physical pointer. It cannot operate Chrome internal pages, file URLs, incognito windows, or an already-selected tab.

## Use native windows

1. Call `list_windows` to identify an on-screen window by `target_pid` and `target_window_id`.
2. Call `jev_decide` with that exact target and your goal. With a Jev key, it proposes `click_element`, `WAIT`, `DONE`, or `BLOCKED` after probability and authorization checks. Without a key it returns `mode: llm`, `operation: DEFER_TO_LLM` and eligible controls for the Distill session LLM to choose. Neither path posts input. Only filtered goal text and short Accessibility labels go to Jev; screenshots, coordinates, state tokens and field values do not. Filtering cannot detect every private label.
3. For a permitted `click_element`, pass the exact target, `role`, `label`, and `expected_state_token`; observe again after each action. Confirm consequential actions explicitly. Native operations recheck window identity, state freshness, and recent human activity. `type` sets text in an already-focused, settable Accessibility field; Jev does not generate typed text.

`screenshot`, `zoom`, `get_ui_tree`, `cursor_position` and `doctor` are local observation tools. `get_ui_tree` contains unsanitized on-screen text. Native `left_click` uses Accessibility rather than moving the cursor. Unsupported input, unavailable permissions, ambiguous targets, and human activity fail closed. Native actions share RemoteCode's cross-process input lock.

## Use Chrome background tabs

1. Call `browser_status` to verify the extension is connected. Call `browser_open` with an HTTP(S) `url` to create a **new, inactive tab (muted immediately when still unselected)** in the connected profile. It does not reuse the tab you are browsing.
2. Call `browser_snapshot` after navigation finishes. It returns page text and element `ref`s. Call `browser_act` with `action: click`, `fill`, `type`, or `scroll`; use the fresh `ref` for element actions (`scroll` can omit it). Provide `text` for fill/type or `delta_x`/`delta_y` for scroll. Re-snapshot before relying on refs after page changes; never guess a ref. Explicitly confirm consequential actions.
3. Call `browser_close` when finished. It releases the session handle but **leaves the tab open** for you to close manually: Chrome has no atomic “remove only if still inactive” operation. If you select a tab, the extension will not read or mutate it again. After releasing the old handle, use `browser_open` to create a new background tab.

Chrome tools do **not** call Jev automatically: Distill's session LLM decides from the snapshot. The Jev decision tool applies only to native Accessibility windows. Browser sessions are scoped to one MCP server process and extension connection; restarting either loses those session handles. If Chrome disconnects, it releases session handles and leaves all tabs open. If you select a tab, the extension leaves it alone. Avoid entering passwords or other secrets through `browser_act` because browser tool arguments and snapshots are visible to your agent session.

## Verification and limits

```sh
swift test
node --test --experimental-default-type=module Tests/ChromeExtensionTests.mjs
```

Tests use fake windows, a fake Jev transport and a mocked browser connection; no test sends input to the user's Mac or makes a live Jev request. Run `distill mcp doctor mac-use` after rebuilding and use `browser_status` after you install and connect Chrome. A successful doctor handshake alone does not prove Chrome is connected. This repository does not run an autonomous agent loop, generate text, or include a Core ML detector or local OCR. The native backend uses macOS Accessibility; if a target is absent or ambiguous it stops instead of guessing coordinates.

## Origins

The native backend and Chrome extension are adapted from RemoteCode's macOS computer-use implementation. The Jev decision boundary follows TypeSafe's [System One API](https://docs.typesafe.ai/introduction/quickstart) and [Implementing Computer-Use Using Jev on macOS](https://blog.fka.dev/blog/2026-09-19-implementing-computer-use-using-jev-on-macos/). The [jev-browser project](https://github.com/jkudish/jev-browser) informed the one-step typed-choice approach; its code and Playwright browser are not included.
