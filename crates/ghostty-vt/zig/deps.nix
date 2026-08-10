# Pre-fetched Zig dependencies for ghostty-vt's offline build.
#
# ghostty-vt/build.rs runs `zig build --system <dir>` whenever
# GHOSTTY_ZIG_SYSTEM_DIR is set (see `apply_ghostty_system_cache`). In that
# mode Zig never reaches the network: it resolves every dependency by looking
# up a directory named after the package hash from build.zig.zon under <dir>,
# and trusts whatever is there. This derivation builds that <dir> as a
# linkFarm so the Nix sandbox (no network) can build ghostty-vt.
#
# The one dependency our build.zig.zon declares is uucode (unicode table
# generation). Its url + SRI hash live in the sibling pins.json, the single
# place a bump edits.
{
  linkFarm,
  fetchurl,
  runCommandLocal,
  zig,
}: let
  # Turn a package tarball into the canonical, unpacked package root that
  # `--system` expects: `build.zig.zon` at the top, filtered to that file's
  # declared `.paths`. We let `zig fetch` do the filtering and hashing so the
  # directory name is exactly the hash zig will look up.
  #
  # Two quirks of zig 0.16's `fetch` shape this:
  #   - it refuses to run without a build.zig in scope, so we hand it a
  #     throwaway one in a scratch directory;
  #   - it stores the result as a canonical tarball at <cache>/p/<hash>.tar.gz
  #     (not an unpacked directory), whose single top-level entry is <hash>.
  unpackZigArtifact = {
    name,
    artifact,
  }:
    runCommandLocal name
    {
      nativeBuildInputs = [zig];
    }
    ''
      export HOME="$TMPDIR"
      mkdir -p "$TMPDIR/ctx" "$TMPDIR/cache" "$TMPDIR/unpacked"
      cd "$TMPDIR/ctx"
      printf 'pub fn build(_: *@import("std").Build) void {}\n' > build.zig

      hash="$(zig fetch --global-cache-dir "$TMPDIR/cache" ${artifact})"
      tar -xzf "$TMPDIR/cache/p/$hash.tar.gz" -C "$TMPDIR/unpacked"
      mv "$TMPDIR/unpacked/$hash" "$out"
    '';

  fetchZig = {
    name,
    url,
    hash,
  }: let
    artifact = fetchurl {inherit url hash;};
  in
    unpackZigArtifact {inherit name artifact;};

  # url + hash live in pins.json (no inline `sha256-...`), the one place a
  # bump edits. builtins.fromJSON needs no free variable, so this file imports
  # cleanly from a scope that does not thread `lib`.
  uucode = (builtins.fromJSON (builtins.readFile ./pins.json)).uucode;
in
  linkFarm "ghostty-vt-zig-deps" [
    {
      # This name MUST equal the `.hash` in build.zig.zon: `zig build
      # --system` resolves uucode by looking for a directory of exactly this
      # name. Keep the two in lockstep on any bump.
      name = "uucode-0.2.0-ZZjBPlK5VADj7fdoq7G8LIHzD5o6FSkcBXXrRWr4jnrA";
      path = fetchZig {
        name = "uucode";
        inherit (uucode) url hash;
      };
    }
  ]
