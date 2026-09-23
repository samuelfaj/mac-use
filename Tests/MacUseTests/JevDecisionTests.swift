import Foundation
import XCTest
@testable import MacUse

private actor TestJev: JevTransport {
    var captured: [String: Any]?
    let selected: String
    let probability: Double
    let confidence: Double
    let completion: Double
    let consequential: Double
    let authorization: Double

    init(selected: String = "e0", probability: Double = 0.99, confidence: Double = 0.99,
         completion: Double = 0, consequential: Double = 0, authorization: Double = 0.99) {
        self.selected = selected
        self.probability = probability
        self.confidence = confidence
        self.completion = completion
        self.consequential = consequential
        self.authorization = authorization
    }

    func evaluate(_ request: [String: Any]) async throws -> [String: Any] {
        captured = request
        let questions = request["questions"] as! [String: [String: Any]]
        let next = questions["next"]!["criteria"] as! [String: String]
        var distribution = Dictionary(uniqueKeysWithValues: next.keys.map { ($0, 0.0) })
        distribution[selected] = probability
        let others = next.keys.filter { $0 != selected }.sorted()
        if let first = others.first { distribution[first] = 1 - probability }
        return ["answers": [
            "next": ["choice": selected, "confidence": confidence, "probabilities": distribution],
            "complete": ["noul": completion],
            "consequential": ["noul": consequential],
            "authorized": ["noul": authorization],
        ]]
    }

    func request() -> [String: Any]? { captured }
}

private struct ObservationBackend: ComputerUseToolBackend {
    let observation: String
    func invoke(name: String, arguments: [String: Any]) async -> ComputerUseToolResult {
        guard name == "get_ui_tree" else { return ComputerUseToolResult(text: "unexpected native mutation", isError: true) }
        return ComputerUseToolResult(text: observation)
    }
}

final class JevDecisionTests: XCTestCase {
    private let observation = """
    {"user_activity":"none","is_on_screen":true,"is_minimized":false,"permissions":{"accessibility":true},"state_token":"private-token","target_pid":123}
    ui_tree: {"role":"AXWindow","value":"private message","children":[{"role":"AXButton","title":"Send"},{"role":"AXTextField","value":"secret text"}]}
    """

    func testJevOnlyReceivesAllowlistedLabelsNeverWindowTokenOrFieldValues() async throws {
        let transport = TestJev()
        let proposal = try await JevDecision(transport: transport).advise(goal: "Click Send", observation: observation)
        XCTAssertEqual(proposal.operation, "click_element")
        XCTAssertEqual(proposal.role, "AXButton")
        let captured = await transport.request()
        let request = try XCTUnwrap(captured)
        let payload = String(data: try JSONSerialization.data(withJSONObject: request), encoding: .utf8)!
        XCTAssertTrue(payload.contains("Send"))
        XCTAssertFalse(payload.contains("private-token"))
        XCTAssertFalse(payload.contains("private message"))
        XCTAssertFalse(payload.contains("secret text"))
        XCTAssertFalse(payload.contains("target_pid"))
    }

    func testCredentialBearingGoalNeverLeavesMac() async {
        let transport = TestJev()
        do {
            _ = try await JevDecision(transport: transport).advise(
                goal: "my password is hunter2; click Send", observation: observation)
            XCTFail("A credential-bearing goal must not be sent to Jev")
        } catch {
            let captured = await transport.request()
            XCTAssertNil(captured)
        }
    }

    func testHumanActivityStopsBeforeJevRequest() async {
        let transport = TestJev()
        do {
            _ = try await JevDecision(transport: transport).advise(
                goal: "Click Send", observation: observation.replacingOccurrences(of: "\"none\"", with: "\"human\""))
            XCTFail("Human activity must prevent remote evaluation")
        } catch {
            let captured = await transport.request()
            XCTAssertNil(captured)
        }
    }

    func testConsequentialClickRequiresExplicitAuthorization() async throws {
        let blocked = TestJev(consequential: 0.95, authorization: 0.2)
        let result = try await JevDecision(transport: blocked).advise(goal: "Find Send", observation: observation)
        XCTAssertEqual(result.operation, "BLOCKED")
        let permitted = TestJev(consequential: 0.95, authorization: 0.99)
        let allowed = try await JevDecision(transport: permitted).advise(goal: "Send", observation: observation)
        XCTAssertEqual(allowed.operation, "click_element")
    }

    func testMaterialButtonRequiresStrongGatesEvenIfModelMisclassifiesIt() async throws {
        let transport = TestJev(probability: 0.70, confidence: 0.8, consequential: 0, authorization: 0.99)
        let result = try await JevDecision(transport: transport).advise(goal: "Send", observation: observation)
        XCTAssertEqual(result.operation, "BLOCKED")
    }

    func testDoneNeedsIndependentCompletionEvidence() async throws {
        let transport = TestJev(selected: "DONE", completion: 0.5)
        let result = try await JevDecision(transport: transport).advise(goal: "Send", observation: observation)
        XCTAssertEqual(result.operation, "BLOCKED")
    }

    func testMCPJevToolReturnsProposalAndTokenWithoutExecutingInput() async throws {
        let lock = FileManager.default.temporaryDirectory.appendingPathComponent("mac-use-tests-\(UUID().uuidString)/computer-use.lock")
        let handler = ManagedComputerUseMCP(
            queue: ComputerUseHostQueue(lockURL: lock),
            backend: ObservationBackend(observation: observation),
            jev: JevDecision(transport: TestJev())
        )
        let call = #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"jev_decide","arguments":{"goal":"Click Send","target_pid":123,"target_window_id":9}}}"#
        let reply = await handler.handle(call)
        let response = try XCTUnwrap(reply)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let parts = try XCTUnwrap(result["content"] as? [[String: Any]])
        let proposal = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((parts[0]["text"] as! String).utf8)) as? [String: Any])
        XCTAssertEqual(proposal["operation"] as? String, "click_element")
        XCTAssertEqual(proposal["expected_state_token"] as? String, "private-token")
    }

    func testTitleCannotResolveToAnotherButtonsDescription() async throws {
        let ambiguous = observation.replacingOccurrences(
            of: #"{"role":"AXButton","title":"Send"}"#,
            with: #"{"role":"AXButton","title":"Delete","description":"Send"},{"role":"AXButton","title":"Send"}"#
        )
        let transport = TestJev(selected: "BLOCKED")
        _ = try await JevDecision(transport: transport).advise(goal: "Send", observation: ambiguous)
        let captured = await transport.request()
        let request = try XCTUnwrap(captured)
        let state = request["state"] as! [String: Any]
        let visible = state["visibleElements"] as! [[String: String]]
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible[0]["label"], "Delete")
    }

    func testDuplicateSemanticTargetsNeverProposed() async throws {
        let duplicated = observation.replacingOccurrences(
            of: "{\"role\":\"AXTextField\",\"value\":\"secret text\"}",
            with: "{\"role\":\"AXButton\",\"title\":\"Send\"}")
        let transport = TestJev(selected: "BLOCKED")
        _ = try await JevDecision(transport: transport).advise(goal: "Send", observation: duplicated)
        let captured = await transport.request()
        let request = try XCTUnwrap(captured)
        let state = request["state"] as! [String: Any]
        XCTAssertTrue((state["visibleElements"] as! [[String: String]]).isEmpty)
    }
}
