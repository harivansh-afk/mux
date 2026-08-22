// What a coding agent in a pane announces through the terminal title.
//
// Agents talk to the terminal only through OSC 0/2, so the title is the one
// channel mux reads. Each agent has its own grammar, pinned here and in
// AgentsTests against the version it was read from:
//
// claude (Claude Code 2.1.240; braille spinner up to 2.1.227):
//   "<spinner> <topic>"   working   spinner is U+2800-28FF or U+25D0-25D3
//   "\u{2733} <topic>"    idle      U+2733 EIGHT SPOKED ASTERISK
//
// codex (codex-cli 0.149.0, default `tui.terminal_title = [activity,
// project-name]`, read from codex-rs/tui/src/chatwidget/status_surfaces.rs):
//   "<spinner> <project>"                  working   ten braille frames
//   "<project>"                            idle      the spinner is omitted
//   "[ ! ] Action Required | <project>"    blocked   blinks to "[ . ]"
//   ""                                     on exit   the title is cleared
//
// A bare project name is only codex when codex was already seen in this
// pane, so the tracker keeps the agent between titles. Identity also comes
// from ghostty's shell integration, which writes the command line as the
// title right before it runs ("codex", "claude --resume"): that is what
// names the agent before it has drawn anything, and what lets a codex with
// animations off (no spinner, ever) still show its project.
//
// Shell titles (the cwd at each prompt) are not topics: the stage already
// shows the directory. A pane with no agent reads as nothing.

public enum Agent: Equatable, Sendable {
    case claude
    case codex
}

public enum AgentState: Equatable, Sendable {
    case working
    case idle
    case blocked
}

/// One title, read: which agent, what it is doing, and the text after the
/// state marker (the topic or project).
public struct AgentReading: Equatable, Sendable {
    public var agent: Agent?
    public var state: AgentState?
    public var topic: String

    public static let none = AgentReading(agent: nil, state: nil, topic: "")

    public init(agent: Agent?, state: AgentState?, topic: String) {
        self.agent = agent
        self.state = state
        self.topic = topic
    }
}

/// Reads titles in order and keeps the agent identity between them.
public struct AgentTracker: Sendable {
    private var agent: Agent?

    public init() {}

    public mutating func observe(_ title: String) -> AgentReading {
        let reading = read(title)
        agent = reading.agent
        return reading
    }

    private func read(_ title: String) -> AgentReading {
        let trimmed = trim(title)
        if trimmed.isEmpty {
            return .none
        }

        if let project = Self.codexBlocked(trimmed) {
            return AgentReading(agent: .codex, state: .blocked, topic: project)
        }

        // A state glyph counts only when a space follows it in the raw
        // title, where the agent wrote it.
        let scalars = trimmed.unicodeScalars
        if let glyph = scalars.first, scalars.dropFirst().first == " " {
            let rest = trim(String(scalars.dropFirst()))
            switch glyph.value {
            case 0x25D0 ... 0x25D3:
                return AgentReading(agent: .claude, state: .working, topic: rest)
            case 0x2800 ... 0x28FF:
                // Braille is claude before 2.1.228 and every codex; keep
                // whichever was already named, else leave it unnamed.
                return AgentReading(agent: agent, state: .working, topic: rest)
            case 0x2733:
                return AgentReading(agent: .claude, state: .idle, topic: rest)
            default:
                break
            }
        }

        if let named = Self.command(trimmed) {
            return AgentReading(agent: named, state: nil, topic: "")
        }

        // codex drops the spinner when idle and clears the title on exit,
        // so a plain title after codex is codex at rest. claude never
        // writes a bare title; one after claude is the shell's.
        if agent == .codex {
            return AgentReading(agent: .codex, state: .idle, topic: trimmed)
        }
        return .none
    }

    /// "[ ! ] Action Required | project" and its blink phase. The project
    /// follows the first " | "; with `activity` alone there is none.
    private static func codexBlocked(_ title: String) -> String? {
        guard title.hasPrefix("[ ! ] Action Required") || title.hasPrefix("[ . ] Action Required")
        else { return nil }
        guard let bar = title.firstRange(of: " | ") else { return "" }
        return trim(String(title[bar.upperBound...]))
    }

    /// The command line ghostty's shell integration writes as the title at
    /// preexec: the program name, alone or followed by arguments.
    private static func command(_ title: String) -> Agent? {
        let word = title.split(separator: " ", maxSplits: 1).first.map(String.init) ?? title
        let name = word.split(separator: "/").last.map(String.init) ?? word
        switch name {
        case "claude": return .claude
        case "codex": return .codex
        default: return nil
        }
    }
}

/// ASCII blanks only; the title is one line and the agents write spaces.
private func trim(_ title: String) -> String {
    var rest = Substring(title)
    while let first = rest.first, first == " " || first == "\t" {
        rest = rest.dropFirst()
    }
    while let last = rest.last, last == " " || last == "\t" {
        rest = rest.dropLast()
    }
    return String(rest)
}
