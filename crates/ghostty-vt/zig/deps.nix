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
  # place a bump edits. See indexable-inc/index's pins convention. This file is
  # re-imported by the index cargo-unit renderer's generated units.nix in a
  # scope that does NOT thread `lib`, so `lib.importJSON` fails there with
  # `undefined variable 'lib'`; `builtins.fromJSON (readFile ...)` needs no free
  # variable and reads identical bytes (drvPath unchanged).
  # astlog-ignore: prefer-lib-import-format -- cargo-unit renderer scope has no `lib`; see above
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
