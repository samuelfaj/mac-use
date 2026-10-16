import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

private typealias InputNative = ComputerUseNativeHostBackend.NativePlatform
private typealias InputTarget = ComputerUseNativeHostTarget

struct InputToolsError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

struct InputKey: Equatable {
    let code: CGKeyCode
    let flags: CGEventFlags

    static let codes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43,
        "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49,
        "`": 50, "delete": 51, "escape": 53, "cmd": 55, "shift": 56,
        "option": 58, "ctrl": 59, "f1": 122, "f2": 120, "f3": 99,
        "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101,
        "f10": 109, "f11": 103, "f12": 111, "home": 115, "pageup": 116,
        "forwarddelete": 117, "end": 119, "pagedown": 121, "left": 123,
        "right": 124, "down": 125, "up": 126
    ]
    static let modifierFlags: [String: CGEventFlags] = [
        "cmd": .maskCommand, "shift": .maskShift, "option": .maskAlternate, "ctrl": .maskControl
    ]
    static func normalized(_ key: String) -> String {
        let aliases = ["command": "cmd", "meta": "cmd", "control": "ctrl", "alt": "option",
                       "enter": "return", "esc": "escape", "backspace": "delete",
                       "arrowleft": "left", "arrowright": "right", "arrowup": "up", "arrowdown": "down",
                       "spacebar": "space", "page_up": "pageup", "page_down": "pagedown",
                       "forward_delete": "forwarddelete", " ": "space", "equal": "=", "equals": "=",
                       "minus": "-", "hyphen": "-", "leftbracket": "[", "rightbracket": "]",
                       "semicolon": ";", "quote": "'", "apostrophe": "'", "backslash": "\\",
                       "comma": ",", "period": ".", "slash": "/", "grave": "`", "backtick": "`"]
        let lower = key.lowercased()
        return aliases[lower] ?? lower
    }
    static func modifiers(_ value: [String]) throws -> CGEventFlags {
        try value.reduce(CGEventFlags()) { flags, name in
            guard let flag = modifierFlags[normalized(name)] else { throw InputToolsError("invalid modifier: \(name)") }
            return flags.union(flag)
        }
    }
    static func parse(_ name: String, modifiers: [String] = []) throws -> InputKey {
        let shifted = ["!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7",
                       "*": "8", "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]",
                       ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "|": "\\", "~": "`"]
        let key = normalized(name)
        guard let code = codes[shifted[key] ?? key] else { throw InputToolsError("unknown key: \(name)") }
        var flags = try self.modifiers(modifiers)
        if shifted[key] != nil || (name.count == 1 && name != name.lowercased()) { flags.insert(.maskShift) }
        return InputKey(code: code, flags: flags)
    }
    static func hotkey(_ keys: [String]) throws -> InputKey {
        guard !keys.isEmpty else { throw InputToolsError("keys must not be empty") }
        let ordinary = keys.filter { modifierFlags[normalized($0)] == nil }
        guard ordinary.count == 1 else { throw InputToolsError("hotkey requires exactly one non-modifier key") }
        return try parse(ordinary[0], modifiers: keys.filter { modifierFlags[normalized($0)] != nil })
    }
}

struct InputNode {
    var id: String? = nil
    var role: String? = nil
    var label: String? = nil
    var value: String? = nil
    var enabled: Bool? = nil
    var children: [InputNode] = []

    static func menuIndex(title: String, nodes: [InputNode]) throws -> Int {
        let matches = nodes.indices.filter { nodes[$0].label == title }
        guard matches.count == 1 else { throw InputToolsError(matches.isEmpty ? "menu item missing: \(title)" : "menu item ambiguous: \(title)") }
        guard nodes[matches[0]].enabled == true else { throw InputToolsError("menu item disabled or unavailable: \(title)") }
        return matches[0]
    }
    var flattened: [InputNode] { [self] + children.flatMap(\.flattened) }
}

struct InputSnapshot {
    var windowExists: Bool
    var title: String?
    var nodes: [InputNode]?
    var focused: InputNode?
    var complete: Bool = true

