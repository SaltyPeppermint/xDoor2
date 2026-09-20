SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c

PROJECT_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
HOST ?= xdoor2.lan.xhain.space
SSH_PORT ?= 23
SSH_DEST := admin@$(HOST)
NIX_SSHOPTS := -p $(SSH_PORT)
RESULT ?= $(PROJECT_ROOT)/result
OUTPUT_DIR := $(PROJECT_ROOT)/output/nixos
IMAGE ?= $(firstword $(wildcard $(RESULT)/sd-image/*.img) $(wildcard $(OUTPUT_DIR)/*.img))
NIX_FILES := flake.nix $(wildcard nixos/*.nix)

UNAME_S := $(shell uname -s)
CONTAINER ?= $(firstword $(foreach c,container docker podman,$(if $(shell command -v $(c) 2>/dev/null),$(c))))
CONTAINER_IMAGE ?= docker.io/nixos/nix:latest
CONTAINER_CPUS ?= 8
CONTAINER_MEMORY ?= 12G

.DEFAULT_GOAL := help

.PHONY: help image image-native image-container check-image flash deploy generate-secrets provision shell test lint format clean

help:
	@echo "xDoor2 targets:"
	@echo "  image             Build the NixOS Raspberry Pi SD image"
	@echo "                    (on non-Linux hosts through $(or $(CONTAINER),a container runtime))"
	@echo "  flash             Write the image to DEVICE=/dev/..."
	@echo "  provision         Install decrypted runtime secrets on a booted device"
	@echo "  deploy            Switch a booted device to this NixOS configuration"
	@echo "  shell             Open the administrative SSH console"
	@echo "  generate-secrets  Decrypt build-time secrets into secrets/"
	@echo "  check-image       Check a built SD image is present"
	@echo "  test/lint/format  Run Python development checks through uv"
	@echo "  clean             Remove build outputs and decrypted secrets"

ifeq ($(UNAME_S),Linux)
image: image-native
else
image: image-container
endif

# MacOS thinks its special about writing to mounted disks and you have to do a little dance
ifeq ($(UNAME_S),Darwin)
UNMOUNT = diskutil unmountDisk "$(DEVICE)"
DD_DEVICE = $(patsubst /dev/disk%,/dev/rdisk%,$(DEVICE))
else
UNMOUNT = :
DD_DEVICE = $(DEVICE)
endif

image-native:
	nix build "path:$(PROJECT_ROOT)#image" --out-link "$(RESULT)"

# The link has to stay outside the bind mount otherwise this would result in a broken symlink to the hosts nix store
image-container:
	@test -n "$(CONTAINER)" || { echo "No container runtime found. Install one or set CONTAINER=..." >&2; exit 1; }
	$(CONTAINER) run --rm --cpus $(CONTAINER_CPUS) --memory $(CONTAINER_MEMORY) \
		--volume "$(PROJECT_ROOT):/workspace" \
		--workdir /workspace \
		$(CONTAINER_IMAGE) \
		sh -lc ' \
		  set -eu; \
		  git config --global --add safe.directory /workspace; \
		  nix --extra-experimental-features "nix-command flakes" \
		    build path:.#image --out-link /tmp/xdoor2-result; \
		  mkdir -p output/nixos; \
		  rm -f output/nixos/*.img; \
		  cp /tmp/xdoor2-result/sd-image/*.img output/nixos/; \
		  chmod 644 output/nixos/*.img; \
		'
	@ls -1 "$(OUTPUT_DIR)"/*.img

check-image:
	@test -n "$(IMAGE)" || { echo "No SD image found. Run 'make image' first." >&2; exit 1; }

flash: check-image
	@test -n "$(DEVICE)" || { echo "Set DEVICE to the target block device." >&2; exit 1; }
	$(UNMOUNT)
	sudo dd if="$(IMAGE)" of="$(DD_DEVICE)" bs=4194304 status=progress
	sync

deploy:
	NIX_SSHOPTS='$(NIX_SSHOPTS)' nixos-rebuild switch \
		--flake "path:$(PROJECT_ROOT)#xdoor2" \
		--target-host "$(SSH_DEST)" \
		--use-remote-sudo

generate-secrets:
	mkdir -p secrets
	sops -d --extract '["mqtt_password"]' secrets.yml > secrets/mqtt_pw

provision: generate-secrets
	scp -P "$(SSH_PORT)" secrets/mqtt_pw "$(SSH_DEST):/tmp/"
	ssh -p "$(SSH_PORT)" "$(SSH_DEST)" \
		"sudo install -d -m 0750 -o root -g xdoor2 /var/lib/xdoor2/secrets && \
		 sudo install -m 0440 -o root -g xdoor2 /tmp/mqtt_pw /var/lib/xdoor2/secrets/mqtt_password && \
		 rm -f /tmp/mqtt_pw && \
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
	nix fmt $(NIX_FILES)

clean:
	rm -f "$(RESULT)"
	rm -rf "$(PROJECT_ROOT)/output"
	rm -f "$(PROJECT_ROOT)"/secrets/mqtt_pw
