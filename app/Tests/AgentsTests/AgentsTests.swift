import Agents
import XCTest

/// Every string here is what the named agent version writes to OSC 0/2.
/// When an agent changes its title grammar, the failing test names the
/// version that moved.
final class AgentsTests: XCTestCase {
    private func read(_ titles: String...) -> AgentReading {
        var tracker = AgentTracker()
        var last = AgentReading.none
        for title in titles {
            last = tracker.observe(title)
        }
        return last
    }

    // MARK: claude (Claude Code 2.1.240)

    func testClaudeWorkingHalfCircle() {
        XCTAssertEqual(
            read("\u{25D0} fix the flaky test"),
            AgentReading(agent: .claude, state: .working, topic: "fix the flaky test")
        )
        for glyph in ["\u{25D1}", "\u{25D2}", "\u{25D3}"] {
            XCTAssertEqual(read("\(glyph) x").state, .working)
        }
    }

    func testClaudeWorkingBrailleBefore2_1_228() {
        XCTAssertEqual(
            read("\u{280B} fix the flaky test"),
            AgentReading(agent: nil, state: .working, topic: "fix the flaky test")
        )
        XCTAssertEqual(
            read("claude", "\u{280B} fix the flaky test"),
            AgentReading(agent: .claude, state: .working, topic: "fix the flaky test")
        )
    }

    func testClaudeIdle() {
        XCTAssertEqual(
            read("\u{2733} fix the flaky test"),
            AgentReading(agent: .claude, state: .idle, topic: "fix the flaky test")
        )
    }

    func testGlyphWithoutSpaceIsNotState() {
        XCTAssertEqual(read("\u{2733}flaky"), .none)
        XCTAssertEqual(read("\u{25D0}flaky"), .none)
    }

    func testShellTitleAfterClaudeIsNotClaude() {
        XCTAssertEqual(read("\u{2733} done", "~/src/mux"), .none)
    }

    // MARK: codex (codex-cli 0.149.0, terminal_title = [activity, project-name])

    func testCodexWorkingFrames() {
        for frame in ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"] {
            XCTAssertEqual(
                read("codex", "\(frame) mux"),
                AgentReading(agent: .codex, state: .working, topic: "mux")
            )
        }
    }

    func testCodexIdleIsTheBareProjectAfterCodex() {
        XCTAssertEqual(
            read("codex", "⠋ mux", "mux"),
            AgentReading(agent: .codex, state: .idle, topic: "mux")
        )
    }

    func testCodexBlockedBothBlinkPhases() {
        XCTAssertEqual(
            read("[ ! ] Action Required | mux"),
            AgentReading(agent: .codex, state: .blocked, topic: "mux")
        )
        XCTAssertEqual(
            read("[ . ] Action Required | mux"),
            AgentReading(agent: .codex, state: .blocked, topic: "mux")
        )
        XCTAssertEqual(
            read("[ ! ] Action Required"),
            AgentReading(agent: .codex, state: .blocked, topic: "")
        )
    }

    func testCodexClearsOnExitAndTheShellTitleIsNothing() {
        XCTAssertEqual(read("codex", "⠋ mux", "mux", ""), .none)
        XCTAssertEqual(read("codex", "⠋ mux", "mux", "", "~/src/mux"), .none)
    }

    func testCodexWithAnimationsOffIsNamedByTheShell() {
        XCTAssertEqual(
            read("codex --profile fast", "mux"),
            AgentReading(agent: .codex, state: .idle, topic: "mux")
        )
    }

    // MARK: shells and other programs

    func testBareTitlesAreNothing() {
        XCTAssertEqual(read(""), .none)
        XCTAssertEqual(read("~/src/mux"), .none)
        XCTAssertEqual(read("nvim"), .none)
        XCTAssertEqual(read("mux"), .none)
    }

    func testCommandNamesTheAgentWithoutState() {
        XCTAssertEqual(read("claude"), AgentReading(agent: .claude, state: nil, topic: ""))
        XCTAssertEqual(read("/opt/homebrew/bin/codex -m o3"), AgentReading(agent: .codex, state: nil, topic: ""))
        XCTAssertEqual(read("claude-code-is-not-claude"), .none)
    }

    func testWhitespaceAroundTheTitle() {
        XCTAssertEqual(
            read("  \u{2733} done  "),
            AgentReading(agent: .claude, state: .idle, topic: "done")
        )
    }
}
