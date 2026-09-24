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

# render the ai chart with all per-model values files (one -f each; maps merge)
k8s-render:
	F=(-f k8s/apps/ai/values.yaml); for f in k8s/apps/ai/values/*.yaml; do F+=(-f "$f"); done; helm template ai k8s/apps/ai "${F[@]}"

# render + apply to mjolnir k3s (fast manual path; `just deploy mjolnir` also syncs)
k8s-deploy:
	F=(-f k8s/apps/ai/values.yaml); for f in k8s/apps/ai/values/*.yaml; do F+=(-f "$f"); done; helm template ai k8s/apps/ai "${F[@]}" > /tmp/ai-rendered.yaml && scp /tmp/ai-rendered.yaml mjolnir:/tmp/ai-rendered.yaml && ssh mjolnir 'sudo k3s kubectl apply -f /tmp/ai-rendered.yaml'
