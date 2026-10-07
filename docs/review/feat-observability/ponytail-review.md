# ponytail-review: observability branch

Scope: `git diff main...HEAD` (30 files, +5925/−65). Over-engineering only —
correctness, security, and performance are out of scope.

## k8s/apps/ai/templates/gateway-testpod.yaml

- L1-83: delete: 83-line copy of the prod gateway deployment (git sees it as a 67% copy of gateway-deployment.yaml) for pre-cutover key-minting validation, now disabled (`testPod: false`) with the cutover done. Nothing replaces it.

## k8s/apps/ai/values.yaml

- L35-37: delete: `testPod: false` + its 2-line comment (the throwaway it gates is gone). Nothing replaces it.

## k8s/apps/ai/templates/postgres-deployment.yaml, postgres-pvc.yaml, postgres-service.yaml

- L1: delete: `or .Values.gateway.testPod` in the gate of all three. `{{- if .Values.gateway.usePostgresKeys }}`, net 0.

## k8s/apps/ai/templates/model-deployment.yaml

- L4-5: yagni: `$m.binary` branch set by no model (all 8 values files use `command`). Drop the branch; the 8-line block becomes 5.

## k8s/apps/ai/templates/log-exporter-configmap.yaml

- L50-51: shrink: `with open(LOG_FILE, "w"): pass` truncates the log. `os.truncate(LOG_FILE, 0)`, 1 line.

## nix/services/k3s.nix

- L74-99: shrink: three identical 6-line runCommand chart renderers (dcgm/loki/alloy) + the 3-line system.build block. One `lib.genAttrs` over a {chart, values} attrset, ~11 lines.
- L266-268: shrink: grep/grep/head/sed parses the rendered chart for the pod API key. `${pkgs.yq}/bin/yq -r '.gateway.podApiKey' ${k8sDir}/apps/ai/values.yaml`, 1 line.

## No findings

- .gitignore, .pre-commit-config.yaml, .sops.yaml, justfile
- k8s/apps/ai/templates/gateway-configmap.yaml, gateway-deployment.yaml, gateway-service.yaml, model-service.yaml
- k8s/manifests/cloud-model-rates.yaml (PromQL cannot label a vector without label_replace — the 15 rules are the idiom), kubelet-monitoring.yaml, local-pvs.yaml
- k8s/apps/monitoring/dashboards/cluster-overview.json, llm-fleet.json, llm-overview.json (dashboard data), llama-metrics.md, values/alloy.yaml, values/dcgm-exporter.yaml, values/kube-prometheus-stack.yaml, values/loki.yaml
- nix/services/homelab/homelab-secrets.yaml, scripts/mint-litellm-key.sh, docs/runbook-mint-litellm-key.md

net: -107 lines possible.
