{
  lib,
  xdoor2Package,
  ...
}:

{
  users.groups.gpio = { };
  users.groups.xdoor = { };
  users.users.xdoor = {
    isSystemUser = true;
    group = "xdoor2";
    extraGroups = [ "gpio" ];
    home = "/var/lib/xdoor2";
    createHome = true;
  };

  environment.etc."xdoor2/config.toml".source = ./config.toml;
  environment.etc."xdoor2/greeting".source = ./greeting;
  services.udev.extraRules = ''
    SUBSYSTEM=="gpio", KERNEL=="gpiochip*", GROUP="gpio", MODE="0660"
  '';
  environment.systemPackages = [ xdoor2Package ];

  systemd.tmpfiles.rules = [
    "d /data 0755 root root -"
    "d /data/xdoor2 0750 xdoor xdoor -"
    "d /var/lib/xdoor2/secrets 0750 root xdoor -"
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
    unitConfig.ConditionPathExists = [
      "/var/lib/xdoor2/secrets/authorized_keys_pub.pem"
      "/var/lib/xdoor2/secrets/mqtt_password"
    ];
    environment.XDOOR_CONFIG = "/etc/xdoor2/config.toml";
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
        "mqtt_password:/var/lib/xdoor2/secrets/mqtt_password"
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
