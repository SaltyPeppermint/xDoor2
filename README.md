# xDoor 2

xDoor2 is the Python rewrite of the xHain door controller.

## Build the image

```sh
nix run .#image
```

The image is written to `result/sd-image/`.
Flash with:

```sh
nix run .#flash -- /dev/your-sd-card
```

`flash` builds the image first if needed and overwrites the selected device!
The root partition grows to fill the card on first boot.

### MacOS Weirdness

NixOS images contain Linux/aarch64 binaries so the build needs an `aarch64-linux` builder.
On MacOS enable one, e.g. `nix.linux-builder.enable = true` in nix-darwin or the native Linux builder of Determinate Nix.
`flash` will also unmount the card (MacOS will not write to a mounted volume) and writes through the raw `/dev/rdiskN` node, (faster than `/dev/diskN`).

## First boot

The image starts administrative OpenSSH on port 23 as user `admin`:

```sh
nix run .#shell
```

NixOS creates the device SSH host key on first boot.
The application reuses that key through a systemd credential.

## Updating a running device

NixOS updates can be made and thanks to nix easily rolled back!
Isn't nix amazing! wooooo.

```sh
nix run .#deploy
```

`deploy` and `shell` talk to `xdoor2.lan.xhain.space` on port 23.

## Development

```sh
nix develop
pytest
nix run .#lint  # ruff and ty
nix fmt
```

Please actually do all of this

The NixOS configuration lives in `nixos/`:
- `nixos/rpi3-image.nix`: machine config,
- `nixos/xdoor2.nix` application user, GPIO, credentials, systemd service.
- `nixos/admin-keys.nix` SSH keys for the door admins(used for normal OpenSSH on port 23 and admin interface of app).
- `nixos/authorized_keys_pub.pem` public key used to verify the signature on the `authorized_keys` list fetched from `xdoor.x-hain.de`.
