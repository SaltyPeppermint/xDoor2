# xDoor 2

xDoor2 is the Python rewrite of the xHain door controller.

## Build the image

```sh
nix develop
make image
```

On an `aarch64-linux` machine this builds natively and the image is written to `result/sd-image/`.
Flash with:

```sh
make flash DEVICE=/dev/your-sd-card
```

`flash` overwrites the selected device!
The root partition grows to fill the card on first boot.

### MacOS Weirdness

NixOS images contain Linux/aarch64 binaries so the build needs an `aarch64-linux` builder.
On MacOS `make image` therefore runs inside a container and copies the image to `output/nixos/`.
`make flash` can then just use it.
It will also unmount the card (MacOS will not write to a mounted volume) and writes through the raw `/dev/rdiskN` node, (faster than `/dev/diskN`).

Override the runtime and the resources it gets:

```sh
make image DEVICE=/dev/disk4 CONTAINER=docker CONTAINER_CPUS=4 CONTAINER_MEMORY=8G
```

## First boot and secrets

The image starts administrative OpenSSH on port 23 as user `admin`.
It does not put the decrypted MQTT password in the Nix store or SD image.
After the first boot, you need to provision it over SSH:

```sh
nix develop
make provision
```

The xDoor2 service starts once the required secret files exist.
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
- `nixos/admin-keys.nix` SSH keys for the door admins(used for normal OpenSSH on port 23 and admin interface of app).
- `nixos/authorized_keys_pub.pem` public key used to verify the signature on the `authorized_keys` list fetched from `xdoor.x-hain.de`.
