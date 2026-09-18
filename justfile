# vim: set ft=make :
# https://github.com/notthebee/nix-config/blob/main/justfile
set quiet

lint:
  pre-commit install
  pre-commit run --all-files

update:
  nix flake update

deploy $host:
	nix run .#deploy-rs -- .#{{host}}

check-clean:
	if [ -n "$(git status --porcelain)" ]; then echo -e "\e[31merror\e[0m: git tree is dirty. Refusing to copy configuration." >&2; exit 1; fi

copy $host: check-clean
	rsync -ax --delete --rsync-path="sudo rsync" ./ {{host}}:/etc/nixos/

build-rpi $host:
	nix build .#nixosConfigurations.{{host}}.config.system.build.sdImage

build-rpi-images:
	just build-rpi clown
	just build-rpi pebble
	just build-rpi thistle
	just build-rpi sevro

build: build-rpi-images

darwin-switch $host="MacStruble":
	darwin-rebuild switch --flake .#{{host}}

darwin-build $host="MacStruble":
	nix build .#darwinConfigurations.{{host}}.system

# render the llama-fleet chart with all per-model values files (one -f each; maps merge)
k8s-render:
	F=(-f k8s/llama-fleet/values.yaml); for f in k8s/llama-fleet/values/*.yaml; do F+=(-f "$f"); done; helm template llama-fleet k8s/llama-fleet "${F[@]}"

# render + apply to mjolnir k3s
k8s-deploy:
	F=(-f k8s/llama-fleet/values.yaml); for f in k8s/llama-fleet/values/*.yaml; do F+=(-f "$f"); done; helm template llama-fleet k8s/llama-fleet "${F[@]}" > /tmp/llama-fleet-rendered.yaml && scp /tmp/llama-fleet-rendered.yaml mjolnir:/tmp/llama-fleet-rendered.yaml && ssh mjolnir 'sudo k3s kubectl apply -f /tmp/llama-fleet-rendered.yaml'
