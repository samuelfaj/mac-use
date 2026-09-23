import Foundation
import XCTest
@testable import MacUse

final class NativeMCPTests: XCTestCase {
    private func response(_ line: String, from handler: ManagedComputerUseMCP) async throws -> [String: Any] {
        let reply = await handler.handle(line)
        let text = try XCTUnwrap(reply)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testInitializeAdvertisesOnlyNativeServer() async throws {
        let handler = ManagedComputerUseMCP()
        let message = try await response(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#, from: handler)
        let result = try XCTUnwrap(message["result"] as? [String: Any])
        let server = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(server["name"] as? String, "mac-use")
        XCTAssertEqual(result["protocolVersion"] as? String, "2024-11-05")
        let instructions = try XCTUnwrap(result["instructions"] as? String)
        XCTAssertTrue(instructions.contains("state token"))
        XCTAssertFalse(instructions.contains("browser_"))
        let notificationReply = await handler.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(notificationReply)
    }

    func testToolsListContainsOnlyImplementedNativeTools() async throws {
        let handler = ManagedComputerUseMCP()
        let message = try await response(#"{"jsonrpc":"2.0","id":"tools","method":"tools/list"}"#, from: handler)
        let result = try XCTUnwrap(message["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }), Set([
            "screenshot", "zoom", "cursor_position", "list_windows", "get_ui_tree", "jev_decide", "doctor",
            "left_click", "type", "click_element",
        ]))
        for tool in tools {
            XCTAssertNotNil(tool["inputSchema"] as? [String: Any])
        }
    }

    func testMalformedJSONReturnsParseErrorInsteadOfLeavingClientWaiting() async throws {
        let response = try await response("not-json", from: ManagedComputerUseMCP())
        XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32700)
    }

    func testUnknownMethodAndBrowserToolAreRejected() async throws {
        let handler = ManagedComputerUseMCP()
        let method = try await response(#"{"jsonrpc":"2.0","id":2,"method":"does/not/exist"}"#, from: handler)
        XCTAssertEqual((method["error"] as? [String: Any])?["code"] as? Int, -32601)
        let tool = try await response(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"browser_open","arguments":{"url":"https://example.com"}}}"#, from: handler)
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
            leftClick: { _, _ in XCTFail("mutation must not click"); return false },
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
            leftClick: { _, _ in XCTFail("mutation must not click"); return false },
            typeText: { _, _ in XCTFail("mutation must not type"); return false }
        ))
        let missing = await quietBackend.invoke(name: "type", arguments: ["target_pid": 42, "target_window_id": 7, "text": "test"])
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(missing.content[0].text?.contains("missing_state_token") == true)
        let stale = await quietBackend.invoke(name: "type", arguments: args)
        XCTAssertTrue(stale.isError)
        XCTAssertTrue(stale.content[0].text?.contains("stale_state_token") == true)
    }

    func testLockIsSharedWithRemoteCodeToPreventCrossServerInputRaces() {
        XCTAssertTrue(ComputerUseHostQueue.defaultLockURL.path.hasSuffix("/RemoteCode/computer-use.lock"))
    }
}
