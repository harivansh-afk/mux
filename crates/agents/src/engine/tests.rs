//! The upstream engine's tests for what this crate kept: the bundled
//! manifests parse, validation rejects what it should, regions slice as
//! documented, and the claude and codex rules read real titles and
//! screens. The rule ids named here are the manifests'.

use std::fmt::Write as _;

use super::*;

fn detect_with(agent: Agent, screen: &str, osc_title: &str, osc_progress: &str) -> Detection {
    detect(
        agent,
        DetectionInput {
            screen,
            osc_title,
            osc_progress,
        },
    )
}

fn detect_screen(agent: Agent, screen: &str) -> Detection {
    detect_with(agent, screen, "", "")
}

fn detect_manifest(manifest: &str, screen: &str) -> Detection {
    let manifest = parse_manifest(manifest).expect("test manifest parses");
    let compiled_rules = compile_manifest(&manifest).expect("test manifest compiles");
    let loaded: &'static LoadedManifest = Box::leak(Box::new(LoadedManifest {
        manifest,
        compiled_rules,
    }));
    evaluate(
        loaded,
        DetectionInput {
            screen,
            osc_title: "",
            osc_progress: "",
        },
    )
}

#[test]
fn known_agent_with_no_matching_rule_is_idle() {
    let detection = detect_screen(Agent::Codex, "ordinary prompt text");
    assert_eq!(detection.state, Some(AgentState::Idle));
    assert_eq!(detection.rule, None);
}

#[test]
fn rule_semantics_apply_gates_priority_and_line_regex() {
    let manifest = r#"
id = "codex"

[[rules]]
id = "low_contains"
state = "idle"
priority = 1
contains = ["match"]

[[rules]]
id = "high_nested_gates"
state = "working"
priority = 10
contains = ["match"]
all = [
  { any = [{ regex = ["w[io]n"] }, { contains = ["fallback"] }] },
]
not = [
  { contains = ["blocked"] },
]

[[rules]]
id = "line_regex"
state = "blocked"
priority = 20
line_regex = ["^exact line$"]
"#;

    let high = detect_manifest(manifest, "match win");
    assert_eq!(high.state, Some(AgentState::Working));
    assert_eq!(high.rule, Some("high_nested_gates"));

    let not_gate = detect_manifest(manifest, "match win blocked");
    assert_eq!(not_gate.state, Some(AgentState::Idle));
    assert_eq!(not_gate.rule, Some("low_contains"));

    let line = detect_manifest(manifest, "before\nexact line\nafter");
    assert_eq!(line.state, Some(AgentState::Blocked));
    assert_eq!(line.rule, Some("line_regex"));
}

#[test]
fn a_manifest_from_a_newer_engine_is_refused() {
    assert!(parse_manifest(
        r#"
id = "codex"
min_engine_version = 99

[[rules]]
id = "ready"
state = "idle"
contains = ["ready"]
"#
    )
    .is_err());
}

#[test]
fn all_bundled_manifests_parse_and_validate() {
    for agent in Agent::ALL {
        assert!(
            bundled_manifest(agent).is_some(),
            "missing bundled manifest for {}",
            agent_label(agent)
        );
    }
}

