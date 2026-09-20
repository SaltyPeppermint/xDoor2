{
  lib,
  buildPythonApplication,
  hatchling,
  asyncssh,
  cryptography,
  gpiozero,
  httpx,
  lgpio,
  paho-mqtt,
}:

buildPythonApplication {
  pname = "xdoor2";
  version = "0.1.0";
  pyproject = true;

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../pyproject.toml
      ../README.md
      ../src
    ];
  };

  build-system = [ hatchling ];
  dependencies = [
    asyncssh
    cryptography
    gpiozero
    httpx
    # gpiozero ships no GPIO backend of its own.
    # lgpio is the most widely supported one to /dev/gpiochip0
    lgpio
    paho-mqtt
  ];

  pythonImportsCheck = [ "xdoor2" ];

  meta = {
    description = "xHain door controller";
    mainProgram = "xdoor2";
    platforms = lib.platforms.linux;
  };
}
