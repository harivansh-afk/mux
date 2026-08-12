# NixOS module: run muxd as a systemd service.
#
# Imported as `mux.nixosModules.muxd`. `self` is the flake, so the default
# package is this flake's muxd built for the host's system.
self: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.muxd;
  # QUIC is UDP; the port is the tail of "<ip>:<port>".
  port = lib.toInt (lib.last (lib.splitString ":" cfg.listen));
  # Digests, not tokens: safe to world-read from /nix/store.
  authorizedTokens =
    pkgs.writeText "muxd-authorized-tokens"
    (lib.concatMapStrings (digest: digest + "\n") cfg.authorizedTokenDigests);
in {
  options.services.muxd = {
    enable = lib.mkEnableOption "the mux session daemon (muxd) QUIC listener";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.muxd;
      defaultText = lib.literalExpression "mux.packages.\${system}.muxd";
      description = "The muxd package to run.";
    };

    listen = lib.mkOption {
      type = lib.types.str;
      example = "100.64.0.7:4433";
      description = ''
        Address muxd's QUIC listener binds, as "<ip>:<port>". Use a Tailscale
        (or otherwise private) IP: the port is exposed to whatever can reach it.
      '';
    };

    authorizedTokenDigests = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"];
      description = ''
        Clients allowed to attach, each named by the SHA-256 of its bearer
        token as "sha256:<64 lowercase hex>".

        Run `muxd client-digest` on the client machine, put the line it
        prints here, and deploy. The token itself stays on the client: no
        secret ever crosses machines, and a digest is safe in the nix store
        and in git. Revoking a client is deleting its line.

        muxd also always admits its own token
        ($HOME/.local/state/muxd/token), so leaving this empty keeps the
        older flow where a client copies that file to
        ~/.local/state/mux/tokens/<alias>.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open the listen port (UDP, QUIC) in the firewall.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      example = "alice";
      description = ''
        User to run muxd as. muxd is a per-user daemon: every pane's shell
        runs as this user, in this user's home, with this user's login
        shell - so it must be the human who attaches, never a system
        account (a nologin shell makes every pane exit immediately).
        muxd's cert, bearer token, and state live under this user's
        $HOME/.local/state/muxd.
      '';
    };

    home = lib.mkOption {
      type = lib.types.str;
      default = config.users.users.${cfg.user}.home or "/var/lib/muxd";
      defaultText = lib.literalExpression "config.users.users.\${cfg.user}.home";
      description = "HOME for the service: the user's real home directory.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.listen != "" && lib.length (lib.splitString ":" cfg.listen) == 2;
        message = ''services.muxd.listen must be set to "<ip>:<port>", e.g. "100.64.0.7:4433".'';
      }
      {
        assertion = lib.all (lib.hasPrefix "sha256:") cfg.authorizedTokenDigests;
        message = ''
          services.muxd.authorizedTokenDigests takes digests, not tokens: every
          entry must be "sha256:<64 lowercase hex>", as printed by
          `muxd client-digest`.
        '';
      }
    ];

    networking.firewall.allowedUDPPorts = lib.mkIf cfg.openFirewall [port];

    systemd.services.muxd = {
      description = "mux session daemon (QUIC listener)";
      documentation = ["https://git.harivan.sh/harivansh-afk/mux"];
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];

      serviceConfig = {
        # muxd reads and writes cert.pem, key.pem, and token under
        # $HOME/.local/state/muxd, and logs the cert pin to the journal
        # on first start (`muxd pin` prints the same line on demand).
        # HOME is the user's real home: pane shells load their dotfiles,
        # and the token sits where the user can read it without sudo.
        ExecStart = lib.concatStringsSep " " ([
            (lib.getExe cfg.package)
            "--listen-quic"
            cfg.listen
          ]
          ++ lib.optionals (cfg.authorizedTokenDigests != []) [
            "--authorized-tokens"
            "${authorizedTokens}"
          ]);
        User = cfg.user;
        Environment = "HOME=${cfg.home}";
        # A pty master plus a client connection per pane, against a
        # 256-pty cap and one QUIC connection per peer. systemd's 1024
        # default is close enough to that to be reachable, and a daemon
        # that runs out of descriptors is a daemon whose accept loop
        # spends its time backing off instead of serving.
        LimitNOFILE = 65536;
        Restart = "on-failure";
        RestartSec = "2s";
      };
    };
  };
}
