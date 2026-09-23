import Foundation
import XCTest
@testable import MacUse

final class ChromeProfileTests: XCTestCase {
    func testInstallerRegistersOnlyThisExtensionAndDoesNotTouchRemoteCode() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("mac-use-chrome-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let id = String(repeating: "a", count: 32)
        XCTAssertThrowsError(try ChromeProfileConnection.install(executable: "/tmp/mac-use-mcp", extensionID: "bad", homeDirectory: home))
        try ChromeProfileConnection.install(executable: "/tmp/mac-use-mcp", extensionID: id, homeDirectory: home)
        XCTAssertEqual(ChromeProfileConnection.installedExtensionID(homeDirectory: home), id)
        let registration = home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts/io.macuse.computer_use.json")
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: registration)) as? [String: Any])
        XCTAssertEqual(manifest["allowed_origins"] as? [String], ["chrome-extension://\(id)/"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts/io.remotecode.computer_use.json").path))
        let host = try String(contentsOf: home.appendingPathComponent("Library/Application Support/mac-use/ChromeComputerUse/native-host"))
        XCTAssertTrue(host.contains("chrome-native-host"))
    }

    func testBrowserMCPRoutesToOwnSessionAndPropagatesFailure() async throws {
        let backend = ChromeProfileComputerUseBackend(send: { request in
            let operation = request["operation"] as? String
            if operation == "browser_act" { return ["id": request["id"] ?? "", "ok": false, "error": "human_activity"] }
            return ["ok": true, "connected": true, "operation": operation ?? ""]
        })
        let handler = ManagedComputerUseMCP(browser: backend)
        for (name, expectedError) in [("browser_status", false), ("browser_act", true)] {
            let line = """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"\(name)","arguments":{"action":"click","ref":"stale"}}}
            """
            let reply = await handler.handle(line)
            let response = try XCTUnwrap(reply)
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
            let result = try XCTUnwrap(envelope["result"] as? [String: Any])
            XCTAssertEqual(result["isError"] as? Bool, expectedError)
            XCTAssertTrue(String(describing: result).contains(expectedError ? "human_activity" : "connected"))
        }
    }
}
