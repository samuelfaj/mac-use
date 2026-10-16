# mac-use

A macOS 14+ MCP server for controlling native macOS windows through Accessibility. An optional Chrome extension lets it work in new background tabs in your current Chrome profile.

Read this in: [Español](README.es.md) · [Português](README.pt-BR.md)

### Why use mac-use?

mac-use is designed to work alongside your normal Mac use and compatible computer-use tools. For native windows, it defaults to background Accessibility actions on the exact window you choose, without activating it or moving your physical pointer; explicit foreground delivery and desktop pointer movement are opt-in. It waits for recent keyboard or mouse activity to settle and stops if you take over. Its shared lock serializes actions with other computer-use tools that honor the same lock, including RemoteCode. Tools that do not use that lock cannot be guaranteed conflict-free. In Chrome, mac-use opens background tabs and stops controlling a tab as soon as you select it. Tabs it opens are placed in a collapsed "mac-use" tab group; moving a tab out of the group or selecting it gives control back to you.

### What you need

- macOS 14 or newer
- Xcode Command Line Tools (`xcode-select --install`)
- An MCP client: Distill, Codex, Claude Code, or Grok Build
- Google Chrome only if you want the browser tools

### 1. Build the MCP server

Open Terminal and run:

```sh
git clone git@github.com:samuelfaj/mac-use.git
cd mac-use
swift build -c release
```

If you do not use GitHub SSH, replace the first command with the clone URL you normally use. Keep this folder in place after setup. The MCP clients below all start the same executable from this folder.

### 2. Connect it to your MCP client

Run **one** command for the client you use, from inside the `mac-use` folder:

- **Distill:**

  ```sh
  distill mcp add mac-use -- "$(pwd)/.build/release/mac-use-mcp"
  distill mcp doctor mac-use
  ```

- **Codex:**

  ```sh
  codex mcp add mac-use -- "$(pwd)/.build/release/mac-use-mcp"
  ```

- **Claude Code:**

  ```sh
  claude mcp add --scope user mac-use -- "$(pwd)/.build/release/mac-use-mcp"
  ```

- **Grok Build:**

  ```sh
  grok mcp add --scope user mac-use -- "$(pwd)/.build/release/mac-use-mcp"
  ```

If the client was already open, restart it after adding the server. In Claude Code, approve the server if prompted. Keep the repository at the same path; each client starts the executable from there.

### Install the agent skill globally

Install the bundled [mac-use skill](skills/mac-use/SKILL.md) from this repository for Codex, Claude Code, and Distill/Grok Build (which share `~/.grok/skills`):

```sh
for root in "$HOME/.codex/skills" "$HOME/.claude/skills" "$HOME/.grok/skills"; do
  mkdir -p "$root/mac-use"
  cp "skills/mac-use/SKILL.md" "$root/mac-use/SKILL.md"
done
```

Start a new client session after installation. The skill requires agents to close resources they create, including after failures, preserve user-owned resources, and verify cleanup. The MCP also advertises a cleanup reminder. This is agent guidance, not an automatic sandbox; the shared Chrome profile retains normal history and site state.

### 3. Allow macOS access for native windows

When macOS asks, allow **Accessibility** and **Screen Recording** for the app that runs your MCP client. These permissions are needed only for native macOS windows. You can use the MCP `doctor` tool on a window to check permissions.

### 4. Optional: set up Chrome

The Chrome extension is included in this repository. Load it into the same Chrome profile you plan to use with mac-use:

1. Open `chrome://extensions`.
2. Turn on **Developer mode**.
3. Click **Load unpacked** and select the `chrome-extension` folder inside the cloned `mac-use` folder.
4. Open the extension's details page and copy its 32-letter **ID**. The screenshot shows where to find it.

   ![Chrome extension details page with the extension ID highlighted](docs/images/chrome-extension-id.jpg)

5. In Terminal, from the `mac-use` folder, register the extension with the native host. Replace the example ID with the one from your Chrome page:

   ```sh
   .build/release/mac-use-mcp install-chrome-host YOUR_32_LETTER_EXTENSION_ID
   ```

6. The extension connects by itself and reconnects automatically (it retries every 30 seconds); its badge should say **ON**. Clicking the icon retries at once. In your MCP client, call `browser_status`; it should report `connected: true`.

The extension uses Chrome's native messaging to connect to the MCP server. If you move the repository or reload the extension and its ID changes, run the registration command again with the new path or ID. Use a regular Chrome window, not Incognito.

### Try it

