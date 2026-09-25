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
            "screenshot", "zoom", "cursor_position", "list_windows", "get_ui_tree", "jev_decide", "doctor",
            "left_click", "type", "click_element", "restore_window", "right_click", "mouse_move", "scroll", "key",
            "browser_open", "browser_snapshot", "browser_act", "browser_close", "browser_status",
        ]))
        for tool in tools {
            XCTAssertNotNil(tool["inputSchema"] as? [String: Any])
        }
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
            pixelAction: { _, name, coordinate in state.record(name, coordinate); return true }
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
            pixelAction: { _, _, _ in XCTFail("do not retry a failed AX dispatch"); return false }
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
            pixelAction: { _, name, coordinate in state.record(name, coordinate); return true }
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
            pixelAction: { _, name, coordinate in state.record(name, coordinate); return true }
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
