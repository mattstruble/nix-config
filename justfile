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

# Render every app chart under k8s/apps/. A directory is an app chart when it
# carries a Chart.yaml — the same rule nix/services/k3s.nix applies, so an app
# cannot render here and be missing from the deploy, or the other way round.
# k8s/apps/monitoring is excluded by that rule: dashboard JSON plus values for the
# vendored upstream charts, which nix renders from the release tarballs.
# The values a build supplies (store paths, host ids) are eval'd from nix and
# written per chart, so the preview applies exactly what production applies. A
# chart that needs them and does not get them fails its render rather than
# rendering something else — `required` in its templates is what makes that true.
# One chart's render failure must neither stop the others nor hide: the loop keeps
# going and the recipe still exits non-zero, because a preview that shows the
# healthy charts and says nothing about the broken one reads as "nothing changed".
# The per-chart helm arguments accumulate in the positional parameters (`set --`),
# not in a bash array: just runs this under the default `sh -cu`, and where
# /bin/sh is a true POSIX shell (dash) `F=(...)` is a syntax error that kills the
# recipe before the first chart renders.
[doc("Render every app chart under k8s/apps/")]
k8s-render:
	rc=0; V=$(mktemp -d); \
	for c in k8s/apps/*/; do \
	[ -f "$c/Chart.yaml" ] || continue; \
	name=$(basename "$c"); \
	set -- -f "$c/values.yaml"; \
	for f in "$c"values/*.yaml; do if [ -f "$f" ]; then set -- "$@" -f "$f"; fi; done; \
	if nix eval --raw ".#nixosConfigurations.mjolnir.config.services.k3s.appChartValues.$name" > "$V/$name.yaml" 2>/dev/null; then \
	set -- "$@" -f "$V/$name.yaml"; \
	else rm -f "$V/$name.yaml"; fi; \
	helm template "$name" "$c" "$@" || { echo "error: the $name chart failed to render" >&2; rc=1; }; \
	done; \
	rm -rf "$V"; exit $rc

# Mint a named LiteLLM key (alias=<name> -> per-source prometheus label), store
# it in sops, print it. Requires the gateway deployed (just deploy mjolnir).
mint-key name:
	@bash scripts/mint-litellm-key.sh "{{name}}"
