import AppKit
import CoreGraphics
import Foundation
import XCTest
@testable import MacUse

private final class RestoreWindowTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var restored: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

private final class OCRRecordingBackend: ComputerUseToolBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var modes: [String?] = []
    let observation: String
    init(observation: String) { self.observation = observation }
    var ocrModes: [String?] { lock.lock(); defer { lock.unlock() }; return modes }
    func invoke(name: String, arguments: [String: Any]) async -> ComputerUseToolResult {
        lock.lock(); modes.append(arguments["ocr"] as? String); lock.unlock()
        return ComputerUseToolResult(text: observation)
    }
}

private final class NativeWindowSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let first: ComputerUseNativeWindow
    private let subsequent: ComputerUseNativeWindow
    private var count = 0

    init(first: ComputerUseNativeWindow, subsequent: ComputerUseNativeWindow) {
        self.first = first
        self.subsequent = subsequent
    }

    func next() -> [ComputerUseNativeWindow] {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return [count == 1 ? first : subsequent]
    }
}

private final class NativeInputTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var focused = false
    private var recorded: [(String, [Double])] = []

    var isFocused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return focused }
        set { lock.lock(); focused = newValue; lock.unlock() }
    }

    var actions: [(String, [Double])] {
        lock.lock(); defer { lock.unlock() }; return recorded
    }

    func record(_ name: String, _ coordinate: [Double]) {
        lock.lock(); recorded.append((name, coordinate)); lock.unlock()
    }
}

private struct SemanticSearchTestNode {
    let role: String?
    let title: String?
    let description: String?
    let children: [SemanticSearchTestNode]?
}

final class NativeMCPTests: XCTestCase {
    func testRestoreDoesNotActivateAppWhenExactWindowFocusSetupFails() {
        var activated = false
        var rolledBack = false
        let restored = NativeWindowRestoreSequence.run(
            wasMinimized: true,
            unminimize: { true },
            focusExactWindow: { false },
            activateApp: { activated = true; return true },
            rollbackMinimized: { rolledBack = true }
        )
        XCTAssertFalse(restored)
        XCTAssertFalse(activated)
        XCTAssertTrue(rolledBack)
    }

    func testSemanticTargetSearchRequiresOneMatchAndCompleteTree() {
        let match = SemanticSearchTestNode(role: "AXButton", title: "Save", description: nil, children: [])
        let attributes: (SemanticSearchTestNode) -> (role: String?, title: String?, description: String?)? = { node in
            guard node.description != "unreadable" else { return nil }
            return (node.role, node.title, node.description)
        }
        let root = SemanticSearchTestNode(role: "AXWindow", title: nil, description: nil, children: [match])
        let unique = NativeSemanticTargetSearch.uniqueMatch(
            root: root, role: "AXButton", label: "Save",
            attributesOf: attributes, childrenOf: \.children
        )
        XCTAssertEqual(unique?.title, "Save")

        let duplicate = SemanticSearchTestNode(role: "AXButton", title: "Save", description: nil, children: [])
        let duplicateRoot = SemanticSearchTestNode(role: "AXWindow", title: nil, description: nil, children: [match, duplicate])
        XCTAssertNil(NativeSemanticTargetSearch.uniqueMatch(
            root: duplicateRoot, role: "AXButton", label: "Save",
            attributesOf: attributes, childrenOf: \.children
        ))

        var deepTree = match
        for _ in 0..<32 {
            deepTree = SemanticSearchTestNode(role: "AXGroup", title: nil, description: nil, children: [deepTree])
        }
        XCTAssertNil(NativeSemanticTargetSearch.uniqueMatch(
            root: deepTree, role: "AXButton", label: "Save",
            attributesOf: attributes, childrenOf: \.children
        ))

        let unreadableAttributes = SemanticSearchTestNode(role: "AXButton", title: nil, description: "unreadable", children: [])
        let partialAttributes = SemanticSearchTestNode(role: "AXWindow", title: nil, description: nil, children: [match, unreadableAttributes])
        XCTAssertNil(NativeSemanticTargetSearch.uniqueMatch(
            root: partialAttributes, role: "AXButton", label: "Save",
            attributesOf: attributes, childrenOf: \.children
        ))

        let unreadableChildren = SemanticSearchTestNode(role: "AXGroup", title: nil, description: nil, children: nil)
        let partialChildren = SemanticSearchTestNode(role: "AXWindow", title: nil, description: nil, children: [match, unreadableChildren])
        XCTAssertNil(NativeSemanticTargetSearch.uniqueMatch(
            root: partialChildren, role: "AXButton", label: "Save",
            attributesOf: attributes, childrenOf: \.children
        ))
    }

    private func testCapture() throws -> ComputerUseNativeCapture {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 100,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        return ComputerUseNativeCapture(data: png.base64EncodedString(), mimeType: "image/png")
    }