- For a native window, call `list_windows`, then use the returned exact window details with the relevant mac-use tools.
- For Chrome, call `browser_status`, then `browser_open` with an `http://` or `https://` address. It opens a new background tab. Tabs opened by mac-use are placed in a collapsed "mac-use" tab group; moving a tab out of the group or selecting it gives control back to you. Use `browser_snapshot` to inspect it and `browser_act` for supported page actions.

`distill mcp doctor` checks that the MCP server starts and exposes its tools. It does not confirm macOS permissions or a Chrome connection.

### Optional: use cua Spaces when available

If the [cua](https://github.com/trycua/cua) CLI is installed (`curl -fsSL https://cua.ai/install.sh | sh`, then `cua auth login`), the read-only `cua_status` tool lists your [cua Spaces](https://spaces.cua.ai/). Agents should prefer a Space, through the `cua` MCP server, for work that does not need your own apps, files or signed-in sessions, so your Mac stays untouched. mac-use itself only detects Spaces; it does not control them. If `cua` is outside the MCP client's `PATH`, set `CUA_BIN` to its full path.

### cua-driver parity tools

Inspired by [trycua/cua's cua-driver](https://github.com/trycua/cua/tree/main/libs/cua-driver), these groups extend the existing tools:

- **Apps:** `list_apps`, `launch_app`, `kill_app`, `bring_to_front`. Launch in the background; force-terminate only apps you launched. `bring_to_front` is an explicit, persistent activation, not an automatic input fallback.
- **Desktop:** `list_windows`, `get_accessibility_tree` (desktop app/window summary), `get_desktop_state` (full-display screenshot), `get_screen_size`, `get_cursor_position`, `move_cursor`. Window-scope cursor movement updates the agent overlay only; `scope: "desktop"` moves the real pointer.
- **Input:** `click`, `double_click`, `right_click`, `drag`, `scroll`, `type_text`, `press_key`, `hotkey`, and the existing input tools. Background is the default. Input tools that expose `delivery_mode` accept `"background"` or `"foreground"`; only an explicit `delivery_mode: "foreground"` temporarily activates the target and restores the prior app afterward. Mutations refuse with `human_activity` when the activity guard detects the user on the target; never retry around that refusal.
- **Menus and window frame:** `invoke_menu` walks an exact menu path and refuses missing, ambiguous or disabled items; `set_value` edits a supported control; `set_window_frame` changes position/size and verifies by readback.
- **Verification:** `verify_state` returns `pass`, `fail` or `unknown` for structured expectations and natural-language `expect.criteria` evaluated by Jev (1–8 non-empty strings, at most 200 characters each; for example, `expect: {"criteria": ["The Save button is visible"]}`). An unknown check is not proof of success.
- **Clipboard:** `clipboard_read` (text only with `include_text: true`) and `clipboard_write` (text, image or file). Track prior contents before overwriting and restore only if no user change intervened.
- **Configuration, permissions and health:** `get_config`, `set_config`, `check_permissions`, `health_report`, plus `doctor`. Configuration persists in `~/.mac-use/config.json`; use diagnostics to check platform requirements rather than assuming permission or utility availability.
- **Sessions and agent cursor:** `start_session`, `end_session`, `get_session_state`; `set_agent_cursor_enabled`, `set_agent_cursor_theme`, `set_agent_cursor_motion`, `get_agent_cursor_state`. The visual overlay is click-through, does not take focus and never moves the real pointer. Track the session identity and end sessions you start.
- **Trajectory recording and replay:** `start_recording`, `stop_recording`, `get_recording_state`, `replay_trajectory`. Each `turn-0000N/` stores `action.json`, `before.png` and `after.png`. Optional video uses ScreenCaptureKit on macOS 15+; otherwise video is skipped. Stop recordings you start. Recordings can contain sensitive action arguments and images; protect their output. Replay repeats real actions and requires the same authorization and safety checks as live work.
- **Owned Chrome tab:** existing `browser_open`, `browser_snapshot`, `browser_act`, `browser_close`, `browser_status`, plus `browser_navigate`, `browser_click`, `browser_type` (`insert_text` or `keystrokes`), `browser_pointer` (hover, right-click, double-click, scroll, drag), `browser_dialog` (inspect, accept, dismiss, prompt text), `browser_set_input_files`, `browser_download`, and `page` (`execute_javascript`, `get_text`, `query_dom`, `click_element`, `insert_text`, `type_keystrokes`). They act only on the session's owned tab, never arbitrary user tabs. Use fresh refs after mutations and yield on user takeover.

The Chrome extension adds the `"debugger"` and `"downloads"` permissions for trusted input, dialogs, file selection and downloads. Reload the updated extension and approve any new permission prompt. Chrome may show its yellow **debugging** bar while `chrome.debugger` is attached during actions; an open dialog can keep it attached until handled. This does not grant ownership of other tabs.

Native tools require Accessibility and, for captures, Screen Recording. Existing AX tools and legacy focus guards remain available; the new input tools expose explicit delivery modes.

### Jev first

Jev is the main advantage: prefer text-only decisions over asking the session LLM to read screenshots. Use `jev_decide` for one step, `run_subtask` for a bounded multi-step native task with a Jev key, and `verify_state` with natural-language `expect.criteria` to verify the result. For Chrome, use `jev_decide` with `browser: true` on the owned tab. Jev works with filtered labels, roles and goal/criteria text, never screenshots, field values or secrets. This is faster and cheaper than screenshot reasoning; labels and goals may still contain private information. Use screenshots only when structured evidence is missing or insufficient.

Configure `JEV_API_KEY`, `TYPESAFE_API_KEY` or `OPENROUTER_API_KEY`. Without a key, use the returned local candidates/evidence with the session LLM; do not claim a Jev check passed. A configured Jev error is not success or permission to act. Jev advises, never authorizes consequential actions.

`jev_decide` suggests one step. With `JEV_API_KEY`, `TYPESAFE_API_KEY` or `OPENROUTER_API_KEY`, Jev answers and the reply also includes up to three runner-up `alternatives`, its `signals` (`complete`, `consequential`, `authorized`) and a `reason` when it returns `BLOCKED`, so your session LLM can check the advice or ask you. Without a key, it returns safe candidates for the session LLM to choose from. If a configured Jev call fails, the tool returns an error instead of switching silently. Neither path clicks anything.

### Native window tools

- `click_element` and `set_value` take either `element_id` (the `ax_<n>` id from the `get_ui_tree` whose token you pass) or `role` plus `label`, never both. `set_value` fills fields and combo boxes, sets sliders and checkboxes, and picks pop-up items. `menu_shortcut` presses the enabled menu item bound to a chord such as `MOD+S`.
- `get_ui_tree` accepts `ocr: auto|always|never`. OCR text is appended after the tree on an `ocr:` line and needs Screen Recording permission; without it the tree is returned with an `ocr_error`.
- Minimized windows and hidden apps work with the AX-only tools (`get_ui_tree`, `click_element`, `set_value`, `menu_shortcut`). Legacy pointer and key tools need an explicit `restore_window` request first; new delivery-mode tools follow the rules above.
- Mutations wait for the UI to settle and return a fresh observation with `settle_ms` and `settled`.
- `jev_decide` also takes `allowed_risks` (`delete`, `send`, `purchase`, `close`: controls in these categories are withheld unless listed), `min_confidence` and `min_margin` (0 to 1).
- `run_subtask` needs a Jev key. Pass `goal`, `verification` (non-empty list), and optionally `constraints`, `inputs`, `max_actions` (default 30), `shortcuts`, `allowed_risks`, `secret_inputs` (input keys typed but never shown to Jev or returned), `dry_run`, `min_confidence`, `min_margin`. It observes, asks Jev for one step, acts and repeats, then returns `SUBTASK_COMPLETE`, `BLOCKED`, `NEEDS_INPUT`, `NEEDS_AGENT` or `DRY_RUN`. Text typed comes only from `inputs`.
- Chrome extension: `browser_act` waits for the page to settle and returns a fresh snapshot, so earlier `ref`s go stale. It also handles select options and fill, skips covered elements, and reports live-region changes.

### If Chrome says "Specified native messaging host not found"

The extension's native host registration is missing or does not match the extension ID. From the `mac-use` folder, run the registration command again with the current ID from `chrome://extensions`. Then click the extension icon to reconnect. Check that `.build/release/mac-use-mcp` is still at the same path and that the extension is loaded in the Chrome profile you are using.

### Privacy and control

The Chrome extension can read page text and form values, except password values. It can click, fill, type, and scroll in tabs that it opened. It does not automate your selected tab; selecting an automated tab gives control back to you. When `browser_close` runs or the extension disconnects, it best-effort closes only tabs it created that still appear inactive and were not selected by the user. Chrome cannot make the activity check and tab removal atomic, so a selection racing with removal may still be closed. Page content and snapshots are visible to your Distill session, so do not use the browser tools on pages containing information you do not want to share with that session. The extension requests access to HTTP and HTTPS sites because it needs to operate on pages you ask it to open.

### Acknowledgements

Thanks to [shhivv](https://github.com/shhivv) and [arc-cua](https://github.com/shhivv/arc-cua), the inspiration for `run_subtask`, `set_value`, `menu_shortcut`, `allowed_risks`, `secret_inputs`, OCR perception, UI settling and element ids.