#[test]
fn devin_manifest_detects_idle_working_and_blocked_states() {
    let idle = detect_screen(
        Agent::Devin,
        "─────────────────────────────────────────────────────\n❭ Ask Devin to build features, fix bugs, or work on\n  your code\n─────────────────────────────────────────────────────\nSWE-1.6               Context: 16k / 200k tokens (7%)",
    );
    assert_eq!(idle.state, Some(AgentState::Idle));

    let live_footer_idle = detect_screen(
        Agent::Devin,
        "Done.\n\n────────────────────────────────────────────────── (bypass permissions on) ─\n❭\n────────────────────────────────────────────────────────────────────────────\nClaude Opus 4.6 Thinking                                    Context: 38k / 200k tokens (18%)",
    );
    assert_eq!(live_footer_idle.state, Some(AgentState::Idle));
    assert_eq!(live_footer_idle.rule, Some("live_prompt_footer"));

    let welcome_footer_idle = detect_screen(
        Agent::Devin,
        "⠀⠀⠀⠀⠀⣴⣾⣶⡄⠀⠀⠀⠀\n⠀⣴⣾⣶⡾⠛⠿⠟⠃⣴⣾⣶⡄  Devin CLI\n⠀⠛⠿⠟⠃⣴⣾⣶⡾⠛⠿⠟⠃  v2026.5.26-8\n⠀⣤⣶⣦⡄⠻⢿⠿⢷⣤⣶⣦⡄\n⠀⠻⢿⠿⢷⣤⣶⣦⡄⠻⢿⠿⠃  Hybrid\n⠀⠀⠀⠀⠀⠻⢿⠿⠃⠀⠀⠀⠀\n\n───────────────────────────\n❭ Ask Devin to build\n  features, fix bugs, or\n  work on your code\n───────────────────────────\nClaude Opus Looking for\n4.6 Thinkingplan mode? /\n            plan",
    );
    assert_eq!(welcome_footer_idle.state, Some(AgentState::Idle));
    assert_eq!(welcome_footer_idle.rule, Some("welcome_prompt_footer"));

    let working = detect_screen(
        Agent::Devin,
        "◔ Reading shell 91b655\n  │ Timeout: 35s\n\n⠀⡆ Running tools · 27s (esc to interrupt)\n─────────────────────────────────────────────────────\n❭ Guide Devin while it works",
    );
    assert_eq!(working.state, Some(AgentState::Working));

    let trust_prompt = detect_screen(
        Agent::Devin,
        "Do you trust the authors of this directory?\nFor security, devin should not be run in directories\nwith untrusted content.\n❭ 1 Yes, trust /private/tmp/devin-hook-probe\n· 2 No, exit",
    );
    assert_eq!(trust_prompt.state, Some(AgentState::Blocked));

    let permission_prompt = detect_screen(
        Agent::Devin,
        "⏺ Running command\n  └ $ sleep 30\n\n❭ 1 Yes  (Approve once)\n· 2 Yes, allow `sleep` commands\n· 3 Yes, always allow `sleep` commands\n· 4 No\n↑↓ select · ↵ confirm · esc cancel",
    );
    assert_eq!(permission_prompt.state, Some(AgentState::Blocked));
}

#[test]
fn manifest_validation_rejects_unknown_fields_empty_rules_invalid_regions_and_regexes() {
    assert!(parse_manifest(
        r#"
id = "codex"

[[rules]]
id = "typo"
state = "working"
contain = ["Working"]
"#
    )
    .is_err());

    assert!(parse_manifest(
        r#"
id = "codex"

[[rules]]
id = "empty"
state = "working"
"#
    )
    .is_err());

    assert!(parse_manifest(
        r#"
id = "codex"

[[rules]]
id = "bad_region"
state = "working"
region = "after_last_promt_marker"
contains = ["Working"]
"#
    )
    .is_err());

    assert!(parse_manifest(
        r#"
id = "codex"

[[rules]]
id = "bad_regex"
state = "working"
regex = ["["]
"#
    )
    .is_err());

    assert!(parse_manifest(
        r#"
id = "codex"

[[rules]]
id = "bad_nested_regex"
state = "working"
any = [{ line_regex = ["["] }]
"#
    )
    .is_err());
}

#[test]
fn manifest_validation_keeps_skip_rules_neutral() {
    assert!(parse_manifest(
        r#"
id = "codex"

[[rules]]
id = "bad_skip_state"
state = "idle"
skip_state_update = true
contains = ["menu"]
"#
    )
    .is_err());
}

#[test]
fn manifest_validation_rejects_excessive_rule_count() {
    let mut manifest = String::from(
        r#"
id = "codex"
"#,
    );
    for index in 0..129 {
        write!(
            manifest,
            r#"
[[rules]]
id = "rule_{index}"
state = "idle"
contains = ["ready"]
"#
        )
        .expect("write to a String");
    }

    assert!(parse_manifest(&manifest).is_err());
}

