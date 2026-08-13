# ghostty patches

Patches the bundled GhosttyKit must carry until they are upstream.
Apply to the ghostty checkout, then rebuild the xcframework:

    cd ~/src/ghostty
    git apply /path/to/mux/patches/ghostty/surface-command.patch
    ~/tools/zig-0.16.0/zig build -Demit-xcframework -Dxcframework-target=native -Doptimize=ReleaseFast
    cp -R macos/GhosttyKit.xcframework /path/to/mux/app/GhosttyKit/

## surface-command.patch

libghostty wipes the embedder's per-surface `command` (and
`wait-after-command`) whenever a conditional theme mismatch makes it
re-derive the surface config by replaying the config file. With a
`theme = light:...,dark:...` config this hits every launch-created
surface: panes silently spawn `$SHELL` instead of `mux-attach`, so
nothing reaches muxd and nothing survives a quit. The patch preserves
the two fields across the replay, exactly as upstream already
preserves `working-directory`. Same bug class also affects embedder
`env_vars` and `initial_input` (unused by mux); mention it when
upstreaming.
