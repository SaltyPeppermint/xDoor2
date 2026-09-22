{
  lib,
  xdoor2Package,
  ...
}:

{
  users.groups.gpio = { };
  users.groups.xdoor2 = { };
  users.users.xdoor2 = {
    isSystemUser = true;
    group = "xdoor2";
    extraGroups = [ "gpio" ];
    home = "/var/lib/xdoor2";
    createHome = true;
  };

  environment.etc."xdoor2/config.toml".source = ./config.toml;
  environment.etc."xdoor2/admin_keys".text = lib.concatLines (import ./admin-keys.nix);
  # Public half of the key that signs the upstream authorized_keys list. Only
  # ever used to verify a signature, so the world-readable Nix store is fine.
  environment.etc."xdoor2/authorized_keys_pub.pem".text = ''
    -----BEGIN PUBLIC KEY-----
    MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEC/yMswx6+6foFhF8/IjpG
    BCx4h9fcg1470Py1YAYEmtociQ8PPepCJJk1jxSeIObsy4PWKYAByT4k6+dXvgSg
    v2WQijKdgK8foKIlIsD9J2hy9X9Zbq32TLI95JEEXzFbbFXRNyemvdx8+Woc300S
    qPukNaJxvMHYaBz6uCXWB/TFr7MT4Qf4LpdKEeug64ajCFLWrGzfd5mC+AFRuGaW
    PYX07NiiaulkiTnRe8HHz06SYweHIvs5NjKW4kNryuJZmk+VVAeSK4yRDoAt0dVo
    01Z9hyU4mm/6KSDwKudo8UNAGOFUiJnjE9u72MigP4bPKKgQ6Dh+3uW+5+haeBmJ
    wHl0f9TRykLMg/rDr9sl0JSZsiNEWCU+jUOe7Nqm9auTQZvUeEVRDbwnIakCNoSn
    O5yXne/5Ax+MOkDQUUMgYbGaV5Zsl0WNMzOssR8e/Cjj2kUxEUOW2C8Od+k6cU2/
    Xd7Q0edgfKN3J2uslcPKJ2r+3ookdY4BwyHMuCD1AKOXNxezF1v0vOmVheeUL4gc
    QXfXgM5TDrHQd9d49bqYAaho31CGUqlVfJicMTdSdP+MIr7ofXyOlMM/LGOUTrN7
    pQ1yK3PpJ6a1i5bTHM68hfeGP0SY1IzouXepTN/JvaVIfSuo3hyI3jCu/r4kUxgx
    pDI3kgn35TIG01VR7SxcDd0CAwEAAQ==
    -----END PUBLIC KEY-----
  '';
  services.udev.extraRules = ''
    SUBSYSTEM=="gpio", KERNEL=="gpiochip*", GROUP="gpio", MODE="0660"
  '';
  environment.systemPackages = [ xdoor2Package ];

  systemd.tmpfiles.rules = [
    "d /data 0755 root root -"
    "d /data/xdoor2 0750 xdoor2 xdoor2 -"
    "d /var/lib/xdoor2/secrets 0750 root xdoor2 -"
    # Empty key cache on a new card but f does not overwrite an existing cache
    "f /data/xdoor2/authorized_keys 0640 xdoor2 xdoor2 -"
    # Same deal for travel distance. 0 means uncalibrated
    "f /data/xdoor2/door_distance 0640 xdoor2 xdoor2 - 0"
  ];

  # The Raspi has no clock so the system start thinking it is in the past.
  # This means every HTTPS request (authorized_keys fetch) fails
  # until timesyncd has talked to an NTP server.
  systemd.additionalUpstreamSystemUnits = [ "systemd-time-wait-sync.service" ];
  systemd.services.systemd-time-wait-sync = {
    # Prevent system hang if no ntp server is reachable
    serviceConfig.TimeoutStartSec = "120s";
  };

  systemd.services.xdoor2 = {
    description = "xDoor2 controller";
    documentation = [ "https://github.com/xHain/xDoor2" ];
    wantedBy = [ "multi-user.target" ];
    wants = [
      "network-online.target"
      # Wants, not requires: if the clock never syncs we still start and let the
      # key refresh loop retry, rather than leaving the door without a controller.
      "systemd-time-wait-sync.service"
    ];
    after = [
      "network-online.target"
      "systemd-time-wait-sync.service"
      "time-sync.target"
      "sshd-keygen.service"
    ];
    # The signature verification key now ships with the configuration, so only
    # genuinely secret files that have to be provisioned out of band belong here.
    unitConfig.ConditionPathExists = [
      # "/var/lib/xdoor2/secrets/mqtt_password"
    ];
    environment = {
      XDOOR_CONFIG = "/etc/xdoor2/config.toml";
      # Pin the gpiozero backend
      GPIOZERO_PIN_FACTORY = "lgpio";
      # lgpio creates its notification FIFO (.lgd-nfy*) in $LG_WD, but falls back to /
      # We cant read root so we need to fix this to smth it can read
      LG_WD = "/run/xdoor2";
    };
    serviceConfig = {
      Type = "simple";
      User = "xdoor2";
      Group = "xdoor2";
      SupplementaryGroups = [ "gpio" ];
      ExecStart = lib.getExe xdoor2Package;
      RuntimeDirectory = "xdoor2";
      RuntimeDirectoryMode = "0700";
      WorkingDirectory = "/run/xdoor2";
      Restart = "on-failure";
      RestartSec = "2s";
      TimeoutStopSec = "10s";

      LoadCredential = [
        "ssh_host_key:/etc/ssh/ssh_host_ed25519_key"
        # "mqtt_password:/var/lib/xdoor2/secrets/mqtt_password"
      ];

      CapabilityBoundingSet = [
        "CAP_NET_BIND_SERVICE"
        "CAP_SYS_BOOT"
      ];
      AmbientCapabilities = [
        "CAP_NET_BIND_SERVICE"
        "CAP_SYS_BOOT"
      ];
      NoNewPrivileges = true;

      PrivateTmp = true;
      PrivateDevices = false;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectClock = true;
      ProtectControlGroups = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
      RestrictRealtime = true;
      LockPersonality = true;
      ReadWritePaths = [ "/data/xdoor2" ];
    };
  };
}
