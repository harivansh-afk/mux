//! Which coding agent runs in a pane and what it is doing.
//!
//! Identity is a process name: the pty's foreground process, looked up in
//! the name table below. State is the per-agent manifest in `engine`
//! evaluated over the terminal title and the screen tail; both are
//! daemon-side facts, read from the pty and the terminal muxd already
//! tracks. Nothing here touches the network or the filesystem.
//!
//! The name table and the manifests are the upstream detector's
//! (Apache-2.0, LICENSE-upstream); the manifests are copied as data so a
//! newer upstream rule set is a file copy.

mod engine;

pub use engine::{detect, Detection, DetectionInput};

// Each row owns the variant, manifest file, wire label and command aliases.
macro_rules! agents {
    ($($variant:ident => $file:literal: $label:literal $(| $alias:literal)*),+ $(,)?) => {
        #[derive(Debug, Clone, Copy, PartialEq, Eq)]
        pub enum Agent { $($variant),+ }

        impl Agent {
            pub const ALL: &[Self] = &[$(Self::$variant),+];

            pub fn label(self) -> &'static str {
                match self { $(Self::$variant => $label),+ }
            }

            fn manifest(self) -> &'static str {
                match self {
                    $(Self::$variant => include_str!(concat!("manifests/", $file, ".toml"))),+
                }
            }
        }

        fn parse_agent_label(name: &str) -> Option<Agent> {
            let name = name.trim().to_lowercase();
            let name = [".exe", ".cmd", ".bat", ".ps1", ".js"].into_iter()
                .find_map(|suffix| name.strip_suffix(suffix)).unwrap_or(&name);
            match name {
                $($label $(| $alias)* => Some(Agent::$variant),)+
                _ => None,
            }
        }
    };
}

agents! {
    Pi => "pi": "pi",
    Claude => "claude": "claude" | "claude-code",
    Codex => "codex": "codex",
    Gemini => "gemini": "gemini",
    Cursor => "cursor": "cursor" | "cursor-agent",
    Devin => "devin": "devin" | "devin-cli" | "devin cli",
    Antigravity => "antigravity": "agy" | "antigravity" | "antigravity-cli",
    Cline => "cline": "cline",
    OpenCode => "opencode": "opencode" | "opencode2" | "open-code",
    GithubCopilot => "github-copilot": "copilot" | "github-copilot" | "ghcs",
    Kimi => "kimi": "kimi" | "kimi-code" | "kimi code",
    Kiro => "kiro": "kiro" | "kiro-cli",
    Droid => "droid": "droid",
    Amp => "amp": "amp" | "amp-local",
    Grok => "grok": "grok" | "grok-build",
    Hermes => "hermes": "hermes" | "hermes-agent",
    Kilo => "kilo": "kilo" | "kilo-code" | "kilo code",
    Qodercli => "qodercli": "qodercli" | "qoderclicn" | "qoder" | "qodercn",
    Qwen => "qwen": "qwen" | "qwen-code" | "qwen code",
    Maki => "maki": "maki",
}

impl Agent {
    /// The agent behind a process name (`claude`, `codex`, a path to
    /// either, `codex.exe`); None for shells and everything else.
    #[must_use]
    pub fn from_process_name(name: &str) -> Option<Self> {
        let basename = name.rsplit('/').next().unwrap_or(name);
        parse_agent_label(basename)
    }

    /// Native agents use argv[0]; npm launchers use `node <agent-script>`.
    /// Only the script position identifies an agent, never arbitrary arguments.
    #[must_use]
    pub fn from_command(argv: &[String]) -> Option<Self> {
        let executable = argv.first()?;
        Self::from_process_name(executable).or_else(|| match executable.rsplit('/').next()? {
            "node" | "nodejs" | "bun" => Self::from_process_name(argv.get(1)?),
            _ => None,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AgentState {
    /// The prompt is up and nothing is happening.
    Idle,
    /// Busy.
    Working,
    /// Waiting on a person.
    Blocked,
}

impl AgentState {
    #[must_use]
    pub fn label(self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Working => "working",
            Self::Blocked => "blocked",
        }
    }
}

/// What the agent says it is on, read from its title with the state
/// marker taken off: claude's topic after its spinner or U+2733, codex's
/// project after its spinner or after "Action Required | ". Empty when
/// the title carries nothing else.
#[must_use]
pub fn topic(title: &str) -> String {
    let title = title.trim();
    if title.starts_with("[ ! ] Action Required") || title.starts_with("[ . ] Action Required") {
        return title
            .split_once(" | ")
            .map_or("", |(_, rest)| rest)
            .trim()
            .to_string();
    }
    let mut scalars = title.chars();
    let glyph = scalars.next().map_or(0, u32::from);
    let marker = matches!(glyph, 0x2800..=0x28FF | 0x25D0..=0x25D3 | 0x2733);
    if marker && scalars.next() == Some(' ') {
        return scalars.as_str().trim().to_string();
    }
    title.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn process_names_name_agents() {
        assert_eq!(Agent::from_process_name("claude"), Some(Agent::Claude));
        assert_eq!(
            Agent::from_process_name("/Users/x/.local/bin/claude"),
            Some(Agent::Claude)
        );
        assert_eq!(Agent::from_process_name("codex"), Some(Agent::Codex));
        assert_eq!(Agent::from_process_name("codex.exe"), Some(Agent::Codex));
        assert_eq!(Agent::from_process_name("zsh"), None);
        assert_eq!(Agent::from_process_name("node"), None);
        assert_eq!(Agent::from_process_name(""), None);
    }

    #[test]
    fn topics_drop_the_state_marker() {
        assert_eq!(topic("\u{25D0} fix the flaky test"), "fix the flaky test");
        assert_eq!(topic("\u{280B} fix the flaky test"), "fix the flaky test");
        assert_eq!(topic("\u{2733} fix the flaky test"), "fix the flaky test");
        assert_eq!(topic("\u{2733}glued"), "\u{2733}glued");
        assert_eq!(topic("[ ! ] Action Required | mux"), "mux");
        assert_eq!(topic("[ . ] Action Required"), "");
        assert_eq!(topic("mux"), "mux");
        assert_eq!(topic("  "), "");
    }

    #[test]
    fn npm_launchers_identify_the_script_not_other_arguments() {
        for (argv, expected) in [
            (
                vec!["/usr/bin/node", "/home/user/.local/bin/codex", "resume"],
                Some(Agent::Codex),
            ),
            (vec!["nodejs", "/opt/codex.js"], Some(Agent::Codex)),
            (vec!["bun", "/opt/claude"], Some(Agent::Claude)),
            (
                vec!["/opt/codex", "--model", "anything"],
                Some(Agent::Codex),
            ),
            (vec!["node", "server.js", "codex"], None),
            (vec!["node", "-e", "codex"], None),
            (vec!["cat", "codex"], None),
            (vec!["node"], None),
            (vec![], None),
        ] {
            let argv: Vec<_> = argv.into_iter().map(String::from).collect();
            assert_eq!(Agent::from_command(&argv), expected, "{argv:?}");
        }
    }

    #[test]
    fn every_agent_has_a_bundled_manifest() {
        for &agent in Agent::ALL {
            let input = DetectionInput {
                screen: "",
                osc_title: "",
                osc_progress: "",
            };
            let _ = detect(agent, input);
        }
    }
}