    func evaluate(_ expect: [String: Any]) -> [String: Any] {
        var checks: [[String: Any]] = []
        func add(_ name: String, _ value: Bool?) {
            checks.append(["check": name, "result": value.map { $0 ? "pass" : "fail" } ?? "unknown"])
        }
        func matches(_ node: InputNode, _ spec: [String: Any]) -> Bool {
            if let id = spec["element_id"] as? String { return node.id == id }
            return node.role == spec["role"] as? String && node.label == spec["label"] as? String
        }
        if let wanted = expect["window_exists"] as? Bool { add("window_exists", windowExists == wanted) }
        if let text = expect["title_contains"] as? String { add("title_contains", title.map { $0.contains(text) }) }
        if let spec = expect["element_exists"] as? [String: Any] {
            let found = nodes?.contains { matches($0, spec) }
            add("element_exists", found == false && !complete ? nil : found)
        }
        if let spec = expect["element_value"] as? [String: Any] {
            let matches = nodes?.filter { matches($0, spec) }
            if let matches, matches.count == 1, let value = matches[0].value {
                add("element_value", value == spec["equals"] as? String)
            } else { add("element_value", matches?.isEmpty == true && complete ? false : nil) }
        }
        if let spec = expect["focused_element"] as? [String: Any] {
            add("focused_element", focused.map { matches($0, spec) })
        }
        let results = checks.compactMap { $0["result"] as? String }
        let result = results.contains("fail") ? "fail" : (results.contains("unknown") || results.isEmpty ? "unknown" : "pass")
        return ["result": result, "checks": checks]
    }
}

public final class InputToolsBackend: ComputerUseToolBackend, @unchecked Sendable {
    public static let observationTools = ["get_cursor_position", "verify_state"]
    public static let mutationTools = ["click", "double_click", "drag", "type_text", "press_key", "hotkey", "move_cursor", "invoke_menu"]

