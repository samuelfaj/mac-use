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
        "doctor",
    ]

    public static let mutationTools: [String] = [
        leftClickTool,
        typeTool,
        "click_element",
    ]

    public static var advertisedToolNames: [String] {
        observationTools + mutationTools
    }

    private let queue: ComputerUseHostQueue
    private let backend: any ComputerUseToolBackend
    private let jev: JevDecision

    public init(
        queue: ComputerUseHostQueue = .shared,
        backend: any ComputerUseToolBackend = ComputerUseNativeHostBackend(),
        jev: JevDecision = JevDecision()
    ) {
        self.queue = queue
        self.backend = backend
        self.jev = jev
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
                "instructions": "mac-use controls exact macOS windows without activating them. List windows, then use jev_decide for one Jev-guided semantic step (requires JEV_API_KEY or TYPESAFE_API_KEY); it returns a proposal and fresh state token but does not act. Call click_element with the exact role, label, target and token only when authorized. Reobserve after every mutation. Native mutation yields to human activity and fails closed when safe background actions are unavailable. Jev receives filtered goal text and eligible Accessibility labels, never screenshots or field values; labels and goals may still contain private information.",
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
            let kind: ComputerUseHostQueue.Kind = Self.mutationTools.contains(name) ? .mutation : .observation
            let targetPID = Self.targetPID(from: arguments)
            if name == "jev_decide" {
                guard let goal = arguments["goal"] as? String, !goal.isEmpty else {
                    return errorReply(id: id, code: -32602, message: "goal is required")
                }
                do {
                    let observation = try await queue.withExclusive(kind: .observation, targetPID: targetPID) {
                        await backend.invoke(name: "get_ui_tree", arguments: arguments)
                    }
                    guard !observation.isError, let text = observation.content.first?.text else {
                        return reply(id: id, result: ["content": observation.jsonContent(), "isError": true])
                    }
                    let proposal = try await jev.advise(goal: goal, observation: text)
                    var output = proposal.jsonObject()
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
            return "Press an AX element at pixel coordinates relative to a screenshot or zoom image in the exact target window; requires its state token and never activates or moves the pointer."
        case typeTool:
            return "Type Unicode text into a settable AX-focused element in the exact background target."
        case "cursor_position":
            return "Read the current pointer position."
        case "list_windows":
            return "List on-screen windows, optionally filtered by bundle id."
        case "get_ui_tree":
            return "Accessibility tree for a window. Contains private screen text; use jev_decide for redacted Jev guidance."
        case "jev_decide":
            return "Ask Jev to choose one safe next semantic action, WAIT, DONE or BLOCKED from an exact window's current Accessibility tree. No input is posted. Returns a state token for subsequent native validation. Only redacted labels and goal text leave this Mac."
        case "click_element":
            return "Press an AX element by role and label in the exact background target."
        case "doctor":
            return "Permission and native-backend diagnostics."
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
                ]) { _, new in new },
                "required": ["target_pid", "target_window_id", "expected_state_token", "role", "label"],
            ]
        case "list_windows":
            return [
                "type": "object",
                "properties": ["bundle_id": ["type": "string"]],
            ]
        case "jev_decide":
            return [
                "type": "object",
                "properties": targeting.merging(["goal": ["type": "string", "description": "Original user goal; sanitized before sending to Jev."]]) { _, new in new },
                "required": ["target_pid", "target_window_id", "goal"],
            ]
        case "doctor", "get_ui_tree", "cursor_position":
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
