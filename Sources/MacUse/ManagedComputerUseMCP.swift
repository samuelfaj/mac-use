import Foundation

public struct ComputerUseContentPart: Sendable, Equatable {
    public var type: String
    public var text: String?
    public var data: String?
    public var mimeType: String?

    public init(type: String, text: String? = nil, data: String? = nil, mimeType: String? = nil) {
        self.type = type
        self.text = text
        self.data = data
        self.mimeType = mimeType
    }

    public static func text(_ value: String) -> ComputerUseContentPart {
        ComputerUseContentPart(type: "text", text: value)
    }

    public static func image(data: String, mimeType: String) -> ComputerUseContentPart {
        ComputerUseContentPart(type: "image", data: data, mimeType: mimeType)
    }

    /// Decode one zavora / MCP content item. Image parts keep data + mimeType.
    public static func parse(_ object: [String: Any]) -> ComputerUseContentPart? {
        guard let type = object["type"] as? String, !type.isEmpty else { return nil }
        return ComputerUseContentPart(
            type: type,
            text: object["text"] as? String,
            data: object["data"] as? String,
            mimeType: object["mimeType"] as? String
        )
    }

    public func jsonObject() -> [String: Any] {
        var object: [String: Any] = ["type": type]
        if let text { object["text"] = text }
        if let data { object["data"] = data }
        if let mimeType { object["mimeType"] = mimeType }
        return object
    }
}

public struct ComputerUseToolResult: Sendable, Equatable {
    public var content: [ComputerUseContentPart]
    public var isError: Bool

    public init(content: [ComputerUseContentPart], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public init(text: String, isError: Bool = false) {
        self.content = [.text(text)]
        self.isError = isError
    }

    /// Decode an injected/backend tools/call result so screenshot/zoom images survive.
    public static func parseUpstream(_ object: [String: Any]) -> ComputerUseToolResult {
        if let error = object["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? String(describing: error)
            return ComputerUseToolResult(text: message, isError: true)
        }
        let result = object["result"] as? [String: Any] ?? object
        let raw = result["content"] as? [[String: Any]] ?? []
        let parts = raw.compactMap(ComputerUseContentPart.parse)
        return ComputerUseToolResult(
            content: parts,
            isError: result["isError"] as? Bool ?? false
        )
    }

    public func jsonContent() -> [[String: Any]] {
        content.map { $0.jsonObject() }
    }
}

public protocol ComputerUseToolBackend: Sendable {
    func invoke(name: String, arguments: [String: Any]) async -> ComputerUseToolResult
}

/// Test backend: records that the host queue admitted the call. Production uses
/// the shipped native backend; callers can inject another backend for tests.
public struct ComputerUseQueuedPassthroughBackend: ComputerUseToolBackend {
    public init() {}

    public func invoke(name: String, arguments: [String: Any]) async -> ComputerUseToolResult {
        let keys = arguments.keys.sorted().joined(separator: ",")
        return ComputerUseToolResult(
            text: "queued \(name)\(keys.isEmpty ? "" : " keys=\(keys)")",
            isError: false
        )
    }
}

/// MCP request handler for the shipped native host backend: screenshot plus
/// targeted semantic/input operations. Mutating and observation tools share
/// `ComputerUseHostQueue` so two bots never interleave HID.
public struct ManagedComputerUseMCP: Sendable {
    public static let serverName = ComputerUseHostQueue.serverName
    public static let screenshotTool = "screenshot"
    public static let leftClickTool = "left_click"
    public static let typeTool = "type"

    public static let observationTools: [String] = [
        screenshotTool,
        "zoom",
        "cursor_position",
        "list_windows",
        "get_ui_tree",
        "jev_decide",
        "run_subtask",
        "doctor",
        "cua_status",
    ]

    public static let mutationTools: [String] = [
        leftClickTool,
        typeTool,
        "click_element",
        "set_value",
        "menu_shortcut",
        "restore_window",
        "right_click",
        "mouse_move",
        "scroll",
        "key",
    ]

