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

    func testHostTellsTheCallerWhenTheExtensionNeverAnswers() throws {
        // The host used to close the caller's socket without a word, which read as a dead
        // bridge and hid that one page had stopped answering.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("mu-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: home) }
        let id = String(repeating: "b", count: 32)
        try ChromeProfileConnection.install(executable: "/tmp/mac-use-mcp", extensionID: id, homeDirectory: home)
        let path = home.appendingPathComponent("b.sock").path
        var toHost: [Int32] = [0, 0], fromHost: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&toHost), 0)
        XCTAssertEqual(pipe(&fromHost), 0)
        defer { for fd in toHost + fromHost { close(fd) } }
        let exited = expectation(description: "host exits so Chrome starts a clean one")
        Thread.detachNewThread {
            try? ChromeProfileConnection.runHost(origin: "chrome-extension://\(id)/", path: path, input: toHost[0],
                                                 output: fromHost[1], responseTimeout: 0.3, homeDirectory: home)
            exited.fulfill()
        }
        let ready = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: path), Date() < ready { usleep(10_000) }
        let response = try ChromeProfileConnection.request(["operation": "browser_status", "session": "s"], path: path)
        XCTAssertEqual(response["ok"] as? Bool, false)
        XCTAssertTrue((response["error"] as? String)?.contains("did not answer") == true, "\(response)")
        wait(for: [exited], timeout: 5)
    }

    func testExtensionStatusNamesEveryStateInsteadOfFailing() throws {
        // An agent that only saw "bridge closed the connection" concluded the extension was not
        // working while Chrome showed it connected. Each state must be told apart, with what to do.
        typealias Failure = ChromeProfileConnection.Failure
        func status(registered: Bool = true, _ send: @escaping ([String: Any], TimeInterval) throws -> [String: Any]) -> [String: Any] {
            ChromeProfileConnection.extensionStatus(registered: registered, send: send)
        }
        let unregistered = status(registered: false) { _, _ in XCTFail("must not ask an extension that is not registered"); return [:] }
        XCTAssertEqual(unregistered["state"] as? String, "not_installed")
        XCTAssertTrue((unregistered["hint"] as? String)?.contains("install-chrome-host") == true)

        let closed = status { _, _ in throw Failure(message: "Google Chrome is not running.", kind: .notConnected) }
        XCTAssertEqual(closed["state"] as? String, "not_connected")
        XCTAssertEqual(closed["connected"] as? Bool, false)
        XCTAssertEqual(closed["hint"] as? String, "Google Chrome is not running.")

        // Another client's long call is not a broken extension.
        let busy = status { _, _ in throw Failure(message: "timed out", kind: .timedOut) }
        XCTAssertEqual(busy["state"] as? String, "busy")
        XCTAssertEqual(busy["connected"] as? Bool, true)

        // Files on disk are newer than what Chrome loaded until the extension is reloaded.
        for stale in [["ok": true, "connected": true], ["ok": true, "connected": true, "version": "1.4.1"]] as [[String: Any]] {
            let outdated = status { _, _ in stale }
            XCTAssertEqual(outdated["state"] as? String, "outdated")
            XCTAssertTrue((outdated["hint"] as? String)?.contains("Reload") == true)
        }
        for version in [ChromeProfileConnection.minimumExtensionVersion, "1.10.0"] {
            var asked: TimeInterval = 0
            let current = status { request, timeout in
                asked = timeout
                XCTAssertEqual(request["operation"] as? String, "browser_status")
                return ["id": "x", "ok": true, "connected": true, "hasTab": false, "version": version]
            }
            XCTAssertEqual(current["state"] as? String, "connected", version)
            XCTAssertNil(current["hint"])
            XCTAssertNil(current["id"])
            XCTAssertLessThanOrEqual(asked, 2, "a status question must not wait on a page")
        }
    }

    func testBrowserStatusToolAnswersWithAStateWhenTheBridgeIsDown() async throws {
        let backend = ChromeProfileComputerUseBackend(send: { _ in
            throw ChromeProfileConnection.Failure(message: "The mac-use Chrome extension is not connected.", kind: .notConnected)
        })
        let result = await backend.invoke(name: "browser_status", arguments: [:])
        XCTAssertFalse(result.isError, "status is an answer, not a failure")
        let status = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(result.content.first?.text).utf8)) as? [String: Any])
        XCTAssertEqual(status["state"] as? String, "not_connected")
        // Tools that need the extension still fail, with the same explanation.
        let open = await backend.invoke(name: "browser_open", arguments: ["url": "https://example.com"])
        XCTAssertTrue(open.isError)
        XCTAssertTrue(open.content.first?.text?.contains("not connected") == true)
    }

    func testRequestWaitsOutAnExtensionReconnectButNotAClosedChrome() throws {
        // After any drop the extension reconnects about a second later; a call landing in that
        // gap used to fail and send the agent off to slower routes.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mu-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("b.sock").path
        XCTAssertFalse(ChromeProfileConnection.hostListening(path: path))

        let started = Date()
        XCTAssertThrowsError(try ChromeProfileConnection.request(["operation": "browser_status"], path: path, chromeRunning: { false })) {
            XCTAssertTrue($0.localizedDescription.contains("not running"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "nothing to wait for when Chrome is closed")

        Thread.detachNewThread {
            usleep(400_000)
            let listener = socket(AF_UNIX, SOCK_STREAM, 0)
            guard var address = try? ChromeProfileConnection.address(path) else { return }
            _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            listen(listener, 1)
            let client = accept(listener, nil, nil)
            if let request = try? ChromeProfileConnection.readFrame(fd: client, until: Date().addingTimeInterval(2)) {
                try? ChromeProfileConnection.writeFrame(["id": request["id"] ?? "", "ok": true, "connected": true], fd: client, until: Date().addingTimeInterval(2))
            }
            close(client)
            close(listener)
        }
        let response = try ChromeProfileConnection.request(["operation": "browser_status"], path: path, chromeRunning: { true })
        XCTAssertEqual(response["connected"] as? Bool, true)
    }

    func testChromeWindowObservationsPointAtTheBrowserToolsOnlyWhenTheyAreUsable() {
        // The agent kept clicking pixels in the Chrome window while a working extension sat idle.
        let chrome: (Int32) -> String? = { $0 == 7 ? "com.google.Chrome" : "com.apple.finder" }
        XCTAssertTrue(ManagedComputerUseMCP.browserToolsHint(pid: 7, bundleID: chrome, extensionConnected: { true })?.contains("browser_open") == true)
        XCTAssertNil(ManagedComputerUseMCP.browserToolsHint(pid: 7, bundleID: chrome, extensionConnected: { false }))
        XCTAssertNil(ManagedComputerUseMCP.browserToolsHint(pid: 8, bundleID: chrome, extensionConnected: { true }))
        XCTAssertNil(ManagedComputerUseMCP.browserToolsHint(pid: nil, bundleID: chrome, extensionConnected: { true }))
    }

    func testEveryBrowserToolThatActsOnThePageAcceptsTheEscalationFlag() throws {
        // A schema with additionalProperties:false that omits the flag would make the client
        // reject the retry the human_activity error asks for.
        for name in ChromeProfileComputerUseBackend.tools where !["browser_status", "browser_open", "browser_close", "browser_dialog"].contains(name) {
            let schema = try XCTUnwrap(ManagedComputerUseMCP.toolCatalog().first { $0["name"] as? String == name }?["inputSchema"] as? [String: Any], name)
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any], name)
            XCTAssertNotNil(properties["allow_while_user_active"], name)
        }
    }

    func testBrowserMCPRoutesToOwnSessionAndPropagatesFailure() async throws {
        let backend = ChromeProfileComputerUseBackend(send: { request in
            let operation = request["operation"] as? String
            if operation == "browser_act" { return ["id": request["id"] ?? "", "ok": false, "error": "human_activity"] }
            return ["ok": true, "connected": true, "operation": operation ?? ""]
        })
        let handler = ManagedComputerUseMCP(browser: backend)
        for (name, arguments, expectedError) in [("browser_status", "{}", false), ("browser_act", #"{"action":"click","ref":"stale"}"#, true)] {
            let line = """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"\(name)","arguments":\(arguments)}}
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