#[test]
fn manifest_validation_rejects_excessive_gate_depth() {
    let manifest = r#"
id = "codex"

[[rules]]
id = "deep"
state = "idle"
contains = ["ready"]
all = [
  { contains = ["1"], all = [
    { contains = ["2"], all = [
      { contains = ["3"], all = [
        { contains = ["4"], all = [
          { contains = ["5"], all = [
            { contains = ["6"], all = [
              { contains = ["7"], all = [
                { contains = ["8"], all = [
                  { contains = ["9"] },
                ] },
              ] },
            ] },
          ] },
        ] },
      ] },
    ] },
  ] },
]
"#;

    assert!(parse_manifest(manifest).is_err());
}

#[test]
fn manifest_validation_rejects_excessive_matchers() {
    let matchers = (0..33)
        .map(|index| format!(r#""m{index}""#))
        .collect::<Vec<_>>()
        .join(", ");
    let manifest = format!(
        r#"
id = "codex"

[[rules]]
id = "many"
state = "idle"
contains = [{matchers}]
"#
    );

    assert!(parse_manifest(&manifest).is_err());
}

#[test]
fn bottom_non_empty_lines_uses_bottom_occurrence_for_repeated_text() {
    let content = "marker\nold\n\nmiddle\nmarker\nnew\n";

    assert_eq!(
        region(
            DetectionInput {
                screen: content,
                osc_title: "",
                osc_progress: "",
            },
            "bottom_non_empty_lines(2)"
        ),
        "marker\nnew\n"
    );
}

#[test]
fn top_non_empty_lines_uses_top_occurrence_for_repeated_text() {
    let content = "\nmarker\nold\n\nmiddle\nmarker\nnew\n";

    assert_eq!(
        region(
            DetectionInput {
                screen: content,
                osc_title: "",
                osc_progress: "",
            },
            "top_non_empty_lines(2)"
        ),
        "\nmarker\nold\n"
    );
}

#[test]
fn top_non_empty_lines_requires_a_canonical_positive_bounded_count() {
    let name = "top_non_empty_lines";
    assert!(validate_region_name(&format!("{name}(1)")).is_ok());
    assert!(validate_region_name(&format!("{name}({})", u16::MAX)).is_ok());
    for count in ["0", "01", "+1", "65536", "999999999999999999999999"] {
        assert!(
            validate_region_name(&format!("{name}({count})")).is_err(),
            "{name} accepted invalid count {count}"
        );
    }
}

#[test]
fn claude_osc_title_braille_prefix_is_working() {
    // "⠂" is U+2802, in the braille block U+2800-U+28FF
    let result = detect_with(Agent::Claude, "", "⠂ project", "");
    assert_eq!(result.state, Some(AgentState::Working));
    assert_eq!(result.rule, Some("osc_title_working"));
}

#[test]
fn claude_osc_title_half_circle_frames_are_working() {
    for frame in ['◐', '◓', '◑', '◒'] {
        let title = format!("{frame} Initial conversation with Claude");
        let result = detect_with(Agent::Claude, "", &title, "");
        assert_eq!(result.state, Some(AgentState::Working), "frame {frame}");
        assert_eq!(result.rule, Some("osc_title_working"), "frame {frame}");
    }
}

#[test]
fn claude_osc_title_static_prefix_is_idle() {
    // "✳" is U+2733, static prefix when Claude is not working
    let result = detect_with(Agent::Claude, "", "✳ Claude Code", "");
    assert_eq!(result.state, Some(AgentState::Idle));
    assert_eq!(result.rule, Some("osc_title_idle"));
}

#[test]
fn claude_osc_progress_4_3_alone_does_not_force_working() {
    // Claude leaves progress stuck at 4;3 while waiting for permission, so
    // 4;3 must not be a working signal on its own. With no other evidence it
    // falls back to idle; blocked screen rules can win when present.
    let result = detect_with(Agent::Claude, "", "", "4;3;");
    assert_eq!(result.state, Some(AgentState::Idle));
}

#[test]
fn claude_blocker_screen_outranks_stale_osc_progress() {
    // Regression: progress 4;3 persists during permission prompts. The
    // blocked form on screen must win because no rule treats 4;3 as working.
    let blocker_screen =
        "──────────\n  1. Yes\n  2. No\n\nEnter to select · ↑/↓ to navigate · Esc to cancel\n";
    let result = detect_with(Agent::Claude, blocker_screen, "✳ Task title", "4;3;");
    assert_eq!(result.state, Some(AgentState::Blocked));
}

#[test]
fn claude_osc_progress_4_0_is_idle() {
    let result = detect_with(Agent::Claude, "", "", "4;0;");
    assert_eq!(result.state, Some(AgentState::Idle));
    assert_eq!(result.rule, Some("osc_progress_idle"));
}

#[test]
fn claude_blocker_screen_outranks_osc_idle_title() {
    // When the OSC title shows ✳ (idle) but the screen has a bash permission
    // prompt, the blocked rule at priority 850 beats osc_title_idle at 250.
    let blocker_screen = "do you want to proceed?\n\
        bash command: rm -rf /tmp/test\n\
        ❯ 1. Yes\n   2. No\n\n\
        Esc to cancel · Tab to amend · ctrl+e to explain\n";
    let result = detect_with(Agent::Claude, blocker_screen, "✳ Claude Code", "");
    assert_eq!(result.state, Some(AgentState::Blocked));
}

#[test]
fn claude_empty_osc_empty_screen_is_idle_fallback() {
    // No OSC data, no matching screen rule → fallback idle (unchanged V3 behavior)
    let result = detect_with(Agent::Claude, "", "", "");
    assert_eq!(result.state, Some(AgentState::Idle));
}

// --- Codex OSC rules ---

#[test]
fn codex_osc_title_braille_spinner_is_working() {
    // "⠋" is U+280B, in the braille block
    let result = detect_with(Agent::Codex, "", "⠋ llm-proxy", "");
    assert_eq!(result.state, Some(AgentState::Working));
    assert_eq!(result.rule, Some("osc_title_working"));
}

#[test]
fn codex_osc_title_action_required_is_blocked() {
    let result = detect_with(Agent::Codex, "", "[ . ] Action Required | llm-proxy", "");
    assert_eq!(result.state, Some(AgentState::Blocked));
    assert_eq!(result.rule, Some("osc_title_blocked"));
}

#[test]
fn codex_osc_title_plain_is_idle() {
    let result = detect_with(Agent::Codex, "", "llm-proxy", "");
    assert_eq!(result.state, Some(AgentState::Idle));
    assert_eq!(result.rule, Some("osc_title_idle"));
}

#[test]
fn codex_trust_directory_requires_live_top_region() {
    let screen = "> You are in C:\\Users\\user\\project\n\n\
        Do you trust the contents of this\n\
        directory? Working with untrusted\n\
        contents comes with higher risk of\n\
        prompt injection. Trusting the\n\
        directory allows project-local config,\n\
        hooks, and exec policies to load.\n\n\
        › 1. Yes, continue\n\
          2. No, quit\n\n\
        Press enter to continue\n";
    let result = detect_with(Agent::Codex, screen, "project", "");

    assert_eq!(result.state, Some(AgentState::Blocked));
    assert_eq!(result.rule, Some("trust_directory"));

    let transcript = "› > You are in C:\\Users\\user\\project\n\n\
        Do you trust the contents of this\n\
        directory? Working with untrusted contents comes with higher risk.\n";
    let result = detect_with(Agent::Codex, transcript, "project", "");

    assert_eq!(result.state, Some(AgentState::Idle));
    assert_ne!(result.rule, Some("trust_directory"));
}

#[test]
fn codex_background_terminal_screen_does_not_override_osc_idle() {
    // Background terminal tasks can be long-lived helpers such as dev servers.
    // They should not make Codex look busy once the foreground turn is idle.
    let screen = "background terminal running · /ps to view · /stop to close\n";
    let result = detect_with(Agent::Codex, screen, "llm-proxy", "");
    assert_eq!(result.state, Some(AgentState::Idle));
    assert_eq!(result.rule, Some("osc_title_idle"));
}

#[test]
fn codex_screen_working_fallback_handles_static_osc_title() {
    let screen = "• I’ll run it and wait for completion.\n\n\
        ◦ Working (1m 16s • esc to interrupt) · 1 background…\n\n\
        › Use /skills to list available skills\n\n\
        gpt-5.6-sol default · /work\n";
    let result = detect_with(Agent::Codex, screen, "project", "");

    assert_eq!(result.state, Some(AgentState::Working));
    assert_eq!(result.rule, Some("screen_working_fallback"));
}

#[test]
fn codex_osc_working_remains_preferred_over_screen_fallback() {
    let screen = "• Working (4s • esc to interrupt)\n\n\
        › Use /skills to list available skills\n\n\
        gpt-5.6-sol default · /work\n";
    let result = detect_with(Agent::Codex, screen, "⠸ project", "");

    assert_eq!(result.state, Some(AgentState::Working));
    assert_eq!(result.rule, Some("osc_title_working"));
}

#[test]
fn codex_screen_blocker_outranks_working_fallback() {
    let screen = "• Working (4s • esc to interrupt)\n\
        › 1. Yes, proceed\n\
        Press enter to confirm or esc to cancel\n";
    let result = detect_with(Agent::Codex, screen, "project", "");

    assert_eq!(result.state, Some(AgentState::Blocked));
    assert_eq!(result.rule, Some("live_strong_blocker"));
}

#[test]
fn codex_weak_blocker_outranks_working_fallback() {
    let screen = "• Working (4s • esc to interrupt)\n\
        do you want to continue? [y/n]\n\
        › Use /skills to list available skills\n";
    let result = detect_with(Agent::Codex, screen, "project", "");

    assert_eq!(result.state, Some(AgentState::Blocked));
    assert_eq!(result.rule, Some("weak_blocker"));
}

#[test]
fn codex_transcript_viewer_outranks_working_fallback() {
    let screen = "• Working (4s • esc to interrupt)\n\
        › transcript\n\
        ↑/↓ to scroll · pgup/pgdn to move · home/end to jump · q to quit · esc to edit prev\n";
    let result = detect_with(Agent::Codex, screen, "project", "");

    assert_eq!(result.state, None);
    assert_eq!(result.rule, Some("transcript_viewer"));
    assert!(result.skip_state_update);
}

#[test]
fn codex_screen_working_fallback_ignores_stale_and_prompt_text() {
    let screens = [
        "◦ Working (1m 16s • esc to interrupt)\n\
         ■ Conversation interrupted\n\
         › Use /skills to list available skills\n\
         gpt-5.6-sol default · /work\n",
        "› Explain the text ◦ Working (1m 16s • esc to interrupt)\n\
         gpt-5.6-sol default · /work\n",
        "  ◦ Working (1m 16s • esc to interrupt)\n\
         › Use /skills to list available skills\n\
         gpt-5.6-sol default · /work\n",
    ];

    for screen in screens {
        let result = detect_with(Agent::Codex, screen, "project", "");
        assert_eq!(result.state, Some(AgentState::Idle));
        assert_eq!(result.rule, Some("osc_title_idle"));
    }
}

#[test]
fn codex_screen_working_fallback_ignores_interrupted_short_terminal() {
    let screen = "◦ Working (1m 16s • esc to interrupt)\n\
        ■ Conversation interrupted\n\
        ›\n";
    let result = detect_with(Agent::Codex, screen, "project", "");

    assert_eq!(result.state, Some(AgentState::Idle));
    assert_eq!(result.rule, Some("osc_title_idle"));
}

#[test]
fn codex_osc_working_beats_weak_blocker_screen() {
    // A stale [y/n] on screen triggers weak_blocker at priority 600, but an
    // active braille spinner in the OSC title is priority 1050 — OSC wins.
    let screen = "do you want to continue? [y/n]\n";
    let result = detect_with(Agent::Codex, screen, "⠋ llm-proxy", "");
    assert_eq!(result.state, Some(AgentState::Working));
    assert_eq!(result.rule, Some("osc_title_working"));
}
