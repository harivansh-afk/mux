{
  description = "mux: the muxd session daemon and mux-attach relay, packaged for Nix";

  inputs = {
    # A recent unstable: it carries zig 0.16.0 as pkgs.zig, which ghostty-vt's
    # zig build requires. No overlay needed.
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # Ghostty's terminal sources: ghostty-vt compiles ghostty's terminal
    # package from this tree. Keep this commit equal to GHOSTTY_COMMIT in
    # .forgejo/workflows/ci.yml - the Rust VT and the AppKit renderer have to
    # agree on ghostty's terminal semantics, and build.zig.zon's uucode pin is
    # chosen to match this tree.
    ghostty = {
      url = "github:ghostty-org/ghostty/fea378e565c8ddb7f49808c4f2e36a4a932e35ff";
      flake = false;
    };
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    ghostty,
  }: let
    # The daemon deploys to Linux; darwin is here so it can be realized and
    # smoke-tested on a Mac (this repo's development machine).
    systems = ["aarch64-linux" "x86_64-linux" "aarch64-darwin"];
  in
    flake-utils.lib.eachSystem systems (system: let
      pkgs = nixpkgs.legacyPackages.${system};

      # The pre-fetched uucode dependency, handed to `zig build --system` so
      # the zig half of ghostty-vt resolves offline in the Nix sandbox.
      zigDeps = pkgs.callPackage ./crates/ghostty-vt/zig/deps.nix {};

      # zig links ghostty's terminal package against libc, and build.rs passes
      # `zig build --system` (offline packages). `--system` also stops zig from
      # probing the host for libc, so we must hand it an explicit libc paths
      # file via ZIG_LIBC (build.rs forwards it as `--libc <file>`), on both
      # platforms, since the sandbox has no system headers to discover:
      #   - Linux: the stdenv libc's include and lib dirs.
      #   - darwin: the SDK sysroot's usr/include and usr/lib (libSystem.tbd).
      #     SDKROOT is set too so build.rs skips its xcrun probe (absent here).
      isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
      darwinSdkroot = "${pkgs.apple-sdk}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk";
      linuxZigLibc = pkgs.writeText "zig-libc.txt" ''
        include_dir=${pkgs.lib.getDev pkgs.stdenv.cc.libc}/include
        sys_include_dir=${pkgs.lib.getDev pkgs.stdenv.cc.libc}/include
        crt_dir=${pkgs.lib.getLib pkgs.stdenv.cc.libc}/lib
        msvc_lib_dir=
        kernel32_lib_dir=
        gcc_dir=
      '';
      darwinZigLibc = pkgs.writeText "zig-libc.txt" ''
        include_dir=${darwinSdkroot}/usr/include
        sys_include_dir=${darwinSdkroot}/usr/include
        crt_dir=${darwinSdkroot}/usr/lib
        msvc_lib_dir=
        kernel32_lib_dir=
        gcc_dir=
      '';

      mux = pkgs.rustPlatform.buildRustPackage {
        pname = "mux";
        version = "0.1.0";
        src = ./.;

        # Vendor from the committed lockfile: no network fetch of crates.
        cargoLock.lockFile = ./Cargo.lock;

        # Only the deployable binaries. The Swift app (app/) is not a cargo
        # member and is never built here.
        cargoBuildFlags = ["-p" "muxd" "-p" "mux-attach"];

        # The workspace tests want a live pty and loopback sockets; the sandbox
        # has neither. CI (.forgejo/workflows/ci.yml) is where tests run.
        doCheck = false;

        # build.rs invokes zig itself, so we hand it the compiler by path
        # (via the ZIG env var it honors) rather than adding pkgs.zig to
        # nativeBuildInputs: that package's setup hook would otherwise install
        # its own zig-build phase and pre-empt buildRustPackage's. `ar` (from
        # the stdenv cc) archives the object zig emits.
        ZIG = pkgs.lib.getExe pkgs.zig;

        # Everything build.rs needs to run `zig build` fully offline.
        GHOSTTY_SOURCE_DIR = "${ghostty}/src";
        GHOSTTY_ZIG_SYSTEM_DIR = zigDeps;
        SDKROOT = pkgs.lib.optionalString isDarwin darwinSdkroot;
        ZIG_LIBC = "${if isDarwin then darwinZigLibc else linuxZigLibc}";

        meta = {
          description = "muxd session daemon and mux-attach relay";
          mainProgram = "muxd";
          platforms = systems;
        };
      };
    in {
      # muxd and mux-attach are the two binaries of one build; both attrs point
      # at the derivation that carries them.
      packages = {
        muxd = mux;
        mux-attach = mux;
        default = mux;
      };
    })
    // {
      # NixOS module: run muxd as a systemd service exposing its QUIC listener.
      nixosModules.muxd = import ./nix/module.nix self;
    };
}
