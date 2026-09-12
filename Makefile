SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c

PROJECT_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
HOST ?= xdoor.lan.xhain.space
SSH_PORT ?= 23
SSH_DEST := admin@$(HOST)
NIX_SSHOPTS := -p $(SSH_PORT)
RESULT ?= $(PROJECT_ROOT)/result
IMAGE ?= $(firstword $(wildcard $(RESULT)/sd-image/*.img.zst) $(wildcard $(PROJECT_ROOT)/output/nixos/*.img.zst))

.DEFAULT_GOAL := help

.PHONY: help image firmware check-image flash deploy generate-secrets provision shell test lint format clean

help:
	@echo "xDoor2 targets:"
	@echo "  image             Build the compressed NixOS Raspberry Pi image"
	@echo "  flash             Write the image to DEVICE=/dev/..."
	@echo "  provision         Install decrypted runtime secrets on a booted device"
	@echo "  deploy            Switch a booted device to this NixOS configuration"
	@echo "  shell             Open the administrative SSH console"
	@echo "  test/lint/format  Run Python development checks through uv"

image:
	nix build "path:$(PROJECT_ROOT)#image" --out-link "$(RESULT)"

# Compatibility for scripts which used the old target name.
firmware: image

check-image:
	@test -n "$(IMAGE)" || { echo "No SD image found. Run 'make image' or the documented Mac container build first." >&2; exit 1; }

flash: check-image
	@test -n "$(DEVICE)" || { echo "Set DEVICE to the target block device." >&2; exit 1; }
	zstd -dc "$(IMAGE)" | sudo dd of="$(DEVICE)" bs=4194304
	sync

deploy:
	NIX_SSHOPTS='$(NIX_SSHOPTS)' nixos-rebuild switch \
		--flake "path:$(PROJECT_ROOT)#xdoor2" \
		--target-host "$(SSH_DEST)" \
		--use-remote-sudo

generate-secrets:
	mkdir -p secrets priv
	sops -d --extract '["mqtt_password"]' secrets.yml > secrets/mqtt_pw
	sops -d --extract '["authorized_keys_pub_pem"]' secrets.yml > priv/authorized_keys_pub.pem

provision: generate-secrets
	scp -P "$(SSH_PORT)" secrets/mqtt_pw priv/authorized_keys_pub.pem "$(SSH_DEST):/tmp/"
	ssh -p "$(SSH_PORT)" "$(SSH_DEST)" \
		"sudo install -d -m 0750 -o root -g xdoor2 /var/lib/xdoor2/secrets && \
		 sudo install -m 0440 -o root -g xdoor2 /tmp/mqtt_pw /var/lib/xdoor2/secrets/mqtt_password && \
		 sudo install -m 0440 -o root -g xdoor2 /tmp/authorized_keys_pub.pem /var/lib/xdoor2/secrets/authorized_keys_pub.pem && \
		 rm -f /tmp/mqtt_pw /tmp/authorized_keys_pub.pem && \
		 sudo systemctl restart xdoor2"

shell:
	ssh -p "$(SSH_PORT)" "$(SSH_DEST)"

test:
	uv run pytest

lint:
	uv run ruff check .
	uv run ty check src

format:
	uv run ruff format .
	uv run ruff check --fix .
	nix fmt flake.nix nixos/admin-keys.nix nixos/package.nix nixos/rpi3-image.nix nixos/xdoor2.nix

clean:
	rm -f "$(RESULT)"
