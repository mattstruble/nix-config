{{- /*
Common labels. `app.kubernetes.io/part-of: forecats` and
`app.kubernetes.io/component: gpu-job` are load-bearing in two directions.

Toward the fleet: the shim's busy-card scan selects pods on
`app.kubernetes.io/component in (model,gpu-job)` and reads the card back out of
the pod's NVIDIA_VISIBLE_DEVICES, so a render pod that is not labelled gpu-job
holds a card that reads as free to the next claim.

Toward monitoring, in the other direction: the ai-fleet ServiceMonitor selects
Services on `component: model` and the llm-log-exporter PodMonitor selects pods
on `part-of: ai` (k8s/apps/monitoring/values/kube-prometheus-stack.yaml). A
render pod carrying either of those would join the model roster and appear in
ai_model_* as a model that never answers. Neither monitor watches this
namespace, so the two selectors are the second line, not the first.
*/ -}}
{{- define "forecats.labels" -}}
app.kubernetes.io/name: forecats
app.kubernetes.io/part-of: forecats
{{- end -}}

{{- define "forecats.renderLabels" -}}
{{ include "forecats.labels" . }}
app.kubernetes.io/component: gpu-job
{{- end -}}

{{- /*
The namespace, or a refusal. The render runs with no --namespace, so
.Release.Namespace answers "default" here and would put a RoleBinding subject in
a namespace the apply pass never creates. nix supplies the value from
`forecatsStorage.namespace`, which is also what the generated PVs' claimRef and
the apply pass's -n read.
*/ -}}
{{- define "forecats.namespace" -}}
{{- required "namespace: set by forecatsStorage in nix/services/k3s.nix, which also generates the PVs' claimRef from it and is the namespace the apply pass creates with -n" .Values.namespace -}}
{{- end -}}

{{- /*
One volume from the list nix generates from `forecatsStorage.volumes`, by the
attribute name it was declared under. A chart that named a claim here could name
one that binds nothing; a chart that reads the list cannot, and moving a volume
is a change to the declaration and to nothing else.

The mount path is the host path, which is what the pipeline wrapper's exported
FORECATS_MODEL_DIRECTORY / FORECATS_PHOTO_DIRECTORY are built from — so a render
reads the same directory the host fills, in the pod and out of it.
*/ -}}
{{- define "forecats.volumeFor" -}}
{{- $want := .name -}}
{{- $found := dict -}}
{{- range .ctx.Values.persistence.volumes -}}
{{- if eq $want .name -}}
{{- $found = . -}}
{{- end -}}
{{- end -}}
{{- if not $found -}}
{{- fail (printf "persistence.volumes has no volume named %q. That list is generated from forecatsStorage.volumes in nix/services/k3s.nix; a template asking for a volume the declaration does not have is a template that would mount a claim nothing binds." $want) -}}
{{- end -}}
{{- toYaml $found -}}
{{- end -}}

{{- /*
Pod `volumes:` entries for the declared volumes, plus the emptyDir /tmp every
container in this chart needs: the root filesystem is read-only at PodSecurity
`restricted`, and both the shim's flock and Python's bytecode cache want to write.

Both this helper and the next build a list and emit it with `toYaml`. A helper
that concatenates YAML lines by hand has to place every newline itself, and the
failure is a render that dies on "mapping values are not allowed in this
context" three files away from the line that caused it.
*/ -}}
{{- define "forecats.volumes" -}}
{{- $volumes := list -}}
{{- range .Values.persistence.volumes -}}
{{- $volumes = append $volumes (dict "name" (printf "data-%s" .name) "persistentVolumeClaim" (dict "claimName" (required "persistence.volumes[].claimName is generated from forecatsStorage.volumes in nix/services/k3s.nix" .claimName))) -}}
{{- end -}}
{{- $volumes = append $volumes (dict "name" "tmp" "emptyDir" (dict "sizeLimit" "256Mi")) -}}
{{- toYaml $volumes -}}
{{- end -}}

{{- /*
Pod `volumeMounts:` for the named volumes only. Pass (dict "ctx" $ "names"
(list "panels" "weights")), and optionally "readOnly" true to force the mounts
read-only for a pod that must not write even a volume its claim would allow. A
name the declaration does not have fails the render rather than silently mounting
less than the pod needs.
*/ -}}
{{- define "forecats.volumeMounts" -}}
{{- $mounts := list -}}
{{- $mounted := list -}}
{{- range .ctx.Values.persistence.volumes -}}
{{- if has .name $.names -}}
{{- $mounted = append $mounted .name -}}
{{- $readonly := .readOnly -}}
{{- if $.readOnly -}}
{{- $readonly = true -}}
{{- end -}}
{{- $mounts = append $mounts (dict "name" (printf "data-%s" .name) "mountPath" (required "persistence.volumes[].mountPath is the host path forecatsStorage declares, and the path the render reads" .mountPath) "readOnly" $readonly) -}}
{{- end -}}
{{- end -}}
{{- range $.names -}}
{{- if not (has . $mounted) -}}
{{- fail (printf "a forecats pod asks for the volume %q and forecatsStorage.volumes does not declare it." .) -}}
{{- end -}}
{{- end -}}
{{- $mounts = append $mounts (dict "name" "tmp" "mountPath" "/tmp") -}}
{{- toYaml $mounts -}}
{{- end -}}

{{- /*
The address a viewer reports a suspected violation of the MiniMax H3 grant to.
It is required by the render and by the pipeline's publish stage, and it is the
one value in this chart that an obligation, rather than a preference, put there.
*/ -}}
{{- define "forecats.reportAddress" -}}
{{- required "report.address: set by services.k3s.forecats.reportAddress, which the grant obliges; the render refuses a publish without it and the viewer refuses to render without it" .Values.report.address -}}
{{- end -}}

{{- /*
PodSecurity `restricted` at container level, for every container in this chart.

k3s v1.35.8+k3s1 drops `readOnlyRootFilesystem` from the POD-level
securityContext as an unknown field — and `kubectl patch` strips it silently — so
setting it once above the containers would leave every container with a writable
root and no error anywhere. It is repeated per container because that is the only
level the API keeps it at.
*/ -}}
{{- define "forecats.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
{{- end -}}

{{- define "forecats.podSecurityContext" -}}
runAsNonRoot: true
seccompProfile:
  type: RuntimeDefault
{{- end -}}
