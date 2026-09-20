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
  environment.etc."xdoor2/greeting".source = ./greeting;
  environment.etc."xdoor2/admin_keys".text = lib.concatLines (import ./admin-keys.nix);
  # Public half of the key that signs the upstream authorized_keys list. Only
  # ever used to verify a signature, so the world-readable Nix store is fine.

  # TODO Fill me with sops -d --extract '["authorized_keys_pub_pem"]' secrets.yml > nixos/authorized_keys_pub.pem
  # environment.etc."xdoor2/authorized_keys_pub.pem".source = ./authorized_keys_pub.pem;
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

  systemd.services.xdoor2 = {
    description = "xDoor2 controller";
    documentation = [ "https://github.com/xHain/xDoor2" ];
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [
      "network-online.target"
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
    };
    serviceConfig = {
      Type = "simple";
      User = "xdoor2";
      Group = "xdoor2";
      SupplementaryGroups = [ "gpio" ];
      ExecStart = lib.getExe xdoor2Package;
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
      ReadWritePaths = [
        "/data/xdoor2"
        "/run"
      ];
    };
  };
}
