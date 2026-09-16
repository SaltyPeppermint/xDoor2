{
  lib,
  buildPythonApplication,
  hatchling,
  asyncssh,
  cryptography,
  gpiozero,
  httpx,
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
    paho-mqtt
  ];

  pythonImportsCheck = [ "xdoor2" ];

  meta = {
    description = "xHain door controller";
    mainProgram = "xdoor2";
    platforms = lib.platforms.linux;
  };
}
