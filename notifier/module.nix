{ self }:
{ config, lib, pkgs, ... }:
let
  cfg = config.services.aqara-doorbell;
  pythonEnv = pkgs.python3.withPackages (ps: [ ps.cryptography ]);
in
{
  options.services.aqara-doorbell = {
    enable = lib.mkEnableOption "Aqara G410 motion -> Matrix snapshot/clip notifier";

    environmentFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to an EnvironmentFile (e.g. an agenix/sops secret) with:
          AQARA_EMAIL, AQARA_PASSWORD        (the account that owns the camera)
          MATRIX_USER, MATRIX_PASSWORD       (the bot account)
          MATRIX_ROOM                        (!roomid, no :server for a v12 room)
        Optional: AQARA_POSITION_ID, AQARA_DID (auto-discovered when unset),
        MATRIX_TOKEN (instead of user/password).
      '';
    };

    homeserver = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:8008";
      example = "https://matrix.example.org";
      description = ''
        Matrix Client-Server API base URL. Prefer a local/private address:
        many reverse proxies (e.g. Cloudflare) return 403 for POST /login.
      '';
    };

    pollInterval = lib.mkOption {
      type = lib.types.ints.positive;
      default = 15;
      description = "Seconds between Aqara event-history polls.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.aqara-doorbell = {
      description = "Aqara G410 motion -> Matrix snapshot/clip notifier";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      environment = {
        MATRIX_HOMESERVER = cfg.homeserver;
        POLL_INTERVAL = toString cfg.pollInterval;
      };
      serviceConfig = {
        Type = "simple";
        DynamicUser = true;
        StateDirectory = "aqara-doorbell";
        EnvironmentFile = cfg.environmentFile;
        ExecStart = "${pythonEnv}/bin/python3 ${self}/notifier/aqara_doorbell_notify.py";
        Restart = "always";
        RestartSec = "30s";

        # Hardening
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
      };
    };
  };
}
