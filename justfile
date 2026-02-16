# vim: set ft=make :
# https://github.com/notthebee/nix-config/blob/main/justfile
set quiet

REBUILD_CMD := if `uname` == "Darwin" { "darwin-rebuild" } else { "nixos-rebuild" }

lint:
  pre-commit install
  pre-commit run --all-files

update:
  nix flake update

deploy $host: (copy host)
	nix run github:serokell/deploy-rs .#{{host}} -- -- --impure

check-clean:
	if [ -n "$(git status --porcelain)" ]; then echo -e "\e[31merror\e[0m: git tree is dirty. Refusing to copy configuration." >&2; exit 1; fi

copy $host: check-clean
	rsync -ax --delete --rsync-path="sudo rsync" ./ {{host}}:/etc/nixos/

build-rpi $host:
	mkdir -p ./images
	nix run nixpkgs#nixos-generators -- -f sd-aarch64 --flake .#{{host}} --system aarch64-linux -o ./images/{{host}}.sd

build-rpi-images:
	just build-rpi clown
	just build-rpi pebble
	just build-rpi thistle
	just build-rpi sevro

build: build-rpi-images
