# Pre-fetched Zig dependencies for ghostty-vt build.
# Includes the single uucode dependency our build.zig.zon needs.
{
  linkFarm,
  fetchurl,
  runCommandLocal,
  zig_0_15,
}: let
  unpackZigArtifact = {
    name,
    artifact,
  }:
    runCommandLocal name
    {
      nativeBuildInputs = [zig_0_15];
    }
    ''
      hash="$(zig fetch --global-cache-dir "$TMPDIR" ${artifact})"
      mv "$TMPDIR/p/$hash" "$out"
      chmod 755 "$out"
    '';

  fetchZig = {
    name,
    url,
    hash,
  }: let
    artifact = fetchurl {inherit url hash;};
  in
    unpackZigArtifact {inherit name artifact;};
  # url + hash live in the sibling pins.json (no inline `sha256-...`), the one
  # place a bump edits. builtins.fromJSON needs no free variable, so this file
  # imports cleanly from a scope that does not thread `lib`.
  uucode = (builtins.fromJSON (builtins.readFile ./pins.json)).uucode;
in
  linkFarm "ghostty-vt-zig-deps" [
    {
      name = "uucode-0.2.0-ZZjBPqZVVABQepOqZHR7vV_NcaN-wats0IB6o-Exj6m9";
      path = fetchZig {
        name = "uucode";
        inherit (uucode) url hash;
      };
    }
  ]
