@testable import Mux
import XCTest

/// The daemon speaks one JSON object per line; these pin what the app
/// makes of `muxd ls --json` and `muxd watch --json`, above all that an
/// agent object this build does not understand costs the agent, not the
/// line.
final class MuxdDecodingTests: XCTestCase {
    private func event(_ line: String) -> Muxd.WatchEvent? {
        Muxd.decode(line[...])
    }

    func testWatchEventCarriesAgentAndCwd() throws {
        let line = """
        {"name":"11111111-1111-1111-1111-111111111111",\
        "agent":{"agent":"claude","state":"working","topic":"fix the tests"},"cwd":"/tmp","exited":false}
        """
        let event = try XCTUnwrap(event(line))
        XCTAssertEqual(event.name, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(event.agent, Muxd.AgentInfo(agent: .claude, state: .working, topic: "fix the tests"))
        XCTAssertEqual(event.cwd, "/tmp")
        XCTAssertFalse(event.exited)
    }

    func testNullAndMissingAgentAreNoAgent() throws {
        let null = try XCTUnwrap(event(#"{"name":"a","agent":null,"cwd":null,"exited":true}"#))
        XCTAssertNil(null.agent)
        XCTAssertNil(null.cwd)
        XCTAssertTrue(null.exited)
        let missing = try XCTUnwrap(event(#"{"name":"a","exited":false}"#))
        XCTAssertNil(missing.agent)
    }

    func testUnknownAgentOrStateDropsTheAgentNotTheLine() throws {
        let state = try XCTUnwrap(event(
            #"{"name":"a","agent":{"agent":"codex","state":"dreaming","topic":""},"exited":false}"#
        ))
        XCTAssertNil(state.agent)
        XCTAssertEqual(state.name, "a")
        let agent = try XCTUnwrap(event(
            #"{"name":"a","agent":{"agent":"gemini","state":"idle","topic":""},"exited":false}"#
        ))
        XCTAssertNil(agent.agent)
    }

    func testLogLinesAndBrokenJsonAreSkipped() {
        XCTAssertNil(event("muxd: connecting"))
        XCTAssertNil(event(#"{"name":"a""#))
        XCTAssertNil(event(#"{"agent":null,"exited":false}"#))
    }

    func testListingCarriesAgent() throws {
        let line = """
        {"name":"a","command":["/bin/zsh"],"attached":true,"exited":false,"cwd":"/x",\
        "agent":{"agent":"codex","state":"blocked","topic":"mux"}}
        """
        let listing: Muxd.PtyListing = try XCTUnwrap(Muxd.decode(line[...]))
        XCTAssertEqual(listing.agent, Muxd.AgentInfo(agent: .codex, state: .blocked, topic: "mux"))
        let bare: Muxd.PtyListing = try XCTUnwrap(Muxd.decode(
            #"{"name":"a","command":[],"attached":false,"exited":false,"cwd":null}"#[...]
        ))
        XCTAssertNil(bare.agent)
    }
}

/// The process side of the watch: a long-running helper read one line at
/// a time, on the main thread, with the exit reported after the last
/// line - whatever chunking the pipe delivers.
final class SubprocessStreamTests: XCTestCase {
    func testStreamDeliversWholeLinesThenExit() {
        var lines: [Substring] = []
        let exited = expectation(description: "exit")
        let stream = Subprocess.Stream(
            "/bin/sh", ["-c", "printf 'one\\ntw'; printf 'o\\nthree\\n'; printf 'tail'"],
            onLine: { lines.append($0) },
            onExit: { exited.fulfill() }
        )
        XCTAssertNotNil(stream)
        wait(for: [exited], timeout: 5)
        // A last fragment with no newline is not a line.
        XCTAssertEqual(lines, ["one", "two", "three"])
    }
}
