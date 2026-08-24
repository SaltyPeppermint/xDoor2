# xDoor 2

xDoor2 is the Python rewrite of the xHain door controller.

## Build the image

On an `aarch64-linux` machine:

```sh
nix develop
make image
```

The compressed SD image is written below:

```sh
make flash DEVICE=/dev/your-sd-card
```

`flash` overwrites the selected device!
The root partition grows to fill the card on first boot.

### Build on an Apple Silicon Mac

NixOS images contain Linux/aarch64 binaries, so the build needs an
`aarch64-linux` builder. Use the container command below:

```sh
container run --rm --cpus 8 --memory 12G \
  --volume "$PWD:/workspace" \
  --workdir /workspace \
  docker.io/nixos/nix:latest \
  sh -lc '
    git config --global --add safe.directory /workspace
    nix --extra-experimental-features "nix-command flakes" \
      build path:.#image --out-link /tmp/xdoor-result
    mkdir -p output/nixos
    cp /tmp/xdoor-result/sd-image/*.img.zst output/nixos/
  '
```

Should work the same with any other docker container thingy.

The syslink fix is necessary to not end up with a broken image.

## First boot and secrets

The image starts administrative OpenSSH on port 23 as user `admin`.
It does not put decrypted MQTT credentials or application keys in the Nix store or SD
image. After the first boot, you need to provision them over SSH:

```sh
nix develop
make provision
```

The xDoor service starts once both required secret files exist.
NixOS creates the device SSH host key on first boot.
The application reuses that key through a systemd credential.

## Updating a running device

NixOS updates can be made and thanks to nix easily rolled back!
Isn't nix amazing! wooooo.

```sh
nix develop
make deploy
```

## Development

```sh
nix develop
make test
make lint
make format
```

Please actually do all of this

The NixOS configuration lives in `nixos/`:
- `nixos/rpi3-image.nix`: machine config,
- `nixos/xdoor2.nix` application user, GPIO, credentials, systemd service.