    struct Effects {
        var windows: () -> [ComputerUseNativeWindow] = { InputNative.listWindows(bundleID: nil) }
        var activity: (ComputerUseNativeHostTarget) -> ComputerUseNativeUserActivity = { InputNative.userActivity(target: $0) }
        var frontmost: () -> Int32? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        var activate: (Int32) -> Bool = { NSRunningApplication(processIdentifier: $0)?.activate(options: []) ?? false }
        var raise: (ComputerUseNativeHostTarget) -> Bool = { target in
            guard let window = InputNative.exactAXWindow(target: target) else { return false }
            return AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
        }
        var scale: (CGRect) -> Double = { bounds in
            var displays = [CGDirectDisplayID](repeating: 0, count: 16)
            var count: UInt32 = 0
            guard CGGetDisplaysWithRect(bounds, 16, &displays, &count) == .success, count > 0,
                  let mode = CGDisplayCopyDisplayMode(displays[0]), mode.width > 0 else { return 1 }
            return Double(mode.pixelWidth) / Double(mode.width)
        }
        var post: (CGEvent, Int32, Bool) -> Void = { event, pid, foreground in
            if foreground { event.post(tap: .cghidEventTap) } else { event.postToPid(pid) }
        }
        var sleep: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }
        var cursor: () -> CGPoint? = { CGEvent(source: nil)?.location }
        var warp: (CGPoint) -> Bool = { CGWarpMouseCursorPosition($0) == .success }
        var axAction: (ComputerUseNativeHostTarget, String, String) -> Bool = { target, id, action in
            guard let element = InputNative.element(target: target, id: id),
                  InputNative.actionNames(of: element).contains(action) else { return false }
            return AXUIElementPerformAction(element, action as CFString) == .success
        }
        var elementPoint: (ComputerUseNativeHostTarget, String) -> CGPoint? = { target, id in
            guard let element = InputNative.element(target: target, id: id),
                  let position = InputNative.attribute(kAXPositionAttribute as CFString, from: element),
                  let size = InputNative.attribute(kAXSizeAttribute as CFString, from: element),
                  CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero
            var dimensions = CGSize.zero
            guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
                  AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
            return CGPoint(x: point.x + dimensions.width / 2, y: point.y + dimensions.height / 2)
        }
        var insert: (ComputerUseNativeHostTarget, String?, String) -> Bool = { target, id, text in
            let element: AXUIElement?
            if let id { element = InputNative.element(target: target, id: id) }
            else if let window = InputNative.exactAXWindow(target: target),
                    let raw = InputNative.attribute(kAXFocusedUIElementAttribute as CFString, from: AXUIElementCreateApplication(target.pid)),
                    let focused = InputNative.axElement(from: raw), InputProduction.contains(focused, in: window) {
                element = focused
            } else { element = nil }
            guard let element else { return false }
            return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
        }
        var focusElement: (ComputerUseNativeHostTarget, String) -> Bool = { target, id in
            guard let element = InputNative.element(target: target, id: id) else { return false }
            return AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
        }
        var menu: (ComputerUseNativeHostTarget, [String], () throws -> Void) throws -> Void = InputProduction.menu
        var snapshot: (ComputerUseNativeHostTarget) -> InputSnapshot = InputProduction.snapshot
    }

    private let effects: Effects
    private let jev: JevDecision
    private let jevAvailable: @Sendable () -> Bool
    public init(transport: any JevTransport = TypeSafeJevTransport(),
                jevAvailable: @escaping @Sendable () -> Bool = { TypeSafeJevTransport.isConfigured() }) {
        effects = Effects()
        jev = JevDecision(transport: transport)
        self.jevAvailable = jevAvailable
    }
    init(effects: Effects, transport: any JevTransport = TypeSafeJevTransport(),
         jevAvailable: @escaping @Sendable () -> Bool = { TypeSafeJevTransport.isConfigured() }) {
        self.effects = effects
        jev = JevDecision(transport: transport)
        self.jevAvailable = jevAvailable
    }

    public static func description(for name: String) -> String? {
        switch name {
        case "click": return "Click an AX element or window-local screenshot pixel. Background uses AX or pid-directed events without activation; foreground temporarily activates and restores prior app. Desktop scope uses screen points."
        case "double_click": return "Open an AX element with AXOpen when available, otherwise double-click its center or supplied window-local screenshot pixels."
        case "drag": return "Drag between window-local screenshot pixels with timed mouse events; background by default."
        case "type_text": return "Insert selected text through AX, falling back to Unicode keyboard events. Desktop scope types into frontmost app."
        case "press_key": return "Press a named key with optional modifiers using background pid events or temporary foreground delivery."
        case "hotkey": return "Press one key with modifiers from keys, for example [cmd,c]."
        case "move_cursor": return "Window scope reports an overlay position only, without moving real pointer. Desktop scope warps real pointer in screen points."
        case "get_cursor_position": return "Return real cursor position in screen points."
        case "invoke_menu": return "Walk app AX menu titles one level at a time, refusing missing, ambiguous or disabled items; press final item without activation."
        case "verify_state": return "Evaluate deterministic window checks plus expect.criteria (1-8 natural-language checks, at most 200 characters each). Prefer text-only, cheap Jev verification before screenshots: one Jev request over filtered AX labels/roles and scrubbed title, never field values. No key returns unknown with filtered evidence for the session LLM. Return pass, fail or unknown per check."
        default: return nil
        }
    }

    public static func inputSchema(for name: String) -> [String: Any]? {
        guard (observationTools + mutationTools).contains(name) else { return nil }
        let string: [String: Any] = ["type": "string"]
        let number: [String: Any] = ["type": "number"]
        let modifiers: [String: Any] = ["type": "array", "items": ["type": "string", "enum": ["cmd", "shift", "option", "ctrl"]]]
        var properties: [String: Any] = [:]
        var required: [String] = []
        if name != "get_cursor_position" {
            properties = ["target_pid": ["type": "integer", "minimum": 1], "target_window_id": ["type": "integer", "minimum": 1]]
            required = ["target_pid", "target_window_id"]
        }
        let desktop = ["click", "press_key", "type_text", "move_cursor"].contains(name)
        if desktop { properties["scope"] = ["type": "string", "enum": ["window", "desktop"], "default": "window"] }
        if mutationTools.contains(name) && name != "invoke_menu" && name != "move_cursor" {
            properties["delivery_mode"] = ["type": "string", "enum": ["background", "foreground"], "default": "background"]
        }
        switch name {
        case "click", "double_click":
            properties.merge(["element_id": string, "x": number, "y": number,
                              "button": ["type": "string", "enum": ["left", "right", "middle"]],
                              "count": ["type": "integer", "minimum": 1, "maximum": 10],
                              "modifier": modifiers,
                              "action": ["type": "string", "enum": ["press", "show_menu", "confirm", "cancel", "open"]]]) { _, new in new }
        case "drag":
            for key in ["from_x", "from_y", "to_x", "to_y"] { properties[key] = number; required.append(key) }
            properties["duration_ms"] = ["type": "number", "minimum": 0, "maximum": 60000, "default": 500]
        case "type_text":
            properties["text"] = string; properties["element_id"] = string; required.append("text")
            properties["delay_ms"] = ["type": "number", "minimum": 0, "maximum": 1000, "default": 0]
        case "press_key": properties["key"] = string; properties["modifiers"] = modifiers; required.append("key")
        case "hotkey": properties["keys"] = ["type": "array", "items": string, "minItems": 1]; required.append("keys")
        case "move_cursor": properties["x"] = number; properties["y"] = number; required += ["x", "y"]
        case "invoke_menu": properties["path"] = ["type": "array", "items": string, "minItems": 1]; required.append("path")
        case "verify_state":
            let selector: [String: Any] = ["type": "object", "properties": ["role": string, "label": string], "required": ["role", "label"], "additionalProperties": false]
            let value: [String: Any] = ["type": "object", "properties": ["element_id": string, "role": string, "label": string, "equals": string], "required": ["equals"], "oneOf": [["required": ["element_id"]], ["required": ["role", "label"]]], "additionalProperties": false]
            properties["expect"] = ["type": "object", "minProperties": 1, "additionalProperties": false,
                                    "properties": ["criteria": ["type": "array", "minItems": 1, "maxItems": 8, "items": ["type": "string", "minLength": 1, "maxLength": 200]], "title_contains": string, "element_exists": selector, "element_value": value,
                                                   "focused_element": selector, "window_exists": ["type": "boolean"]]]
            required.append("expect")
        default: break
        }
        var schema: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
        if desktop {
            schema["required"] = required.filter { !["target_pid", "target_window_id"].contains($0) }
            schema["anyOf"] = [["properties": ["scope": ["const": "desktop"]], "required": ["scope"]], ["required": ["target_pid", "target_window_id"]]]
        } else { schema["required"] = required }
        if name == "click" || name == "double_click" {
            schema["oneOf"] = [["required": ["element_id"], "not": ["anyOf": [["required": ["x"]], ["required": ["y"]]]]], ["required": ["x", "y"], "not": ["required": ["element_id"]]]]
        }
        return schema
    }

    public func invoke(name: String, arguments: [String: Any]) async -> ComputerUseToolResult {
        do {
            let result = try await perform(name: name, arguments: arguments)
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            return ComputerUseToolResult(text: String(decoding: data, as: UTF8.self))
        } catch { return ComputerUseToolResult(text: String(describing: error), isError: true) }
    }

    private func perform(name: String, arguments a: [String: Any]) async throws -> [String: Any] {
        try Self.validate(name: name, arguments: a)
        if name == "get_cursor_position" {
            guard let point = effects.cursor() else { throw InputToolsError("cursor unavailable") }
            return ["x": point.x, "y": point.y, "coordinate_space": "screen_points"]
        }
        let desktop = a["scope"] as? String == "desktop"
        let windows = effects.windows()
        let target: InputTarget
        if desktop {
            guard let pid = effects.frontmost() else { throw InputToolsError("frontmost application unavailable") }
            target = windows.first { $0.target.pid == pid }?.target ?? InputTarget(pid: pid, windowID: 0)
        } else {
            target = InputTarget(pid: Int32((a["target_pid"] as! NSNumber).int64Value), windowID: UInt32((a["target_window_id"] as! NSNumber).int64Value))
        }
        if name == "verify_state" {
            let snapshot = effects.snapshot(target)
            let expect = a["expect"] as! [String: Any]
            var result = snapshot.evaluate(expect)
            if let criteria = expect["criteria"] as? [String] {
                let labels = (snapshot.nodes ?? []).compactMap { node -> (role: String, label: String)? in
                    guard let role = node.role, role != "AXSecureTextField", let label = node.label else { return nil }
                    return (role, label)
                }
                let checks: [[String: Any]]
                do {
                    checks = try await jev.verify(criteria: criteria, title: snapshot.title, labels: labels,
                                                  available: jevAvailable(), secrets: (snapshot.nodes ?? []).compactMap(\.value))
                } catch {
                    checks = criteria.map { ["criterion": $0, "result": "unknown", "reason": "Jev verification unavailable or invalid"] }
                }
                let combined = (result["checks"] as? [[String: Any]] ?? []) + checks
                let results = combined.compactMap { $0["result"] as? String }
                result["checks"] = combined
                result["result"] = results.contains("fail") ? "fail" : (results.contains("unknown") ? "unknown" : "pass")
            }
            return result
        }
        let window = windows.first { $0.target == target }
        guard desktop || window != nil else { throw InputToolsError("target window unavailable") }
        func guardActivity() throws {
            if effects.activity(target) == .human { throw InputToolsError("human_activity: target is in use") }
        }
        try guardActivity()
        let foreground = desktop || a["delivery_mode"] as? String == "foreground"
        let previous = effects.frontmost()
        let temporaryActivation = foreground && !desktop
        defer {
            if temporaryActivation {
                effects.sleep(0.15)
                if let previous, effects.frontmost() == target.pid,
                   effects.activity(target) != .human { _ = effects.activate(previous) }
            }
        }
        if temporaryActivation {
            guard effects.activate(target.pid), effects.raise(target) else { throw InputToolsError("foreground activation or AXRaise failed") }
            effects.sleep(0.15)
            try guardActivity()
        }
        func point(_ x: String, _ y: String) throws -> CGPoint {
            let px = (a[x] as! NSNumber).doubleValue
            let py = (a[y] as! NSNumber).doubleValue
            if desktop { return CGPoint(x: px, y: py) }
            guard let window else { throw InputToolsError("target window unavailable") }
            let scale = effects.scale(window.bounds)
            guard scale.isFinite, scale > 0, px >= 0, py >= 0,
                  px < window.bounds.width * scale, py < window.bounds.height * scale else {
                throw InputToolsError("coordinates outside window screenshot pixels")
            }
            return CGPoint(x: window.bounds.minX + px / scale, y: window.bounds.minY + py / scale)
        }
        func post(_ event: CGEvent?) throws {
            try guardActivity()
            if foreground, effects.frontmost() != target.pid { throw InputToolsError("foreground application changed during delivery") }
            guard let event else { throw InputToolsError("CGEvent creation failed") }
            event.setIntegerValueField(.eventSourceUserData, value: ComputerUseNativeActivityMonitor.syntheticEventUserData)
            effects.post(event, target.pid, foreground)
        }
        func keyboard(_ key: InputKey) throws {
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: key.code, keyDown: down)
                event?.flags = key.flags
                try post(event)
            }
        }
        func mouse(_ location: CGPoint, count: Int, button: String, flags: CGEventFlags) throws {
            let cgButton: CGMouseButton = button == "right" ? .right : (button == "middle" ? .center : .left)
            let down: CGEventType = button == "right" ? .rightMouseDown : (button == "middle" ? .otherMouseDown : .leftMouseDown)
            let up: CGEventType = button == "right" ? .rightMouseUp : (button == "middle" ? .otherMouseUp : .leftMouseUp)
            for index in 1...count {
                for type in [down, up] {
                    let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: cgButton)
                    event?.flags = flags
                    event?.setIntegerValueField(.mouseEventClickState, value: Int64(index))
                    try post(event)
                }
                if index < count { effects.sleep(0.04) }
            }
        }
        switch name {
        case "click", "double_click":
            let id = a["element_id"] as? String
            let actions = ["press": "AXPress", "show_menu": "AXShowMenu", "confirm": "AXConfirm", "cancel": "AXCancel", "open": "AXOpen"]
            if let id {
                try guardActivity()
                let action = name == "double_click" ? "AXOpen" : actions[a["action"] as? String ?? "press"]!
                if effects.axAction(target, id, action) { return ["ok": true, "delivery": "accessibility"] }
                if name != "double_click" { throw InputToolsError("AX action unavailable or failed: \(action)") }
            }
            let location: CGPoint
            if let id {
                guard let center = effects.elementPoint(target, id) else { throw InputToolsError("element bounds unavailable") }
                location = center
            } else { location = try point("x", "y") }
            try mouse(location, count: name == "double_click" ? 2 : ((a["count"] as? NSNumber)?.intValue ?? 1), button: a["button"] as? String ?? "left", flags: InputKey.modifiers(a["modifier"] as? [String] ?? []))
        case "drag":
            let start = try point("from_x", "from_y"), end = try point("to_x", "to_y")
            let duration = ((a["duration_ms"] as? NSNumber)?.doubleValue ?? 500) / 1000
            let steps = max(1, Int(ceil(duration * 60)))
            try post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left))
            for step in 1...steps {
                effects.sleep(duration / Double(steps))
                let fraction = Double(step) / Double(steps)
                try post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction), mouseButton: .left))
            }
            try post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left))
        case "type_text":
            let text = a["text"] as! String
            try guardActivity()
            if !desktop && effects.insert(target, a["element_id"] as? String, text) { return ["ok": true, "delivery": "accessibility"] }
            if let id = a["element_id"] as? String {
                try guardActivity()
                guard effects.focusElement(target, id) else { throw InputToolsError("element unavailable or cannot receive keyboard fallback") }
            }
            let delay = ((a["delay_ms"] as? NSNumber)?.doubleValue ?? 0) / 1000
            for character in text {
                let units = Array(String(character).utf16)
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                    units.withUnsafeBufferPointer { buffer in event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: buffer.baseAddress) }
                    try post(event)
                }
                if delay > 0 { effects.sleep(delay) }
            }
        case "press_key": try keyboard(InputKey.parse(a["key"] as! String, modifiers: a["modifiers"] as? [String] ?? []))
        case "hotkey": try keyboard(InputKey.hotkey(a["keys"] as! [String]))
        case "move_cursor":
            let location = try point("x", "y")
            if desktop {
                try guardActivity()
                guard effects.warp(location) else { throw InputToolsError("cursor warp failed") }
            }
            return ["ok": true, "x": location.x, "y": location.y, "coordinate_space": "screen_points", "pointer_moved": desktop, "overlay_hint": !desktop]
        case "invoke_menu": try effects.menu(target, a["path"] as! [String], guardActivity)
        default: throw InputToolsError("unknown input tool: \(name)")
        }
        return ["ok": true, "delivery": foreground ? "foreground" : "background"]
    }

    static func validate(name: String, arguments a: [String: Any]) throws {
        guard let schema = inputSchema(for: name), let properties = schema["properties"] as? [String: Any] else { throw InputToolsError("unknown input tool: \(name)") }
        for key in a.keys where properties[key] == nil { throw InputToolsError("unknown argument: \(key)") }
        func string(_ key: String, required: Bool = false) throws {
            if let value = a[key] { guard value is String else { throw InputToolsError("\(key) must be a string") } }
            else if required { throw InputToolsError("\(key) required") }
        }
        func number(_ key: String, required: Bool = false, integer: Bool = false, min: Double = -.infinity, max: Double = .infinity) throws {
            guard let raw = a[key] else { if required { throw InputToolsError("\(key) required") }; return }
            guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
                  value.doubleValue >= min, value.doubleValue <= max,
                  !integer || value.doubleValue.rounded() == value.doubleValue else { throw InputToolsError("invalid \(key)") }
        }
        func strings(_ key: String, required: Bool = false) throws {
            guard let value = a[key] else { if required { throw InputToolsError("\(key) required") }; return }
            guard let items = value as? [String], items.allSatisfy({ !$0.isEmpty }) else { throw InputToolsError("\(key) must be strings") }
        }
        for key in ["scope", "delivery_mode", "element_id", "button", "action", "text", "key"] where a[key] != nil { try string(key) }
        if let scope = a["scope"] as? String, !["window", "desktop"].contains(scope) { throw InputToolsError("invalid scope") }
        if let mode = a["delivery_mode"] as? String, !["background", "foreground"].contains(mode) { throw InputToolsError("invalid delivery_mode") }
        let desktop = a["scope"] as? String == "desktop"
        if name != "get_cursor_position" {
            try number("target_pid", required: !desktop, integer: true, min: 1, max: Double(Int32.max))
            try number("target_window_id", required: !desktop, integer: true, min: 1, max: Double(UInt32.max))
        }
        if let id = a["element_id"] as? String {
            guard !desktop, NativeElementID.index(id) != nil else { throw InputToolsError("invalid element_id or desktop element addressing") }
        }
        for key in ["x", "y", "from_x", "from_y", "to_x", "to_y"] where a[key] != nil { try number(key) }
        for key in ["modifier", "modifiers"] where a[key] != nil {
            try strings(key)
            _ = try InputKey.modifiers(a[key] as! [String])
        }
        switch name {
        case "click", "double_click":
            if a["element_id"] == nil { try number("x", required: true); try number("y", required: true) }
            else if a["x"] != nil || a["y"] != nil { throw InputToolsError("element_id and pixels are mutually exclusive") }
            if let button = a["button"] as? String, !["left", "right", "middle"].contains(button) { throw InputToolsError("invalid button") }
            if let action = a["action"] as? String, !["press", "show_menu", "confirm", "cancel", "open"].contains(action) { throw InputToolsError("invalid action") }
            if a["action"] != nil && a["element_id"] == nil { throw InputToolsError("action requires element_id") }
            try number("count", integer: true, min: 1, max: 10)
        case "drag":
            for key in ["from_x", "from_y", "to_x", "to_y"] { try number(key, required: true) }
            try number("duration_ms", min: 0, max: 60000)
        case "type_text": try string("text", required: true); try number("delay_ms", min: 0, max: 1000)
        case "press_key": try string("key", required: true); _ = try InputKey.parse(a["key"] as! String, modifiers: a["modifiers"] as? [String] ?? [])
        case "hotkey": try strings("keys", required: true); _ = try InputKey.hotkey(a["keys"] as! [String])
        case "move_cursor": try number("x", required: true); try number("y", required: true)
        case "invoke_menu":
            try strings("path", required: true)
            guard !(a["path"] as! [String]).isEmpty else { throw InputToolsError("path must not be empty") }
        case "verify_state":
            guard let expect = a["expect"] as? [String: Any], !expect.isEmpty else { throw InputToolsError("expect must be a nonempty object") }
            for (key, raw) in expect {
                switch key {
                case "window_exists":
                    guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw InputToolsError("window_exists must be boolean") }
                case "criteria":
                    guard let criteria = raw as? [String], (1...8).contains(criteria.count),
                          criteria.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 200 }) else {
                        throw InputToolsError("criteria must contain 1-8 nonempty strings of at most 200 characters")
                    }
                case "title_contains": guard raw is String else { throw InputToolsError("title_contains must be string") }
                case "element_exists", "element_value", "focused_element":
                    guard let spec = raw as? [String: Any] else { throw InputToolsError("\(key) must be object") }
                    let value = key == "element_value"
                    let allowed = value ? ["element_id", "role", "label", "equals"] : ["role", "label"]
                    guard spec.keys.allSatisfy({ allowed.contains($0) }), spec.values.allSatisfy({ $0 is String }),
                          !value || spec["equals"] is String else { throw InputToolsError("invalid \(key) selector") }
                    if let id = spec["element_id"] as? String {
                        guard value, NativeElementID.index(id) != nil, spec["role"] == nil, spec["label"] == nil else { throw InputToolsError("invalid element_id selector") }
                    } else {
                        guard spec["role"] is String, spec["label"] is String else { throw InputToolsError("selector requires role and label") }
                    }
                default: throw InputToolsError("unknown expectation: \(key)")
                }
            }
        default: break
        }
    }
}

