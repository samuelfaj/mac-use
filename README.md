# mac-use

A macOS 14+ MCP server for controlling native macOS windows through Accessibility. An optional Chrome extension lets it work in new background tabs in your current Chrome profile.

Read this in: [Español](README.es.md) · [Português](README.pt-BR.md)

### Why use mac-use?

mac-use is designed to work alongside your normal Mac use and compatible computer-use tools. For native windows, it acts through Accessibility on the exact window you choose, without activating that window or moving your physical pointer. It waits for recent keyboard or mouse activity to settle and stops if you take over. Its shared lock serializes actions with other computer-use tools that honor the same lock, including RemoteCode. Tools that do not use that lock cannot be guaranteed conflict-free. In Chrome, mac-use opens background tabs and stops controlling a tab as soon as you select it. Tabs it opens are placed in a collapsed "mac-use" tab group; moving a tab out of the group or selecting it gives control back to you.

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

### Jev and the session LLM

`jev_decide` suggests one step. With `JEV_API_KEY`, `TYPESAFE_API_KEY` or `OPENROUTER_API_KEY`, Jev answers and the reply also includes up to three runner-up `alternatives`, its `signals` (`complete`, `consequential`, `authorized`) and a `reason` when it returns `BLOCKED`, so your session LLM can check the advice or ask you. Without a key, it returns safe candidates for the session LLM to choose from. If a configured Jev call fails, the tool returns an error instead of switching silently. Neither path clicks anything.

### Native window tools

- `click_element` and `set_value` take either `element_id` (the `ax_<n>` id from the `get_ui_tree` whose token you pass) or `role` plus `label`, never both. `set_value` fills fields and combo boxes, sets sliders and checkboxes, and picks pop-up items. `menu_shortcut` presses the enabled menu item bound to a chord such as `MOD+S`.
- `get_ui_tree` accepts `ocr: auto|always|never`. OCR text is appended after the tree on an `ocr:` line and needs Screen Recording permission; without it the tree is returned with an `ocr_error`.
- Minimized windows and hidden apps work with the AX-only tools (`get_ui_tree`, `click_element`, `set_value`, `menu_shortcut`). Pointer and key tools need `restore_window` first.
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
