# mac-use

A macOS 14+ native computer-use MCP server for Distill. Extracted from RemoteCode's window-scoped native computer-use backend. Jev proposes one semantic step at a time; macOS Accessibility and the native backend validate and execute it. It does **not** control Chrome background tabs (those need the RemoteCode extension), run an autonomous agent loop, generate text, or activate an application for you.

## Build and connect to Distill

```sh
cd /path/to/mac-use
swift build -c release
# Optional: set OPENROUTER_API_KEY, JEV_API_KEY or TYPESAFE_API_KEY in the
# environment that starts Distill. Never commit a key.
distill mcp add mac-use -- /path/to/mac-use/.build/release/mac-use-mcp
distill mcp doctor mac-use
```

Use the absolute path to your checkout in place of `/path/to/mac-use`. Grant **Accessibility** and **Screen Recording** to the app that launched Distill if macOS requests them. `distill mcp doctor mac-use` checks server startup; the MCP's `doctor` tool reports native permission status for an exact target window. The server never asks for an administrator password. `JEV_API_KEY` or `TYPESAFE_API_KEY` use TypeSafe's typed `POST /v1/systemone` API (`jev-latest`); otherwise `OPENROUTER_API_KEY` uses OpenRouter's typed `POST /api/alpha/decisions` API (`typesafe/jev-1.13`). If all three keys are missing, `jev_decide` makes no Jev request and hands the safe local candidates to the Distill session LLM. An API outage or invalid response with a key configured remains an error, not a silent fallback. The Jev model configured as a *Distill model tier* is a different feature; the MCP server cannot call Distill's private Rust Jev client.

## Usage

1. `list_windows` identifies an existing, on-screen target with `target_pid` and `target_window_id`.
2. `jev_decide` takes that exact target and the original user `goal`. With a Jev key, it asks a typed Choice plus completion, consequence and authorization questions, applies probability gates, and returns `click_element`, `WAIT`, `DONE`, or `BLOCKED`. Without a key, it returns `mode: llm`, `operation: DEFER_TO_LLM` and a list of unambiguous eligible controls so the **Distill session LLM** can choose; the server does not pretend an LLM decision was made. Neither path executes input. With Jev, short button/menu labels and the goal (with basic path, URL, email and credential-pattern filtering) go to TypeSafe or OpenRouter, not screenshots, coordinates, PID, state tokens, text field values or the full Accessibility tree. Credential-related goals are refused on the Jev path. Filtering cannot detect every secret or private name: send Jev only goals and labels you are comfortable sharing with that provider. The no-key response contains labels, never field values.
3. For `click_element`, pass the same target, the exact `role` and `label`, and `expected_state_token` from the Jev proposal or local candidate response. In LLM mode, decide from the original user goal and current evidence; explicitly confirm authorization before a consequential action. Then observe and decide again. The backend checks current window identity, state freshness and human activity, and rejects ambiguous/unsupported input. `type` is an explicit separate operation for an already focused, settable Accessibility field; Jev cannot generate its text.
4. `screenshot`, `zoom`, `get_ui_tree`, `doctor` and `cursor_position` are local observation tools. `get_ui_tree` returns the **unsanitized** tree to the Distill agent; avoid copying it into remote prompts when privacy matters.

The physical pointer and foreground application remain the user's. `click_element` and coordinate `left_click` use Accessibility press actions; unsupported right-click, scrolling, key injection, application activation and arbitrary pointer moves are not exposed. Input yields to recent physical activity and is serialized with RemoteCode using the same host lock. The MCP does not bypass macOS privacy permissions or guarantee that applications expose usable Accessibility controls. A control can trigger side effects; review consequential proposals before executing.

## Verification

```sh
swift test
```

Offline tests use fake windows and a fake Jev transport; they do not send input or make TypeSafe requests. Live UI input has intentionally not been tested on the user's active Mac. No Core ML detector or local OCR pipeline is included: unlike the article's visual-first prototype, this version uses a current macOS Accessibility tree for actionable controls. If a target is absent or ambiguous, it stops rather than guessing coordinates.

## Origins

The native window, capture, activity monitor, queue, and MCP protocol implementation are adapted from the RemoteCode macOS project. The Jev decision boundary follows the TypeSafe [System One API](https://docs.typesafe.ai/introduction/quickstart) and the safety approach in [Implementing Computer-Use Using Jev on macOS](https://blog.fka.dev/blog/2026-09-19-implementing-computer-use-using-jev-on-macos/). The [jev-browser project](https://github.com/jkudish/jev-browser) informed the one-step typed-choice and trace approach; its code and Playwright browser are not included.