private enum InputProduction {
    static func contains(_ wanted: AXUIElement, in root: AXUIElement, depth: Int = 0) -> Bool {
        if CFEqual(wanted, root) { return true }
        guard depth < NativeElementID.maximumDepth else { return false }
        return InputNative.children(of: root).contains { contains(wanted, in: $0, depth: depth + 1) }
    }

    static func node(_ element: AXUIElement, id: String? = nil) -> InputNode {
        let label = InputNative.title(of: element)
            ?? InputNative.attribute(kAXDescriptionAttribute as CFString, from: element) as? String
        let value = InputNative.attribute(kAXValueAttribute as CFString, from: element)
        return InputNode(id: id,
                         role: InputNative.attribute(kAXRoleAttribute as CFString, from: element) as? String,
                         label: label,
                         value: (value as? String) ?? (value as? NSNumber)?.stringValue,
                         enabled: InputNative.attribute(kAXEnabledAttribute as CFString, from: element) as? Bool)
    }

    static func menu(target: InputTarget, path: [String], guardActivity: () throws -> Void) throws {
        let app = AXUIElementCreateApplication(target.pid)
        guard let raw = InputNative.attribute(kAXMenuBarAttribute as CFString, from: app),
              let bar = InputNative.axElement(from: raw) else { throw InputToolsError("AXMenuBar unavailable") }
        var level = InputNative.children(of: bar)
        for (index, title) in path.enumerated() {
            let selected = level[try InputNode.menuIndex(title: title, nodes: level.map { node($0) })]
            try guardActivity()
            guard AXUIElementPerformAction(selected, kAXPressAction as CFString) == .success else { throw InputToolsError("menu AXPress failed: \(title)") }
            if index + 1 < path.count {
                let menus = InputNative.children(of: selected).filter {
                    InputNative.attribute(kAXRoleAttribute as CFString, from: $0) as? String == kAXMenuRole as String
                }
                guard menus.count == 1 else { throw InputToolsError("menu submenu missing or ambiguous: \(title)") }
                level = InputNative.children(of: menus[0])
            }
        }
    }