    public static var advertisedToolNames: [String] {
        observationTools + mutationTools + ChromeProfileComputerUseBackend.tools
    }

    private let queue: ComputerUseHostQueue
    private let backend: any ComputerUseToolBackend
    private let jev: JevDecision
    private let browser: any ComputerUseToolBackend
    private let jevAvailable: @Sendable () -> Bool
    private let cua: CuaSpaces
    private let jevTransport: any JevTransport

    public init(
        queue: ComputerUseHostQueue = .shared,
        backend: any ComputerUseToolBackend = ComputerUseNativeHostBackend(),
        jev: JevDecision = JevDecision(),
        browser: any ComputerUseToolBackend = ChromeProfileComputerUseBackend(),
        jevAvailable: @escaping @Sendable () -> Bool = {
            TypeSafeJevTransport.isConfigured()
        },
        cua: CuaSpaces = CuaSpaces(),
        jevTransport: any JevTransport = TypeSafeJevTransport()
    ) {
        self.queue = queue
        self.backend = backend
        self.jev = jev
        self.browser = browser
        self.jevAvailable = jevAvailable
        self.cua = cua
        self.jevTransport = jevTransport
    }

    public func handle(_ line: String) async -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return errorReply(id: nil, code: -32700, message: "parse error")
        }
        let id = message["id"]
        guard let method = message["method"] as? String else {
            return id == nil ? nil : errorReply(id: id, code: -32600, message: "invalid request")
        }
        if id == nil || method.hasPrefix("notifications/") { return nil }
        switch method {
        case "initialize":
            return reply(id: id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": Self.serverName, "version": "1"],
                "instructions": "Read the installed mac-use skill before using these tools (repository: skills/mac-use/SKILL.md). Track resources created by this task and clean them up on success, failure, or cancellation before responding. Preserve pre-existing resources, user takeovers, and requested deliverables. After each browser use, call browser_close on the same MCP connection and verify the result plus browser_status; released does not mean closed. Report cleanup that cannot be verified. Call cua_status first: when cua Spaces are available, prefer a Space (through the cua MCP server) for work that does not need the user's own apps, windows, files or signed-in sessions. mac-use controls exact macOS windows without implicit activation. Use restore_window only when explicitly requested, then use its fresh state token. Pointer fallback tools use screenshot coordinates and require the exact window already focused, not merely another window of the same foreground app; key accepts an allowlisted key only while the exact window is already focused. List windows, then use jev_decide for one semantic step: it uses Jev with JEV_API_KEY, TYPESAFE_API_KEY or OPENROUTER_API_KEY; without any key it returns safe candidates for the session LLM to decide. With Jev, the reply also lists runner-up alternatives, complete/consequential/authorized signals and a reason when BLOCKED, so the session LLM can verify the advice or ask the user; alternatives are evidence, never authorization. Neither mode posts input. Call click_element with the exact role, label, target and state token only when authorized; set_value sets a field/slider/checkbox/pop-up by role and label, and menu_shortcut presses the enabled menu item bound to a chord (MOD+S), both without focusing the window. Minimized windows and hidden apps allow get_ui_tree, click_element and set_value; input-event tools need restore_window first. Reobserve after every mutation. Chrome background tabs use browser_status, browser_open, browser_snapshot, browser_act and browser_close with the separately installed extension; close each owned tab as soon as its purpose is complete, including after an error. The extension best-effort closes tabs it created that remain inactive and were not selected by the user; Chrome cannot make the activity check and tab removal atomic, so a selection racing with removal may still be closed. Selecting an automated tab yields control to the user. Native mutation yields to human activity and fails closed when safe background actions are unavailable. Jev receives filtered goal text and eligible Accessibility labels, never screenshots or field values; labels and goals may still contain private information. For a multi-step goal with a Jev key, run_subtask runs a bounded observe-decide-act loop over your inputs, verification and constraints and returns SUBTASK_COMPLETE, BLOCKED, NEEDS_INPUT, NEEDS_AGENT or DRY_RUN; secret_inputs are typed but never shown to Jev or returned.",
            ])
        case "tools/list":
            return reply(id: id, result: ["tools": Self.toolCatalog()])
        case "tools/call":
            let params = message["params"] as? [String: Any]
            let name = params?["name"] as? String ?? ""
            let arguments = params?["arguments"] as? [String: Any] ?? [:]
            guard Self.advertisedToolNames.contains(name) else {
                return errorReply(id: id, code: -32602, message: "unknown tool: \(name)")
            }
            if ChromeProfileComputerUseBackend.tools.contains(name) {
                let result = await browser.invoke(name: name, arguments: arguments)
                return reply(id: id, result: ["content": result.jsonContent(), "isError": result.isError])
            }
            if name == "cua_status" {
                let result = ComputerUseToolResult(text: encode(cua.status()) ?? "{}")
                return reply(id: id, result: ["content": result.jsonContent(), "isError": false])
            }
            let kind: ComputerUseHostQueue.Kind = Self.mutationTools.contains(name) ? .mutation : .observation
            let targetPID = Self.targetPID(from: arguments)
            if name == "run_subtask" {
                guard let target = ComputerUseNativeHostBackend.exactInt32(arguments["target_pid"]),
                      let window = ComputerUseNativeHostBackend.exactUInt32(arguments["target_window_id"]),
                      target > 0, window > 0 else {
                    return errorReply(id: id, code: -32602, message: "target_pid and target_window_id are required")
                }
                let subtask: Subtask
                do {
                    subtask = try Subtask.parse(arguments)
                } catch {
                    let text = SecretRedactor(rawArguments: arguments).redact(String(describing: error))
                    let result = ComputerUseToolResult(text: text, isError: true)
                    return reply(id: id, result: ["content": result.jsonContent(), "isError": true])
                }
                guard jevAvailable() else {
                    let result = ComputerUseToolResult(
                        text: "run_subtask needs a Jev key; use jev_decide for LLM-driven steps", isError: true)
                    return reply(id: id, result: ["content": result.jsonContent(), "isError": true])
                }
                let output = await SubtaskRunner(backend: backend, transport: jevTransport, queue: queue).run(
                    target: ComputerUseNativeHostTarget(pid: target, windowID: window), subtask: subtask,
                    dryRun: subtask.dryRun, logPath: arguments["log_path"] as? String)
                let result = ComputerUseToolResult(text: encode(output) ?? "{}")
                return reply(id: id, result: ["content": result.jsonContent(), "isError": false])
            }
            if name == "jev_decide" {
                guard let goal = arguments["goal"] as? String, !goal.isEmpty else {
                    return errorReply(id: id, code: -32602, message: "goal is required")
                }
                var allowedRisks = Set<RiskCategory>()
                var minConfidence = 0.0
                var minMargin = 0.0
                do {
                    if let raw = arguments["allowed_risks"] {
                        guard let names = raw as? [String] else {
                            throw SubtaskError.invalid(field: "allowed_risks", reason: "must be an array of strings")
                        }
                        for name in names {
                            guard let category = RiskCategory(rawValue: name) else {
                                throw SubtaskError.invalid(field: "allowed_risks", reason: "'\(name)' is not one of delete, send, purchase, close")
                            }
                            allowedRisks.insert(category)
                        }
                    }
                    for (field, key) in [("min_confidence", 0), ("min_margin", 1)] {
                        guard let raw = arguments[field] else { continue }
                        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                              number.doubleValue.isFinite, (0...1).contains(number.doubleValue) else {
                            throw SubtaskError.invalid(field: field, reason: "must be a number between 0 and 1")
                        }
                        if key == 0 { minConfidence = number.doubleValue } else { minMargin = number.doubleValue }
                    }
                } catch {
                    let result = ComputerUseToolResult(text: String(describing: error), isError: true)
                    return reply(id: id, result: ["content": result.jsonContent(), "isError": true])
                }
                do {
                    let observation = try await queue.withExclusive(kind: .observation, targetPID: targetPID) {
                        await backend.invoke(name: "get_ui_tree", arguments: arguments.merging(["ocr": "never"]) { _, new in new })
                    }
                    guard !observation.isError, let text = observation.content.first?.text else {
                        return reply(id: id, result: ["content": observation.jsonContent(), "isError": true])
                    }
                    let outputFromModel: [String: Any]
                    if jevAvailable() {
                        outputFromModel = try await jev.advise(
                            goal: goal, observation: text, allowedRisks: allowedRisks,
                            minConfidence: minConfidence, minMargin: minMargin).jsonObject()
                    } else {
                        outputFromModel = try jev.localFallback(observation: text, allowedRisks: allowedRisks)
                    }
                    var output = outputFromModel
                    if let prefix = text.range(of: "\nui_tree: "),
                       let header = text[..<prefix.lowerBound].data(using: .utf8),
                       let status = try? JSONSerialization.jsonObject(with: header) as? [String: Any],
                       let token = status["state_token"] as? String {
                        output["expected_state_token"] = token
                    }
                    let result = ComputerUseToolResult(text: encode(output) ?? "{}")
                    return reply(id: id, result: ["content": result.jsonContent(), "isError": false])
                } catch {
                    let result = ComputerUseToolResult(text: String(describing: error), isError: true)
                    return reply(id: id, result: ["content": result.jsonContent(), "isError": true])
                }
            }
            do {
                let result = try await queue.withExclusive(kind: kind, targetPID: targetPID) {
                    await backend.invoke(name: name, arguments: arguments)
                }
                return reply(id: id, result: [
                    "content": result.jsonContent(),
                    "isError": result.isError,
                ])
            } catch is CancellationError {
                return errorReply(id: id, code: -32800, message: "computer-use call cancelled")
            } catch {
                return errorReply(id: id, code: -32000, message: String(describing: error))
            }
        default:
            return errorReply(id: id, code: -32601, message: "method not found: \(method)")
        }
    }

    public static func toolCatalog() -> [[String: Any]] {
        advertisedToolNames.map { name in
            [
                "name": name,
                "description": description(for: name),
                "inputSchema": inputSchema(for: name),
            ]
        }
    }

    private static func description(for name: String) -> String {
        switch name {
        case screenshotTool:
            return "Capture the exact target window; returned image coordinates are pixels with a top-left origin."
        case "zoom":
            return "Return an exact integral pixel crop from the target window; crop coordinates and returned image coordinates use a top-left origin."
        case leftClickTool:
            return "Click a screenshot pixel coordinate in the exact target window using Accessibility when hit-testable. If hit testing cannot identify an AX element, uses CGEvent only when that exact target window is already focused; requires a fresh screenshot state token."
        case typeTool:
            return "Type Unicode text into a settable AX-focused element in the exact background target."
        case "right_click":
            return "Right-click a screenshot pixel coordinate in the exact target window; requires a fresh screenshot state token and the exact target window must already be focused."
        case "mouse_move":
            return "Move the pointer to a screenshot pixel coordinate in the exact focused target window; requires a fresh screenshot state token."
        case "scroll":
            return "Scroll at a screenshot pixel coordinate in the exact focused target window using bounded delta_x and delta_y; requires a fresh screenshot state token."
        case "key":
            return "Send one allowlisted key with optional command/control/option/shift modifiers only while the exact target app and window are already focused; requires a fresh state token and never focuses or activates the target."
        case "cursor_position":
            return "Read the current pointer position."
        case "list_windows":
            return "List on-screen windows, optionally filtered by bundle id."
        case "get_ui_tree":
            return "Accessibility tree for a window; each actionable element has an ax_<n> id for click_element and set_value. Optional ocr auto, always or never (needs Screen Recording) appends an \"ocr:\" line of recognized text after the tree. Contains private screen text; use jev_decide for redacted Jev guidance."
        case "jev_decide":
            return "With a Jev key, ask Jev for one semantic action, WAIT, DONE or BLOCKED, plus runner-up alternatives, risk signals and a BLOCKED reason for the session LLM to weigh. Without a key, return unambiguous labeled candidates for the session LLM to decide; no Jev call. Neither path posts input. The returned token is checked again before native mutation; labels and goal text may contain private information."
        case "run_subtask":
            return "Requires a Jev key. Run a bounded loop (max_actions) that observes the window, asks Jev for one semantic step (CLICK, SET_VALUE, HOTKEY, WAIT, DONE, BLOCKED or NEEDS_INPUT), executes it natively and reobserves. Literal text comes only from inputs; secret_inputs are typed but never sent to Jev or returned. Risky controls (delete, send, purchase, close) are withheld unless in allowed_risks. Stops with SUBTASK_COMPLETE, BLOCKED, NEEDS_INPUT, NEEDS_AGENT or DRY_RUN; stops on human activity."
        case "click_element":
            return "Press an AX element in the exact background target, by element_id (ax_<n> from the get_ui_tree of the observation whose token is passed) or by role and label."
        case "set_value":
            return "Set the AX value of the unique element with this role and label in the exact background target: text for fields and combo boxes, a number for sliders, 0/1 for checkboxes, or an item title for AXPopUpButton (opened and pressed via AX). Optional submit_key ENTER or TAB is posted only if the exact window is already focused (ENTER falls back to AXConfirm). Waits for the UI to settle and returns a fresh observation with settle_ms and settled."
        case "menu_shortcut":
            return "Press the enabled menu bar item bound to a keyboard chord such as MOD+S (MOD=Cmd, CTRL, ALT, SHIFT) via AX, without focusing the window. MOD+A in a focused text field selects all text. Fails with \"no enabled menu item has this shortcut\". Returns a fresh observation with settle_ms and settled."
        case "restore_window":
            return "Explicitly restore and focus the exact PID/window; requires its fresh state token and returns a new observation. Use that new token for subsequent actions."
        case "browser_open":
            return "Open an HTTP(S) URL in a new background tab in the connected Chrome profile. Always call browser_close on this same connection when finished or on error, before another open. Never navigate a tab selected by the user."
        case "browser_snapshot":
            return "Read the owned Chrome background tab and obtain fresh element refs; may contain private page text."
        case "browser_act":
            return "Click, fill, type or scroll in the owned background tab using a fresh snapshot ref. Fails if the user selects the tab; confirm consequential actions."
        case "browser_close":
            return "Release the session and best-effort close its tab if it remains inactive and has not been selected by the user. Check closed separately from released, then verify browser_status; release alone is not proof of removal. Chrome cannot make this activity check and removal atomic, so a selection racing with removal may still be closed."
        case "browser_status":
            return "Check whether the separate Chrome extension is connected."
        case "doctor":
            return "Permission and native-backend diagnostics."
        case "cua_status":
            return "Read-only: report whether the cua CLI is installed and which cua Spaces are registered. When available, prefer a Space via the cua MCP server for tasks that do not need the user's real apps or sessions."
        default:
            return name
        }
    }

    private static func inputSchema(for name: String) -> [String: Any] {
        let targeting: [String: Any] = [
            "target_app": ["type": "string"],
            "target_pid": ["type": "integer"],
            "target_window_id": ["type": "integer"],
            "expected_state_token": ["type": "string"],
        ]
        switch name {
        case "browser_open":
            return ["type": "object", "properties": ["url": ["type": "string"]], "required": ["url"]]
        case "browser_act":
            return ["type": "object", "properties": [
                "action": ["type": "string", "enum": ["click", "fill", "type", "scroll"]],
                "ref": ["type": "string"], "text": ["type": "string"],
                "delta_x": ["type": "number"], "delta_y": ["type": "number"],
            ], "required": ["action"]]
        case "browser_snapshot", "browser_close", "browser_status", "cua_status":
            return ["type": "object", "properties": [String: Any]()]
        case screenshotTool:
            return [
                "type": "object",
                "properties": targeting,
                "required": ["target_pid", "target_window_id"],
            ]
        case "zoom":
            return [
                "type": "object",
                "properties": targeting.merging([
                    "region": ["type": "array", "description": "Integral [x,y,width,height] pixels in the full window image, top-left origin.", "items": ["type": "integer"]],
                ]) { _, new in new },
                "required": ["target_pid", "target_window_id", "region"],
            ]
        case leftClickTool:
            return [
                "type": "object",
                "properties": targeting.merging([
                    "coordinate": ["type": "array", "description": "Pixel coordinates relative to the returned screenshot or zoom image, top-left origin.", "items": ["type": "number"]],
                ]) { _, new in new },
                "required": ["target_pid", "target_window_id", "expected_state_token", "coordinate"],
            ]
        case typeTool:
            return [
                "type": "object",
                "properties": targeting.merging(["text": ["type": "string"]]) { _, new in new },
                "required": ["target_pid", "target_window_id", "expected_state_token", "text"],
            ]
        case "click_element":
            return [
                "type": "object",
                "properties": targeting.merging([
                    "role": ["type": "string"],
                    "label": ["type": "string"],
                    "element_id": ["type": "string", "description": "ax_<n> id from get_ui_tree of the observation whose token is passed; use instead of role+label."],
                ]) { _, new in new },
                "required": ["target_pid", "target_window_id", "expected_state_token"],
            ]
        case "set_value":
            return [
                "type": "object",
                "properties": targeting.merging([
                    "role": ["type": "string"],
                    "label": ["type": "string"],
                    "element_id": ["type": "string", "description": "ax_<n> id from get_ui_tree of the observation whose token is passed; use instead of role+label."],
                    "value": ["type": "string"],
                    "submit_key": ["type": "string", "enum": ["ENTER", "TAB"]],
                    "allowed_risks": ["type": "array", "items": ["type": "string", "enum": ["delete", "send", "purchase", "close"]], "description": "When present, refuse a menu item whose title names a risk category not listed."],
                ]) { _, new in new },
                "required": ["target_pid", "target_window_id", "expected_state_token", "value"],
            ]
        case "menu_shortcut":
            return [
                "type": "object",
                "properties": targeting.merging([
                    "chord": ["type": "string", "description": "Modifiers MOD (Cmd), CTRL, ALT, SHIFT joined by + with one key, e.g. MOD+S or MOD+SHIFT+Z."],
                    "allowed_risks": ["type": "array", "items": ["type": "string", "enum": ["delete", "send", "purchase", "close"]], "description": "When present, refuse a menu item whose title names a risk category not listed."],
                ]) { _, new in new },
                "required": ["target_pid", "target_window_id", "expected_state_token", "chord"],
            ]
        case "right_click", "mouse_move":
            return [
                "type": "object",
                "properties": targeting.merging([
                    "coordinate": ["type": "array", "description": "[x,y] pixels relative to the latest screenshot.", "items": ["type": "number"]],
                ]) { _, new in new },
                "required": ["target_pid", "target_window_id", "expected_state_token", "coordinate"],
            ]
        case "scroll":
            return [
                "type": "object",
                "properties": targeting.merging([
                    "coordinate": ["type": "array", "description": "[x,y] pixels relative to the latest screenshot.", "items": ["type": "number"]],
                    "delta_x": ["type": "number"], "delta_y": ["type": "number"],
                ]) { _, new in new },
                "required": ["target_pid", "target_window_id", "expected_state_token", "coordinate", "delta_x", "delta_y"],
            ]
        case "key":
            return [
                "type": "object",
                "properties": targeting.merging([
                    "key": ["type": "string", "description": "One allowlisted single-character key or Return, Tab, Space, Delete, Escape, Left, Right, Up, Down."],
                    "modifiers": ["type": "array", "items": ["type": "string", "enum": ["command", "control", "option", "shift"]]],
                ]) { _, new in new },
                "required": ["target_pid", "target_window_id", "expected_state_token", "key"],
            ]
        case "restore_window":
            return [
                "type": "object",
                "properties": targeting,
                "required": ["target_pid", "target_window_id", "expected_state_token"],
            ]
        case "list_windows":
            return [
                "type": "object",
                "properties": ["bundle_id": ["type": "string"]],
            ]
        case "jev_decide":
            return [
                "type": "object",
                "properties": targeting.merging([
                    "goal": ["type": "string", "description": "Original user goal; sanitized before sending to Jev."],
                    "allowed_risks": ["type": "array", "items": ["type": "string", "enum": ["delete", "send", "purchase", "close"]], "description": "Risk categories of controls the goal explicitly authorizes; other risky controls are withheld."],
                    "min_confidence": ["type": "number", "description": "0-1; below this Jev's answer returns NEEDS_AGENT."],
                    "min_margin": ["type": "number", "description": "0-1; minimum lead over the runner-up choice."],
                ]) { _, new in new },
                "required": ["target_pid", "target_window_id", "goal"],
            ]
        case "run_subtask":
            return [
                "type": "object",
                "properties": [
                    "target_pid": ["type": "integer"],
                    "target_window_id": ["type": "integer"],
                    "goal": ["type": "string"],
                    "verification": ["type": "array", "items": ["type": "string"], "description": "Criteria that must all be visibly true before SUBTASK_COMPLETE."],
                    "constraints": ["type": "array", "items": ["type": "string"]],
                    "inputs": ["type": "object", "description": "Named literal values (string, number or boolean) the loop may type; the model never invents text."],
                    "max_actions": ["type": "integer", "minimum": 1, "description": "Action budget; default 30."],
                    "shortcuts": ["type": "object", "description": "Extra chords such as {\"MOD+S\": \"Save the document\"} mapped to a description.", "additionalProperties": ["type": "string"]],
                    "allowed_risks": ["type": "array", "items": ["type": "string", "enum": ["delete", "send", "purchase", "close"]]],
                    "secret_inputs": ["type": "array", "items": ["type": "string"], "description": "Keys of inputs whose values are typed but redacted from Jev, results and logs."],
                    "min_confidence": ["type": "number"],
                    "min_margin": ["type": "number"],
                    "dry_run": ["type": "boolean", "description": "Stop with DRY_RUN and planned_action after the first validated decision."],
                    "log_path": ["type": "string", "description": "Append one redacted JSONL line per decision."],
                ],
                "required": ["target_pid", "target_window_id", "goal", "verification"],
            ]
        case "get_ui_tree":
            return [
                "type": "object",
                "properties": targeting.merging([
                    "ocr": ["type": "string", "enum": ["auto", "always", "never"]],
                ]) { _, new in new },
                "required": ["target_pid", "target_window_id"],
            ]
        case "doctor", "cursor_position":
            return [
                "type": "object",
                "properties": targeting,
                "required": ["target_pid", "target_window_id"],
            ]
        default:
            return [
                "type": "object",
                "properties": targeting,
                "required": ["target_pid", "target_window_id"],
            ]
        }
    }

    private static func targetPID(from arguments: [String: Any]) -> Int32? {
        ComputerUseNativeHostBackend.exactInt32(arguments["target_pid"])
    }

    private func reply(id: Any?, result: [String: Any]) -> String? {
        encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private func errorReply(id: Any?, code: Int, message: String) -> String? {
        encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])
    }

    private func encode(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }
}
