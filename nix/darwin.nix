# nix-darwin module: run muxd as a launchd user agent.
#
# Imported as `mux.darwinModules.muxd`. Without this, the mac daemon is
# whatever process last spawned it: Mux.app on first pane, or `muxd
# upgrade` from any shell - including an agent pane, whose harness
# environment (GIT_EDITOR=true and friends) the daemon then hands to
# every pane it ever spawns. Under launchd the daemon starts from
# launchd's environment, owned by nothing that could poison it, and
# comes back on its own if it dies.
#
# launchd has no systemd `MAINPID=` handoff, so `muxd upgrade` (a
# detached setsid successor) is not how a binary bump lands here: the
# agent restarts on `darwin-rebuild switch` when the package changes,
# and every pane goes with it. A successor spawned by hand would take
# the socket, the launchd job would exit "already running", and with
# KeepAlive limited to unclean exits launchd leaves that successor
# alone until it dies. Keep Mux.app on the same package so its
# version-mismatch upgrade path never fires.
self: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.muxd;
in {
  options.services.muxd = {
    enable = lib.mkEnableOption "the mux session daemon (muxd) as a launchd user agent";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.muxd;
      defaultText = lib.literalExpression "mux.packages.\${system}.muxd";
      description = "The muxd package to run.";
    };

    listen = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "100.64.0.7:4433";
      description = ''
        Optional QUIC listen address, "<ip>:<port>". Null serves the local
        control socket only, which is all a client machine needs.
      '';
    };

    home = lib.mkOption {
      type = lib.types.str;
      description = ''
        HOME for the daemon: the user's real home. Pane shells start
        there and load their dotfiles from it, and muxd's state lives in
        $HOME/.local/state/muxd.
      '';
    };

    path = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "/usr/local/bin"
        "/usr/bin"
        "/bin"
        "/usr/sbin"
        "/sbin"
      ];
      description = ''
        PATH the daemon starts with. Pane shells are login shells and
        rebuild their own PATH; this only has to find the user's shell.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    launchd.user.agents.muxd = {
      serviceConfig = {
        ProgramArguments =
          [(lib.getExe cfg.package)]
          ++ lib.optionals (cfg.listen != null) ["--listen-quic" cfg.listen];
        RunAtLoad = true;
        # Restart on a crash or a kill; a clean exit is a successor that
        # took over the socket (see the header), and it stays in charge.
        KeepAlive.SuccessfulExit = false;
        ProcessType = "Interactive";
        # Enough for a pty master plus a client connection per pane
        # against the 256-pty cap.
        SoftResourceLimits.NumberOfFiles = 65536;
        # The only environment the daemon has. Pane shells inherit it,
        # minus what pty.rs scrubs, so nothing session-specific belongs
        # here.
        EnvironmentVariables = {
          HOME = cfg.home;
          PATH = lib.concatStringsSep ":" cfg.path;
        };
        StandardOutPath = "${cfg.home}/Library/Logs/muxd.log";
        StandardErrorPath = "${cfg.home}/Library/Logs/muxd.log";
      };
    };
  };
}