    static func snapshot(target: InputTarget) -> InputSnapshot {
        let window = InputNative.listWindows(bundleID: nil).first { $0.target == target }
        guard let window else { return InputSnapshot(windowExists: false, title: nil, nodes: nil, focused: nil) }
        guard let root = InputNative.exactAXWindow(target: target) else { return InputSnapshot(windowExists: true, title: window.title, nodes: nil, focused: nil) }
        var nodes: [InputNode] = []
        var complete = true
        var focused: InputNode?
        let focusedRaw = InputNative.attribute(kAXFocusedUIElementAttribute as CFString, from: AXUIElementCreateApplication(target.pid))
        let focusedElement = focusedRaw.flatMap { InputNative.axElement(from: $0) }
        func visit(_ element: AXUIElement, depth: Int) {
            guard depth <= NativeElementID.maximumDepth, nodes.count < NativeElementID.maximumNodes else { complete = false; return }
            let item = node(element, id: "ax_\(nodes.count)")
            nodes.append(item)
            if let focusedElement, CFEqual(element, focusedElement) { focused = item }
            for child in InputNative.children(of: element) { visit(child, depth: depth + 1) }
        }
        visit(root, depth: 0)
        return InputSnapshot(windowExists: true, title: window.title, nodes: nodes, focused: focused, complete: complete)
    }
}