    private func observation(_ result: ComputerUseToolResult) throws -> [String: Any] {
        let text = try XCTUnwrap(result.content.first?.text)
        let jsonLine = text.components(separatedBy: "\n").first(where: { $0.hasPrefix("{") }) ?? text
        let data = try XCTUnwrap(jsonLine.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func response(_ line: String, from handler: ManagedComputerUseMCP) async throws -> [String: Any] {
        let reply = await handler.handle(line)
        let text = try XCTUnwrap(reply)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testInitializeAdvertisesNativeAndBrowserTools() async throws {
        let handler = ManagedComputerUseMCP()
        let message = try await response(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#, from: handler)
        let result = try XCTUnwrap(message["result"] as? [String: Any])
        let server = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(server["name"] as? String, "mac-use")
        XCTAssertEqual(result["protocolVersion"] as? String, "2024-11-05")
        let instructions = try XCTUnwrap(result["instructions"] as? String)
        XCTAssertTrue(instructions.contains("state token"))
        XCTAssertTrue(instructions.contains("browser_open"))
        let notificationReply = await handler.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(notificationReply)
    }

    func testToolsListContainsNativeAndBrowserTools() async throws {
        let handler = ManagedComputerUseMCP()
        let message = try await response(#"{"jsonrpc":"2.0","id":"tools","method":"tools/list"}"#, from: handler)
        let result = try XCTUnwrap(message["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }), Set([
            "screenshot", "zoom", "cursor_position", "list_windows", "get_ui_tree", "jev_decide", "doctor", "cua_status",
            "left_click", "type", "click_element", "set_value", "menu_shortcut", "restore_window", "right_click", "mouse_move", "scroll", "key",
            "browser_open", "browser_snapshot", "browser_act", "browser_close", "browser_status", "run_subtask",
        ]))
        for tool in tools {
            XCTAssertNotNil(tool["inputSchema"] as? [String: Any])
        }
        func required(_ name: String) -> Set<String> {
            let schema = tools.first { $0["name"] as? String == name }?["inputSchema"] as? [String: Any]
            return Set(schema?["required"] as? [String] ?? [])
        }
        XCTAssertEqual(required("set_value"), ["target_pid", "target_window_id", "expected_state_token", "value"])
        XCTAssertEqual(required("menu_shortcut"), ["target_pid", "target_window_id", "expected_state_token", "chord"])
    }

    func testJevDecidePassesAllowedRisksAndForcesOCRNever() async throws {
        let observation = """
        {"user_activity":"none","is_on_screen":true,"is_minimized":false,"permissions":{"accessibility":true},"state_token":"t"}
        ui_tree: {"role":"AXWindow","children":[{"role":"AXButton","title":"Save"},{"role":"AXButton","title":"Delete"}]}
        ocr: [{"text":"Delete everything"}]
        """
        let lock = FileManager.default.temporaryDirectory.appendingPathComponent("mac-use-tests-\(UUID().uuidString)/computer-use.lock")
        let backend = OCRRecordingBackend(observation: observation)
        let handler = ManagedComputerUseMCP(
            queue: ComputerUseHostQueue(lockURL: lock), backend: backend, jevAvailable: { false })
        func call(_ risks: String) async throws -> (text: String, isError: Bool) {
            let line = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"jev_decide","arguments":{"goal":"Save","target_pid":42,"target_window_id":7,"ocr":"always","allowed_risks":"# + risks + "}}}"
            let message = try await response(line, from: handler)
            let result = try XCTUnwrap(message["result"] as? [String: Any])
            let parts = try XCTUnwrap(result["content"] as? [[String: Any]])
            return (try XCTUnwrap(parts.first?["text"] as? String), result["isError"] as? Bool ?? false)
        }
        func labels(_ text: String) throws -> [String] {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            return (json["candidates"] as? [[String: String]] ?? []).compactMap { $0["label"] }
        }
        let withoutRisk = try await call("[]")
        XCTAssertEqual(try labels(withoutRisk.text), ["Save"])
        let allowed = try await call(#"["delete"]"#)
        XCTAssertEqual(try labels(allowed.text), ["Save", "Delete"])
        let bogus = try await call(#"["bogus"]"#)
        XCTAssertTrue(bogus.isError)
        XCTAssertTrue(bogus.text.contains("allowed_risks"))
        XCTAssertEqual(backend.ocrModes, ["never", "never"])
    }

    func testSetValueAndMenuShortcutRejectStaleTokenBeforeTouchingAX() async throws {
        let target = ComputerUseNativeHostTarget(pid: 42, windowID: 7)
        let window = ComputerUseNativeWindow(target: target, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let backend = ComputerUseNativeHostBackend(hooks: .init(
            listWindows: { _ in [window] },
            userActivity: { _ in .none },
            activityMonitorAvailable: { true },
            accessibilityPermission: { true },
            axTargetAvailable: { _ in true },
            screenCapturePermission: { true },
            capture: { _ in .unavailable("offline") },
            uiTree: { _ in "tree" },
            setValue: { _, _, _, _, _ in XCTFail("stale token must not set a value"); return .applied },
            menuShortcut: { _, _, _ in XCTFail("stale token must not press a menu"); return .applied }
        ))
        let value = await backend.invoke(name: "set_value", arguments: [
            "target_pid": 42, "target_window_id": 7, "expected_state_token": "stale",
            "role": "AXTextField", "label": "Name", "value": "x",
        ])
        XCTAssertTrue(value.isError)
        XCTAssertTrue(value.content[0].text?.contains("stale_state_token") == true)
        let menu = await backend.invoke(name: "menu_shortcut", arguments: [
            "target_pid": 42, "target_window_id": 7, "expected_state_token": "stale", "chord": "MOD+S",
        ])
        XCTAssertTrue(menu.isError)
        XCTAssertTrue(menu.content[0].text?.contains("stale_state_token") == true)
    }

    func testSetValueAndMenuShortcutReportSettleAndFreshObservation() async throws {
        let target = ComputerUseNativeHostTarget(pid: 42, windowID: 7)
        let window = ComputerUseNativeWindow(target: target, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let backend = ComputerUseNativeHostBackend(hooks: .init(
            listWindows: { _ in [window] },
            userActivity: { _ in .none },
            activityMonitorAvailable: { true },
            accessibilityPermission: { true },
            axTargetAvailable: { _ in true },
            screenCapturePermission: { true },
            capture: { _ in .unavailable("offline") },
            uiTree: { _ in "tree" },
            setValue: { _, role, label, value, _ in
                role == "AXTextField" && label == "Name" && value == "x" ? .applied : .failed("unexpected")
            },
            menuShortcut: { _, chord, _ in chord.key == "S" ? .applied : .noMenuItem },
            settleWatcher: { _ in NativeSettleWatcher(wait: { .init(settled: false, elapsedMilliseconds: 2000) }) }
        ))
        let observed = await backend.invoke(name: "doctor", arguments: ["target_pid": 42, "target_window_id": 7])
        let token = try XCTUnwrap(try observation(observed)["state_token"] as? String)
        let base: [String: Any] = ["target_pid": 42, "target_window_id": 7, "expected_state_token": token]
        let value = await backend.invoke(name: "set_value", arguments: base.merging([
            "role": "AXTextField", "label": "Name", "value": "x",
        ]) { _, new in new })
        XCTAssertFalse(value.isError)
        let fresh = try observation(value)
        XCTAssertEqual(fresh["settled"] as? Bool, false)
        XCTAssertEqual(fresh["settle_ms"] as? Int, 2000)
        let menu = await backend.invoke(name: "menu_shortcut", arguments: base.merging(["chord": "MOD+Q"]) { _, new in new })
        XCTAssertTrue(menu.isError)
        XCTAssertTrue(menu.content[0].text?.contains("no enabled menu item has this shortcut") == true)
        let invalid = await backend.invoke(name: "menu_shortcut", arguments: base.merging(["chord": "S"]) { _, new in new })
        XCTAssertTrue(invalid.isError)
    }

    func testRiskGuardRefusesUnlistedPopUpItemWithoutPressing() {
        let presses = NativeInputTestState()
        func select(_ title: String, _ allowed: Set<RiskCategory>?) -> ComputerUseNativeSetValueResult {
            NativeRiskGuard.selectPopUpItem(
                items: ["Keep", title], title: title, titleOf: { $0 }, allowed: allowed,
                press: { presses.record("press:\($0 ?? "nil")", []); return true },
                cancel: { presses.record("cancel", []) })
        }
        XCTAssertEqual(select("Delete", []), .failed("risky menu item 'Delete' requires allowed_risks delete"))
        XCTAssertEqual(presses.actions.map(\.0), ["cancel"], "a refused pop-up item must be cancelled, never pressed")
        XCTAssertEqual(select("Delete", [.delete]), .applied)
        XCTAssertEqual(select("Delete", nil), .applied, "no allowed_risks keeps the unguarded behaviour")
        XCTAssertEqual(presses.actions.map(\.0), ["cancel", "press:Delete", "press:Delete"])
    }

    func testRiskGuardRefusesRiskyShortcutMenuItem() {
        let presses = NativeInputTestState()
        func press(_ allowed: Set<RiskCategory>?) -> ComputerUseNativeMenuShortcutResult {
            NativeRiskGuard.pressShortcutMatch(
                matches: ["Close"], titleOf: { $0 }, allowed: allowed,
                press: { presses.record("press:\($0 ?? "nil")", []); return true })
        }
        XCTAssertEqual(press([]), .refused("risky menu item 'Close' requires allowed_risks close"))
        XCTAssertTrue(presses.actions.isEmpty, "MOD+W bound to Close must not be pressed without allowed_risks")
        XCTAssertEqual(press([.close]), .applied)
        XCTAssertEqual(presses.actions.map(\.0), ["press:Close"])
        XCTAssertEqual(NativeRiskGuard.pressShortcutMatch(
            matches: [String](), titleOf: { $0 }, allowed: [], press: { _ in true }), .noMenuItem)
    }

    func testBackendPassesAllowedRisksToHooksAndReportsRefusal() async throws {
        let seen = NativeInputTestState()
        let backend = semanticBackend { hooks in
            hooks.setValueByID = { _, _, _, allowed in
                seen.record("set:\(allowed.map { $0.map(\.rawValue).sorted().joined(separator: ",") } ?? "nil")", [])
                return .failed("risky menu item 'Delete' requires allowed_risks delete")
            }
            hooks.menuShortcut = { _, _, allowed in
                seen.record("menu:\(allowed.map { $0.map(\.rawValue).sorted().joined(separator: ",") } ?? "nil")", [])
                return .refused("risky menu item 'Close' requires allowed_risks close")
            }
        }
        let observed = await backend.invoke(name: "get_ui_tree", arguments: ["target_pid": 42, "target_window_id": 7, "ocr": "never"])
        let token = try XCTUnwrap(try observation(observed)["state_token"] as? String)
        let base: [String: Any] = ["target_pid": 42, "target_window_id": 7, "expected_state_token": token]
        let set = await backend.invoke(name: "set_value", arguments: base.merging([
            "element_id": "ax_1", "value": "Delete", "allowed_risks": [String](),
        ]) { _, new in new })
        XCTAssertTrue(set.isError)
        XCTAssertTrue(set.content[0].text?.contains("risky menu item 'Delete' requires allowed_risks delete") == true)
        let menu = await backend.invoke(name: "menu_shortcut", arguments: base.merging([
            "chord": "MOD+W", "allowed_risks": ["send", "close"],
        ]) { _, new in new })
        XCTAssertTrue(menu.isError)
        XCTAssertTrue(menu.content[0].text?.contains("requires allowed_risks close") == true)
        let unguarded = await backend.invoke(name: "menu_shortcut", arguments: base.merging(["chord": "MOD+W"]) { _, new in new })
        XCTAssertTrue(unguarded.isError)
        let bogus = await backend.invoke(name: "menu_shortcut", arguments: base.merging([
            "chord": "MOD+W", "allowed_risks": ["bogus"],
        ]) { _, new in new })
        XCTAssertTrue(bogus.content[0].text?.contains("allowed_risks") == true)
        XCTAssertEqual(seen.actions.map(\.0), ["set:", "menu:close,send", "menu:nil"])
    }

    func testSubmitFallbackNeverRunsAfterHumanTakeoverDuringSettle() async throws {
        for pixelPostsKey in [false, true] {
            let state = NativeInputTestState()
            let human = NativeInputTestState()
            let backend = semanticBackend { hooks in
                hooks.userActivity = { _ in human.isFocused ? .human : .none }
                hooks.settleWatcher = { _ in
                    NativeSettleWatcher(wait: { human.isFocused = true; return .init(settled: true, elapsedMilliseconds: 1) })
                }
                hooks.setValueByID = { _, _, _, _ in state.record("set", []); return .applied }
                hooks.focusedTarget = { _ in true }
                hooks.isFocusedElementByID = { _, _ in true }
                hooks.pixelAction = { _, _, _ in state.record("key", []); return pixelPostsKey }
                hooks.semanticConfirmByID = { _, _ in XCTFail("AXConfirm must not run after takeover"); return true }
            }
            let observed = await backend.invoke(name: "get_ui_tree", arguments: ["target_pid": 42, "target_window_id": 7, "ocr": "never"])
            let token = try XCTUnwrap(try observation(observed)["state_token"] as? String)
            let result = await backend.invoke(name: "set_value", arguments: [
                "target_pid": 42, "target_window_id": 7, "expected_state_token": token,
                "element_id": "ax_1", "value": "x", "submit_key": "ENTER",
            ])
            XCTAssertTrue(result.isError)
            XCTAssertTrue(result.content[0].text?.contains("human_activity") == true, "\(result.content[0].text ?? "")")
            XCTAssertEqual(state.actions.map(\.0), ["set"], "no key and no AXConfirm after the human took over")
        }
    }

    func testHumanActivityAfterFailedKeyPathBlocksAXConfirm() async throws {
        let human = NativeInputTestState()
        let backend = semanticBackend { hooks in
            hooks.userActivity = { _ in human.isFocused ? .human : .none }
            hooks.setValueByID = { _, _, _, _ in .applied }
            hooks.focusedTarget = { _ in true }
            hooks.isFocusedElementByID = { _, _ in true }
            hooks.pixelAction = { _, _, _ in human.isFocused = true; return false }
            hooks.semanticConfirmByID = { _, _ in XCTFail("AXConfirm must not run after takeover"); return true }
        }
        let observed = await backend.invoke(name: "get_ui_tree", arguments: ["target_pid": 42, "target_window_id": 7, "ocr": "never"])
        let token = try XCTUnwrap(try observation(observed)["state_token"] as? String)
        let result = await backend.invoke(name: "set_value", arguments: [
            "target_pid": 42, "target_window_id": 7, "expected_state_token": token,
            "element_id": "ax_1", "value": "x", "submit_key": "ENTER",
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content[0].text?.contains("human_activity") == true)
    }

    func testMinimizedWindowAllowsAXPressButRefusesInputEvents() async throws {
        let target = ComputerUseNativeHostTarget(pid: 42, windowID: 7)
        let window = ComputerUseNativeWindow(target: target, isOnScreen: false, isMinimized: true)
        let backend = ComputerUseNativeHostBackend(hooks: .init(
            listWindows: { _ in [window] },
            userActivity: { _ in .none },
            activityMonitorAvailable: { true },
            accessibilityPermission: { true },
            axTargetAvailable: { _ in true },
            screenCapturePermission: { true },
            capture: { _ in .unavailable("offline") },
            uiTree: { _ in "tree" },
            semanticAction: { _, _, _ in true },
            typeText: { _, _ in XCTFail("minimized window must not receive typing"); return false },
            settleWatcher: { _ in .immediate }
        ))
        let observed = await backend.invoke(name: "get_ui_tree", arguments: ["target_pid": 42, "target_window_id": 7])
        XCTAssertFalse(observed.isError)
        let token = try XCTUnwrap(try observation(observed)["state_token"] as? String)
        XCTAssertEqual(try observation(observed)["is_minimized"] as? Bool, true)
        let base: [String: Any] = ["target_pid": 42, "target_window_id": 7, "expected_state_token": token]
        let click = await backend.invoke(name: "click_element", arguments: base.merging(["role": "AXButton", "label": "OK"]) { _, new in new })
        XCTAssertFalse(click.isError)
        XCTAssertEqual(try observation(click)["is_minimized"] as? Bool, true)
        let typed = await backend.invoke(name: "type", arguments: base.merging(["text": "x"]) { _, new in new })
        XCTAssertTrue(typed.isError)
        XCTAssertTrue(typed.content[0].text?.contains("restore_window first") == true)
    }

    private func semanticBackend(
        tree: String = "tree",
        hooks configure: (inout ComputerUseNativeHostBackend.Hooks) -> Void = { _ in }
    ) -> ComputerUseNativeHostBackend {
        let target = ComputerUseNativeHostTarget(pid: 42, windowID: 7)
        let window = ComputerUseNativeWindow(target: target, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        var hooks = ComputerUseNativeHostBackend.Hooks(
            listWindows: { _ in [window] },
            userActivity: { _ in .none },
            activityMonitorAvailable: { true },
            accessibilityPermission: { true },
            axTargetAvailable: { _ in true },
            screenCapturePermission: { true },
            capture: { _ in .unavailable("offline") },
            uiTree: { _ in tree },
            settleWatcher: { _ in .immediate }
        )
        configure(&hooks)
        return ComputerUseNativeHostBackend(hooks: hooks)
    }

    func testElementIDResolvesForClickAndSetValueAndRejectsStaleToken() async throws {
        let pressed = NativeInputTestState()
        let backend = semanticBackend { hooks in
            hooks.semanticActionByID = { _, id in pressed.record("press:\(id)", []); return true }
            hooks.setValueByID = { _, id, value, _ in pressed.record("set:\(id)=\(value)", []); return .applied }
            hooks.semanticAction = { _, _, _ in XCTFail("element_id must not use role+label"); return false }
            hooks.setValue = { _, _, _, _, _ in XCTFail("element_id must not use role+label"); return .applied }
        }
        let observed = await backend.invoke(name: "get_ui_tree", arguments: ["target_pid": 42, "target_window_id": 7, "ocr": "never"])
        let token = try XCTUnwrap(try observation(observed)["state_token"] as? String)
        let base: [String: Any] = ["target_pid": 42, "target_window_id": 7, "expected_state_token": token]

        let click = await backend.invoke(name: "click_element", arguments: base.merging(["element_id": "ax_3"]) { _, new in new })
        XCTAssertFalse(click.isError)
        let set = await backend.invoke(name: "set_value", arguments: base.merging(["element_id": "ax_4", "value": "v"]) { _, new in new })
        XCTAssertFalse(set.isError)
        XCTAssertEqual(pressed.actions.map(\.0), ["press:ax_3", "set:ax_4=v"])

        let stale = await backend.invoke(name: "click_element", arguments: [
            "target_pid": 42, "target_window_id": 7, "expected_state_token": "stale", "element_id": "ax_3",
        ])
        XCTAssertTrue(stale.isError)
        XCTAssertTrue(stale.content[0].text?.contains("stale_state_token") == true)
        XCTAssertEqual(pressed.actions.count, 2)
    }

    func testElementIDAndRoleLabelAreMutuallyExclusiveAndIDMustBeInRange() async throws {
        let backend = semanticBackend { hooks in
            hooks.semanticActionByID = { _, _ in XCTFail("invalid selector must not act"); return true }
            hooks.semanticAction = { _, _, _ in XCTFail("invalid selector must not act"); return true }
            hooks.setValueByID = { _, _, _, _ in XCTFail("invalid selector must not act"); return .applied }
        }
        let observed = await backend.invoke(name: "get_ui_tree", arguments: ["target_pid": 42, "target_window_id": 7, "ocr": "never"])
        let token = try XCTUnwrap(try observation(observed)["state_token"] as? String)
        let base: [String: Any] = ["target_pid": 42, "target_window_id": 7, "expected_state_token": token]
        let both = await backend.invoke(name: "click_element", arguments: base.merging([
            "element_id": "ax_1", "role": "AXButton", "label": "OK",
        ]) { _, new in new })
        XCTAssertTrue(both.isError)
        XCTAssertTrue(both.content[0].text?.contains("either element_id or role+label") == true)
        let neither = await backend.invoke(name: "set_value", arguments: base.merging(["value": "x"]) { _, new in new })
        XCTAssertTrue(neither.isError)
        for bad in ["ax_200", "ax_-1", "ax_01", "x_1", "ax_", "ax_1000"] {
            let result = await backend.invoke(name: "click_element", arguments: base.merging(["element_id": bad]) { _, new in new })
            XCTAssertTrue(result.isError, bad)
            XCTAssertTrue(result.content[0].text?.contains("out of range or malformed") == true, bad)
        }
        XCTAssertEqual(NativeElementID.index("ax_199"), 199)
        XCTAssertEqual(NativeElementID.index("ax_0"), 0)
    }

    private let unlabelledTree = #"{"id":"ax_0","role":"AXWindow","children":[{"id":"ax_1","role":"AXGroup"}]}"#
    private let labelledTree = #"{"id":"ax_0","role":"AXWindow","children":[{"id":"ax_1","role":"AXButton","title":"Save"}]}"#

    func testOCRNeverAndAutoOnLabelledTreeAddNoOCRLine() async throws {
        let capture = try testCapture()
        for (mode, tree) in [("never", unlabelledTree), ("auto", labelledTree)] {
            let backend = semanticBackend(tree: tree) { hooks in
                hooks.capture = { _ in .success(capture) }
                hooks.recognizeText = { _ in XCTFail("OCR must not run for \(mode)"); return [] }
            }
            let result = try await backend.invoke(name: "get_ui_tree", arguments: ["target_pid": 42, "target_window_id": 7, "ocr": mode])
            let text = try XCTUnwrap(result.content.first?.text)
            XCTAssertFalse(text.contains("\nocr: "))
            XCTAssertEqual(try observation(result)["perception_sources"] as? [String], ["ax"])
        }
    }

    func testOCRAutoAddsEvidenceWhenTreeHasNoLabelledControls() async throws {
        let capture = try testCapture()
        let backend = semanticBackend(tree: unlabelledTree) { hooks in
            hooks.capture = { _ in .success(capture) }
            hooks.recognizeText = { image in
                XCTAssertEqual(image.width, 100)
                return [OCRElement(id: "ocr_1", text: "Hello", confidence: 0.9, frame: CGRect(x: 1, y: 2, width: 3, height: 4))]
            }
        }
        let args: [String: Any] = ["target_pid": 42, "target_window_id": 7]
        let result = await backend.invoke(name: "get_ui_tree", arguments: args)
        XCTAssertFalse(result.isError)
        let text = try XCTUnwrap(result.content.first?.text)
        let line = try XCTUnwrap(text.components(separatedBy: "\n").first { $0.hasPrefix("ocr: ") })
        let array = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [[String: Any]])
        XCTAssertEqual(array.first?["text"] as? String, "Hello")
        XCTAssertEqual(try observation(result)["perception_sources"] as? [String], ["ax", "ocr"])
        XCTAssertTrue(text.contains("\nui_tree: "))
        let always = await backend.invoke(name: "get_ui_tree", arguments: args.merging(["ocr": "always"]) { _, new in new })
        XCTAssertTrue(always.content[0].text?.contains("\nocr: ") == true)
    }

    func testOCRFailureNeverFailsGetUITreeAndIsReported() async throws {
        struct Boom: Error {}
        let capture = try testCapture()
        let failing = semanticBackend(tree: unlabelledTree) { hooks in
            hooks.capture = { _ in .success(capture) }
            hooks.recognizeText = { _ in throw Boom() }
        }
        let result = await failing.invoke(name: "get_ui_tree", arguments: ["target_pid": 42, "target_window_id": 7])
        XCTAssertFalse(result.isError)
        let header = try observation(result)
        XCTAssertNotNil(header["ocr_error"] as? String)
        XCTAssertEqual(header["perception_sources"] as? [String], ["ax"])
        XCTAssertFalse(result.content[0].text?.contains("\nocr: ") == true)

        let noCapture = semanticBackend(tree: unlabelledTree)
        let offline = await noCapture.invoke(name: "get_ui_tree", arguments: ["target_pid": 42, "target_window_id": 7])
        XCTAssertFalse(offline.isError)
        XCTAssertNotNil(try observation(offline)["ocr_error"] as? String)
    }

    func testMenuChordParsing() {
        let save = ComputerUseNativeMenuChord.parse("MOD+S")
        XCTAssertEqual(save, .init(key: "S", command: true, control: false, option: false, shift: false))
        XCTAssertEqual(save?.axModifiers, 0)
        let redo = ComputerUseNativeMenuChord.parse("mod+shift+z")
        XCTAssertEqual(redo?.key, "Z")
        XCTAssertEqual(redo?.axModifiers, 1)
        XCTAssertEqual(ComputerUseNativeMenuChord.parse("CTRL+ALT+1")?.axModifiers, 2 | 4 | 8)
        XCTAssertEqual(ComputerUseNativeMenuChord.parse("MOD++")?.key, "+")
        XCTAssertTrue(ComputerUseNativeMenuChord.parse("MOD+A")?.isSelectAll == true)
        for invalid in ["", "S", "MOD+", "MOD+SS", "MOD+MOD+S", "FOO+S", "MOD+ ", "+S"] as [String] {
            XCTAssertNil(ComputerUseNativeMenuChord.parse(invalid), invalid)
        }
        XCTAssertNil(ComputerUseNativeMenuChord.parse(5))
    }

    func testMenuShortcutSearchSkipsDisabledAndFlagsAmbiguity() {
        struct Node {
            let role: String
            let enabled: Bool
            let cmdChar: String?
            let modifiers: Int?
            let children: [Node]
        }
        let chord = ComputerUseNativeMenuChord.parse("MOD+S")!
        let attributes: (Node) -> (role: String?, enabled: Bool, cmdChar: String?, cmdModifiers: Int?)? = {
            ($0.role, $0.enabled, $0.cmdChar, $0.modifiers)
        }
        let disabled = Node(role: "AXMenuItem", enabled: false, cmdChar: "S", modifiers: 0, children: [])
        let wrongModifier = Node(role: "AXMenuItem", enabled: true, cmdChar: "S", modifiers: 1, children: [])
        let good = Node(role: "AXMenuItem", enabled: true, cmdChar: "s", modifiers: 0, children: [])
        let bar = Node(role: "AXMenuBar", enabled: true, cmdChar: nil, modifiers: nil, children: [
            Node(role: "AXMenuBarItem", enabled: true, cmdChar: nil, modifiers: nil, children: [
                Node(role: "AXMenu", enabled: true, cmdChar: nil, modifiers: nil, children: [disabled, wrongModifier, good]),
            ]),
        ])
        XCTAssertEqual(NativeMenuShortcutSearch.enabledMatches(root: bar, chord: chord, attributesOf: attributes, childrenOf: \.children).count, 1)
        let twice = Node(role: "AXMenuBar", enabled: true, cmdChar: nil, modifiers: nil, children: [good, good])
        XCTAssertEqual(NativeMenuShortcutSearch.enabledMatches(root: twice, chord: chord, attributesOf: attributes, childrenOf: \.children).count, 2)
    }

    /// Fake clock: a notification script gives the delay until each notification.
    private func settle(notificationTimes: [TimeInterval]) -> NativeSettle.Result {
        var clock: TimeInterval = 0
        var pending = notificationTimes
        return NativeSettle.wait(
            now: { clock },
            waitForNotification: { timeout in
                if let next = pending.first, next - clock <= timeout {
                    clock = max(clock, next)
                    pending.removeFirst()
                    return true
                }
                clock += timeout
                return false
            }
        )
    }

    func testSettleTreatsNoReactionWithinFirstWindowAsSettled() {
        let result = settle(notificationTimes: [])
        XCTAssertTrue(result.settled)
        XCTAssertEqual(result.elapsedMilliseconds, 600)
    }

    func testSettleWaitsForQuietAfterBurst() {
        let result = settle(notificationTimes: [0.1, 0.2, 0.3])
        XCTAssertTrue(result.settled)
        XCTAssertEqual(result.elapsedMilliseconds, 450)
    }

    func testSettleCapsContinuousNotificationsAtTwoSeconds() {
        let result = settle(notificationTimes: (1...100).map { Double($0) * 0.1 })
        XCTAssertFalse(result.settled)
        XCTAssertEqual(result.elapsedMilliseconds, 2000)
    }

    func testMalformedJSONReturnsParseErrorInsteadOfLeavingClientWaiting() async throws {
        let response = try await response("not-json", from: ManagedComputerUseMCP())
        XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32700)
    }

    func testUnknownMethodAndUnknownToolAreRejected() async throws {
        let handler = ManagedComputerUseMCP()
        let method = try await response(#"{"jsonrpc":"2.0","id":2,"method":"does/not/exist"}"#, from: handler)
        XCTAssertEqual((method["error"] as? [String: Any])?["code"] as? Int, -32601)
        let tool = try await response(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"browser_unknown","arguments":{"url":"https://example.com"}}}"#, from: handler)
        XCTAssertEqual((tool["error"] as? [String: Any])?["code"] as? Int, -32602)
    }

    func testNativeMutationFailsClosedForWrongWindowHumanActivityAndMissingToken() async {
        let target = ComputerUseNativeHostTarget(pid: 42, windowID: 7)
        let window = ComputerUseNativeWindow(target: target, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let humanBackend = ComputerUseNativeHostBackend(hooks: .init(
            listWindows: { _ in [window] },
            userActivity: { _ in .human },
            activityMonitorAvailable: { true },
            accessibilityPermission: { true },
            axTargetAvailable: { _ in true },
            screenCapturePermission: { true },
            capture: { _ in .unavailable("offline") },
            uiTree: { _ in "tree" },
            semanticAction: { _, _, _ in XCTFail("mutation must not reach AX"); return false },
            leftClick: { _, _ in XCTFail("mutation must not click"); return .failed },
            typeText: { _, _ in XCTFail("mutation must not type"); return false }
        ))
        let args: [String: Any] = ["target_pid": 42, "target_window_id": 7, "expected_state_token": "stale", "text": "test"]
        let wrongWindow = await humanBackend.invoke(name: "type", arguments: args.merging(["target_window_id": 8]) { _, new in new })
        XCTAssertTrue(wrongWindow.isError)
        XCTAssertTrue(wrongWindow.content[0].text?.contains("target_not_found") == true)
        let human = await humanBackend.invoke(name: "type", arguments: args)
        XCTAssertTrue(human.isError)
        XCTAssertTrue(human.content[0].text?.contains("human_activity") == true)

        let quietBackend = ComputerUseNativeHostBackend(hooks: .init(
            listWindows: { _ in [window] },
            userActivity: { _ in .none },
            activityMonitorAvailable: { true },
            accessibilityPermission: { true },
            axTargetAvailable: { _ in true },
            screenCapturePermission: { true },
            capture: { _ in .unavailable("offline") },
            uiTree: { _ in "tree" },
            semanticAction: { _, _, _ in XCTFail("mutation must not reach AX"); return false },
            leftClick: { _, _ in XCTFail("mutation must not click"); return .failed },
            typeText: { _, _ in XCTFail("mutation must not type"); return false }
        ))
        let missing = await quietBackend.invoke(name: "type", arguments: ["target_pid": 42, "target_window_id": 7, "text": "test"])
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(missing.content[0].text?.contains("missing_state_token") == true)
        let stale = await quietBackend.invoke(name: "type", arguments: args)
        XCTAssertTrue(stale.isError)
        XCTAssertTrue(stale.content[0].text?.contains("stale_state_token") == true)
    }

    func testPixelFallbacksAreBoundsCheckedAndAXMissDispatchesOneClick() async throws {
        let target = ComputerUseNativeHostTarget(pid: 42, windowID: 7)
        let window = ComputerUseNativeWindow(target: target, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let state = NativeInputTestState()
        state.isFocused = true
        let capture = try testCapture()
        let backend = ComputerUseNativeHostBackend(hooks: .init(
            listWindows: { _ in [window] },
            userActivity: { _ in .none },
            activityMonitorAvailable: { true },
            accessibilityPermission: { true },
            axTargetAvailable: { _ in true },
            screenCapturePermission: { true },
            capture: { _ in .success(capture) },
            uiTree: { _ in "tree" },
            leftClick: { _, coordinate in
                state.record("ax_hit_test", coordinate)
                return .noAXTarget
            },
            focusedTarget: { _ in state.isFocused },
            pixelAction: { _, name, coordinate in state.record(name, coordinate); return true },
            settleWatcher: { _ in .immediate }
        ))
        let screenshot = await backend.invoke(name: "screenshot", arguments: ["target_pid": 42, "target_window_id": 7])
        let token = try XCTUnwrap(try observation(screenshot)["state_token"] as? String)
        let base: [String: Any] = ["target_pid": 42, "target_window_id": 7, "expected_state_token": token]
        for (name, extra) in [
            ("left_click", ["coordinate": [10.0, 20.0]] as [String: Any]),
            ("right_click", ["coordinate": [11.0, 21.0]] as [String: Any]),
            ("mouse_move", ["coordinate": [12.0, 22.0]] as [String: Any]),
            ("scroll", ["coordinate": [13.0, 23.0], "delta_x": 2.0, "delta_y": -3.0] as [String: Any]),
        ] {
            let result = await backend.invoke(name: name, arguments: base.merging(extra) { _, new in new })
            XCTAssertFalse(result.isError, "\(name) should use the guarded pixel fallback")
            XCTAssertNotNil(try observation(result)["state_token"])
        }
        let dispatched = state.actions.filter { ["left_click", "right_click", "mouse_move", "scroll"].contains($0.0) }
        XCTAssertEqual(dispatched.map(\.0), ["left_click", "right_click", "mouse_move", "scroll"])
        XCTAssertEqual(dispatched[0].1, [10, 20])
        XCTAssertEqual(dispatched[3].1, [13, 23, 2, -3])

        state.isFocused = false
        let unfocused = await backend.invoke(name: "left_click", arguments: base.merging(["coordinate": [10.0, 20.0]]) { _, new in new })
        XCTAssertTrue(unfocused.isError)
        XCTAssertTrue(unfocused.content[0].text?.contains("focus_required") == true)
        XCTAssertEqual(state.actions.filter { ["left_click", "right_click", "mouse_move", "scroll"].contains($0.0) }.count, 4)

        let rejected = await backend.invoke(name: "right_click", arguments: base.merging(["coordinate": [101.0, 20.0]]) { _, new in new })
        XCTAssertTrue(rejected.isError)
        XCTAssertEqual(state.actions.filter { $0.0 == "right_click" }.count, 1)
        XCTAssertEqual(state.actions.filter { $0.0 == "ax_hit_test" }.count, 2)

        let failedAX = ComputerUseNativeHostBackend(hooks: .init(
            listWindows: { _ in [window] },
            userActivity: { _ in .none },
            activityMonitorAvailable: { true },
            accessibilityPermission: { true },
            axTargetAvailable: { _ in true },
            screenCapturePermission: { true },
            capture: { _ in .success(capture) },
            leftClick: { _, _ in .failed },
            pixelAction: { _, _, _ in XCTFail("do not retry a failed AX dispatch"); return false },
            settleWatcher: { _ in .immediate }
        ))
        let failed = await failedAX.invoke(name: "left_click", arguments: base.merging(["coordinate": [10.0, 20.0]]) { _, new in new })
        XCTAssertTrue(failed.isError)
    }

    func testChangedWindowMetadataFailsStaleCheckBeforeKeyDispatch() async throws {
        let target = ComputerUseNativeHostTarget(pid: 42, windowID: 7)
        let original = ComputerUseNativeWindow(target: target, title: "Original", bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let changed = ComputerUseNativeWindow(target: target, title: "Changed", bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let windows = NativeWindowSequence(first: original, subsequent: changed)
        let state = NativeInputTestState()
        let backend = ComputerUseNativeHostBackend(hooks: .init(
            listWindows: { _ in windows.next() },
            userActivity: { _ in .none },
            activityMonitorAvailable: { true },
            accessibilityPermission: { true },
            axTargetAvailable: { _ in true },
            screenCapturePermission: { true },
            capture: { _ in .unavailable("offline") },
            uiTree: { _ in "tree" },
            focusedTarget: { _ in true },
            pixelAction: { _, name, coordinate in state.record(name, coordinate); return true },
            settleWatcher: { _ in .immediate }
        ))
        let observed = await backend.invoke(name: "cursor_position", arguments: ["target_pid": 42, "target_window_id": 7])
        let token = try XCTUnwrap(try observation(observed)["state_token"] as? String)
        let result = await backend.invoke(name: "key", arguments: [
            "target_pid": 42, "target_window_id": 7, "expected_state_token": token, "key": "a",
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.first?.text?.contains("stale_state_token") == true)
        XCTAssertTrue(state.actions.isEmpty)
    }

    func testKeyboardFallbackRequiresExactFocusAndAllowlistedKey() async throws {
        let target = ComputerUseNativeHostTarget(pid: 42, windowID: 7)
        let window = ComputerUseNativeWindow(target: target, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let state = NativeInputTestState()
        let backend = ComputerUseNativeHostBackend(hooks: .init(
            listWindows: { _ in [window] },
            userActivity: { _ in .none },
            activityMonitorAvailable: { true },
            accessibilityPermission: { true },
            axTargetAvailable: { _ in true },
            screenCapturePermission: { true },
            capture: { _ in .unavailable("offline") },
            uiTree: { _ in "tree" },
            focusedTarget: { _ in state.isFocused },
            pixelAction: { _, name, coordinate in state.record(name, coordinate); return true },
            settleWatcher: { _ in .immediate }
        ))
        let observed = await backend.invoke(name: "cursor_position", arguments: ["target_pid": 42, "target_window_id": 7])
        let token = try XCTUnwrap(try observation(observed)["state_token"] as? String)
        let args: [String: Any] = ["target_pid": 42, "target_window_id": 7, "expected_state_token": token, "key": "a"]
        let notFocused = await backend.invoke(name: "key", arguments: args)
        XCTAssertTrue(notFocused.isError)
        XCTAssertTrue(notFocused.content.first?.text?.contains("focus_required") == true)
        XCTAssertTrue(state.actions.isEmpty)

        state.isFocused = true
        let invalid = await backend.invoke(name: "key", arguments: args.merging(["key": "F1"]) { _, new in new })
        XCTAssertTrue(invalid.isError)
        XCTAssertTrue(state.actions.isEmpty)
        let sent = await backend.invoke(name: "key", arguments: args.merging(["modifiers": ["command"]]) { _, new in new })
        XCTAssertFalse(sent.isError)
        XCTAssertEqual(state.actions.count, 1)
        XCTAssertEqual(state.actions[0].0, "key")
        XCTAssertEqual(state.actions[0].1, [0, Double(1 << 20)])
        XCTAssertNotNil(try observation(sent)["state_token"])
    }

    func testRestoreWindowTargetsExactWindowReturnsFreshObservationAndRejectsStaleTarget() async throws {
        let target = ComputerUseNativeHostTarget(pid: 42, windowID: 7)
        let other = ComputerUseNativeHostTarget(pid: 42, windowID: 8)
        let state = RestoreWindowTestState()
        let minimized = ComputerUseNativeWindow(target: target, isOnScreen: false, isMinimized: true)
        let backend = ComputerUseNativeHostBackend(hooks: .init(
            listWindows: { _ in [state.restored ? ComputerUseNativeWindow(target: target) : minimized,
                                 ComputerUseNativeWindow(target: other)] },
            userActivity: { _ in .none },
            activityMonitorAvailable: { true },
            accessibilityPermission: { true },
            axTargetAvailable: { _ in true },
            screenCapturePermission: { true },
            capture: { _ in .unavailable("offline") },
            uiTree: { _ in "tree" },
            activate: { requested in
                XCTAssertEqual(requested, target)
                state.restored = true
                return true
            }
        ))
        let before = await backend.invoke(name: "cursor_position", arguments: ["target_pid": 42, "target_window_id": 7])
        let beforeText = try XCTUnwrap(before.content.first?.text)
        let beforeData = try XCTUnwrap(beforeText.components(separatedBy: "\n").first?.data(using: .utf8))
        let beforeObservation = try XCTUnwrap(JSONSerialization.jsonObject(with: beforeData) as? [String: Any])
        XCTAssertEqual(beforeObservation["is_minimized"] as? Bool, true)
        let token = try XCTUnwrap(beforeObservation["state_token"] as? String)
        let restored = await backend.invoke(name: "restore_window", arguments: [
            "target_pid": 42, "target_window_id": 7, "expected_state_token": token,
        ])
        XCTAssertFalse(restored.isError)
        let restoredText = try XCTUnwrap(restored.content.first?.text)
        let freshText = try XCTUnwrap(restoredText.components(separatedBy: "\n").last)
        let freshData = try XCTUnwrap(freshText.data(using: .utf8))
        let fresh = try XCTUnwrap(JSONSerialization.jsonObject(with: freshData) as? [String: Any])
        XCTAssertNotEqual(fresh["state_token"] as? String, token)
        XCTAssertEqual(fresh["target_window_id"] as? Int, 7)
        XCTAssertEqual(fresh["is_minimized"] as? Bool, false)
        let stale = await backend.invoke(name: "restore_window", arguments: [
            "target_pid": 42, "target_window_id": 99, "expected_state_token": token,
        ])
        XCTAssertTrue(stale.isError)
        XCTAssertTrue(stale.content.first?.text?.contains("target_not_found") == true)
    }

    func testSyntheticInputTagPreventsOwnEventsFromTriggeringHumanActivityGuard() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .hidSystemState))
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true))
        ComputerUseNativeHostBackend.NativePlatform.markSyntheticInput(event)
        XCTAssertEqual(
            event.getIntegerValueField(.eventSourceUserData),
            ComputerUseNativeActivityMonitor.syntheticEventUserData
        )
        let monitor = ComputerUseNativeActivityMonitor(quietWindowNanoseconds: 100, now: { 20 })
        monitor.record(.init(
            kind: .keyboard,
            pid: 42,
            timestampNanoseconds: 20,
            isSynthetic: event.getIntegerValueField(.eventSourceUserData)
                == ComputerUseNativeActivityMonitor.syntheticEventUserData
        ))
        XCTAssertEqual(monitor.activity(for: .init(pid: 42, windowID: 7)), .none)
    }

    func testLockIsSharedWithRemoteCodeToPreventCrossServerInputRaces() {
        XCTAssertTrue(ComputerUseHostQueue.defaultLockURL.path.hasSuffix("/RemoteCode/computer-use.lock"))
    }
}
