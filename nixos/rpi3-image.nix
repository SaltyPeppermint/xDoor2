{
  config,
  lib,
  modulesPath,
  pkgs,
  ...
}:

{
  imports = [
    "${modulesPath}/installer/sd-card/sd-image-aarch64.nix"
    ./xdoor2.nix
  ];

  networking = {
    hostName = "xdoor2";
    usePredictableInterfaceNames = false;
    useDHCP = false;
    interfaces.eth0.useDHCP = true;
    firewall.allowedTCPPorts = [
      22 # xDoor2 application SSH server
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
    openssh.authorizedKeys.keys = import ./admin-keys.nix;
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
    # Do not compress and uncompress uneccessarily
    compressImage = false;
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

  # Boot on the firmware's device tree instead that of the kernel.
  # Only the firmware's has the board data gpiozero needs (/system/linux,revision).
  # This means the dtb no longer follows the kernel.
  # Should not be a problem, and worst case we rebuild and reflash
  boot.loader.generic-extlinux-compatible.useGenerationDeviceTree = false;

  boot.kernelParams = [ "console=tty1" ];
  boot.kernel.sysctl."kernel.panic" = 10;
  boot.supportedFilesystems = lib.mkForce [
    "ext4"
    "vfat"
  ];
  environment.defaultPackages = lib.mkForce [ ];
  environment.systemPackages = with pkgs; [
    libgpiod
    ghostty.terminfo
    neovim
    curl
    tmux
    ripgrep
    fd
    file
    unzip
    dnsutils
    ncdu
    tree
    iotop
    btop
    lm_sensors
    libraspberrypi
  ];
  documentation.enable = false;
  documentation.nixos.enable = false;

  system.stateVersion = "25.11";
}
