{
  config,
  lib,
  modulesPath,
  pkgs,
  xdoor2Package,
  ...
}:

{
  imports = [
    "${modulesPath}/installer/sd-card/sd-image-aarch64.nix"
    ./xdoor2.nix
  ];

  networking = {
    hostName = "xdoor";
    usePredictableInterfaceNames = false;
    useDHCP = false;
    interfaces.eth0.useDHCP = true;
    firewall.allowedTCPPorts = [
      22 # xDoor application SSH server
      23 # administrative OpenSSH server
    ];
  };

  services.openssh = {
    enable = true;
    ports = [ 23 ];
    settings = {
      AllowAgentForwarding = false;
      AllowTcpForwarding = false;
      AllowUsers = [ "admin" ];
      AuthenticationMethods = "publickey";
      GatewayPorts = "no";
      KbdInteractiveAuthentication = false;
      MaxAuthTries = 3;
      MaxSessions = 4;
      PasswordAuthentication = false;
      PermitRootLogin = "no";
      PermitTunnel = false;
      PubkeyAuthentication = true;
      X11Forwarding = false;
    };
  };

  users.mutableUsers = false;
  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFk68ujMEgPVglDNnxqrht/0piGwofQy4GmPjgq4CvUV"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINkN6Gh946RDixD57F0DVCKDSWTgJWIdW5YXbokMXuwi"
    ];
  };
  security.sudo.wheelNeedsPassword = false;
  nix.settings.trusted-users = [
    "root"
    "@wheel"
  ];

  # Keep the PL011 UART on the GPIO header and reserve RAM for crash logs, as
  # the Buildroot image did. These commands extend the module's config.txt.
  image.baseName = "xdoor2-nixos-${config.system.nixos.label}-${pkgs.stdenv.hostPlatform.system}";
  sdImage = {
    populateFirmwareCommands = lib.mkAfter ''
      mkdir -p firmware/overlays
      cp ${pkgs.raspberrypifw}/share/raspberrypi/boot/overlays/miniuart-bt.dtbo firmware/overlays/
      cp ${pkgs.raspberrypifw}/share/raspberrypi/boot/overlays/ramoops.dtbo firmware/overlays/
      chmod u+w firmware/config.txt
      cat >> firmware/config.txt <<'EOF'

      [pi3]
      dtoverlay=miniuart-bt
      dtoverlay=ramoops
      dtparam=i2c_arm=off
      dtparam=spi=off
      dtparam=audio=off
      disable_splash=1
      gpu_mem=16
      EOF
    '';
  };

  boot.kernelParams = [ "console=tty1" ];
  boot.kernel.sysctl."kernel.panic" = 10;
  boot.supportedFilesystems = lib.mkForce [
    "ext4"
    "vfat"
  ];
  boot.zfs.forceImportRoot = false;

  # The upstream SD-card profile includes a broad set of installer and rescue
  # tools. Keep the appliance image focused on what is useful on the door Pi.
  environment.defaultPackages = lib.mkForce [ ];
  environment.systemPackages = lib.mkForce [
    pkgs.libgpiod
    pkgs.vim
    xdoor2Package
  ];
  documentation.enable = false;
  documentation.nixos.enable = false;

  system.stateVersion = "25.11";
}
