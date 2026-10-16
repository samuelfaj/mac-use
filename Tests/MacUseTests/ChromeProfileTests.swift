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
    func testExtendedBrowserToolsHaveCatalogMetadataAndMutationClassification() throws {
        let names = ["browser_navigate", "browser_click", "browser_type", "browser_pointer", "browser_dialog", "browser_set_input_files", "browser_download", "page"]
        for name in names {
            XCTAssertTrue(ChromeProfileComputerUseBackend.tools.contains(name), name)
            XCTAssertTrue(ChromeProfileComputerUseBackend.mutationTools.contains(name), name)
            XCTAssertNotNil(ChromeProfileComputerUseBackend.description(for: name), name)
            let schema = try XCTUnwrap(ChromeProfileComputerUseBackend.inputSchema(for: name))
            XCTAssertEqual(schema["type"] as? String, "object")
            XCTAssertNotNil(schema["properties"] as? [String: Any])
        }
        XCTAssertEqual(Set(ChromeProfileComputerUseBackend.tools).count, ChromeProfileComputerUseBackend.tools.count)
        XCTAssertNil(ChromeProfileComputerUseBackend.inputSchema(for: "unknown"))
        XCTAssertNil(ChromeProfileComputerUseBackend.description(for: "unknown"))
    }

    func testDownloadMovesCompletedFileAndRejectsMissingDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mac-use-download-\(UUID().uuidString)")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("download.txt")
        try Data("download".utf8).write(to: source)
        let backend = ChromeProfileComputerUseBackend(send: { _ in ["ok": true, "download_path": source.path] })
        let result = await backend.invoke(name: "browser_download", arguments: ["ref": "ref", "directory": destination.path])
        XCTAssertFalse(result.isError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("download.txt")), "download")
        let text = try XCTUnwrap(result.content.first?.text)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(response["path"] as? String, destination.appendingPathComponent("download.txt").path)
        let invalid = await backend.invoke(name: "browser_download", arguments: ["ref": "ref", "directory": root.appendingPathComponent("missing").path])
        XCTAssertTrue(invalid.isError)
    }

    func testDownloadNeverOverwritesDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mac-use-download-\(UUID().uuidString)")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("download.txt")
        try Data("new".utf8).write(to: source)
        try Data("old".utf8).write(to: destination.appendingPathComponent("download.txt"))
        let backend = ChromeProfileComputerUseBackend(send: { _ in ["ok": true, "download_path": source.path] })
        let result = await backend.invoke(name: "browser_download", arguments: ["ref": "ref", "directory": destination.path])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(try String(contentsOf: source), "new")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("download.txt")), "old")
    }
}
