# mac-use

A macOS 14+ native computer-use MCP server for Distill. Extracted from RemoteCode's window-scoped native computer-use backend. Jev proposes one semantic step at a time; macOS Accessibility and the native backend validate and execute it. It does **not** control Chrome background tabs (those need the RemoteCode extension), run an autonomous agent loop, generate text, or activate an application for you.

## Build and connect to Distill

```sh
cd /path/to/mac-use
swift build -c release
# Provide a TypeSafe API key in the environment that starts Distill; never commit it.
export TYPESAFE_API_KEY=... # Or JEV_API_KEY (TypeSafe credential)
distill mcp add mac-use -- /path/to/mac-use/.build/release/mac-use-mcp
distill mcp doctor mac-use
```

Use the absolute path to your checkout in place of `/path/to/mac-use`. Grant **Accessibility** and **Screen Recording** to the app that launched Distill if macOS requests them. `doctor` reports missing permissions instead of silently skipping them. The server never asks for an administrator password. A missing TypeSafe key (`JEV_API_KEY` or `TYPESAFE_API_KEY`) makes `jev_decide` return an error without proposing an action; observation and native tools remain available. Jev requests use TypeSafe's typed `POST /v1/systemone` API (`jev-latest`). The Jev model configured as a *Distill model tier* is a different feature; the MCP server cannot call Distill's private Rust Jev client.

## Usage

1. `list_windows` identifies an existing, on-screen target with `target_pid` and `target_window_id`.
2. `jev_decide` takes that exact target and the original user `goal`. It captures the current Accessibility tree locally, asks Jev a typed Choice plus completion, consequence and authorization questions, applies probability gates, and returns `click_element`, `WAIT`, `DONE`, or `BLOCKED`. It **does not** execute input. Only short button/menu labels and the goal (with basic path, URL, email and credential-pattern filtering) are sent to TypeSafe, not screenshots, coordinates, PID, state tokens, text field values or the full Accessibility tree. Credential-related goals are refused. Filtering cannot detect every secret or private name: use the tool only when sending eligible labels and goal text to TypeSafe is acceptable.
3. For `click_element`, pass the same target, the exact `role` and `label`, and `expected_state_token` from the proposal. Then observe and decide again. The backend checks current window identity, state freshness and human activity, and rejects ambiguous/unsupported input. `type` is an explicit separate operation for an already focused, settable Accessibility field; Jev cannot generate its text.
4. `screenshot`, `zoom`, `get_ui_tree`, `doctor` and `cursor_position` are local observation tools. `get_ui_tree` returns the **unsanitized** tree to the Distill agent; avoid copying it into remote prompts when privacy matters.

The physical pointer and foreground application remain the user's. `click_element` and coordinate `left_click` use Accessibility press actions; unsupported right-click, scrolling, key injection, application activation and arbitrary pointer moves are not exposed. Input yields to recent physical activity and is serialized with RemoteCode using the same host lock. The MCP does not bypass macOS privacy permissions or guarantee that applications expose usable Accessibility controls. A control can trigger side effects; review consequential proposals before executing.

## Verification

```sh
swift test
```

Offline tests use fake windows and a fake Jev transport; they do not send input or make TypeSafe requests. Live UI input has intentionally not been tested on the user's active Mac. No Core ML detector or local OCR pipeline is included: unlike the article's visual-first prototype, this version uses a current macOS Accessibility tree for actionable controls. If a target is absent or ambiguous, it stops rather than guessing coordinates.

## Origins

The native window, capture, activity monitor, queue, and MCP protocol implementation are adapted from the RemoteCode macOS project. The Jev decision boundary follows the TypeSafe [System One API](https://docs.typesafe.ai/introduction/quickstart) and the safety approach in [Implementing Computer-Use Using Jev on macOS](https://blog.fka.dev/blog/2026-09-19-implementing-computer-use-using-jev-on-macos/). The [jev-browser project](https://github.com/jkudish/jev-browser) informed the one-step typed-choice and trace approach; its code and Playwright browser are not included.
