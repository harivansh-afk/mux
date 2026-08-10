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

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open the listen port (UDP, QUIC) in the firewall.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "muxd";
      description = ''
        User to run muxd as. muxd derives its cert, bearer token, and state
        paths from $HOME, so the service is given a stable home under
        /var/lib/muxd regardless of this user.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.listen != "" && lib.length (lib.splitString ":" cfg.listen) == 2;
        message = ''services.muxd.listen must be set to "<ip>:<port>", e.g. "100.64.0.7:4433".'';
      }
    ];

    # Create the default service user when it has not been overridden.
    users.users = lib.mkIf (cfg.user == "muxd") {
      muxd = {
        isSystemUser = true;
        group = "muxd";
        home = "/var/lib/muxd";
        description = "mux session daemon";
      };
    };
    users.groups = lib.mkIf (cfg.user == "muxd") {muxd = {};};

    networking.firewall.allowedUDPPorts = lib.mkIf cfg.openFirewall [port];

    systemd.services.muxd = {
      description = "mux session daemon (QUIC listener)";
      documentation = ["https://git.harivan.sh/harivansh-afk/mux"];
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];

      serviceConfig = {
        # muxd reads and writes cert.pem, key.pem, and token under
        # $HOME/.local/state/muxd, and logs the cert pin to the journal on
        # first start. StateDirectory gives it /var/lib/muxd (mode 0700, owned
        # by the service user) and HOME points there, so the token lands at
        # /var/lib/muxd/.local/state/muxd/token for out-of-band copying.
        ExecStart = "${lib.getExe cfg.package} --listen-quic ${cfg.listen}";
        User = cfg.user;
        StateDirectory = "muxd";
        Environment = "HOME=/var/lib/muxd";
        Restart = "on-failure";
        RestartSec = "2s";
      };
    };
  };
}
