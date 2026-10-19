{{/*
The Strata bundle's /nix/store path.

Injected by the nix render through .Values.strataBundle (fed by
services.k3s.aiChart.strataBundle in nix/hosts/mjolnir/default.nix), so the path
the pod mounts is produced by the build rather than transcribed into a values
file - which is what puts the bundle in the generation's closure instead of
needing a hand-maintained pin, a drift check and a manual GC root.

Per-model `binary:` still wins for a standalone `helm template` (CI manifest
diff, `just k8s-render`) where no nix render supplied a path.

Usage: {{ include "ai.strataBundle" (dict "root" $ "m" $m "name" $name) }}
*/}}
{{- define "ai.strataBundle" -}}
{{- $b := .root.Values.strataBundle | default .m.binary | default "" -}}
{{- if not $b -}}
{{- fail (printf "strata model %q has no bundle: .Values.strataBundle is empty and the model sets no binary. The nix render injects it from services.k3s.aiChart.strataBundle; for a standalone helm render pass --set strataBundle=/nix/store/...-strata-<version>." .name) -}}
{{- end -}}
{{- $b -}}
{{- end -}}

{{/*
Shared building blocks for the model pods.

model-deployment.yaml (llama.cpp) and strata-deployment.yaml (Strata) render the
same pod: same labels, same hardening, same log-exporter sidecar, same backing
volumes. They drifted the moment the second one was written (probe thresholds,
then a duplicated self-contradicting comment), so the shared parts live here.

Everything in this file must keep the RENDERED OBJECT unchanged — a change to a
pod template is a rollout, and these pods hold a GPU. Check with:
  ruby /tmp/norm.rb > /tmp/after.json && diff /tmp/before.json /tmp/after.json
*/}}

{{/*
Labels every model pod carries. app.kubernetes.io/component: model is the
network-policy selector (k8s/manifests/ai-networkpolicies.yaml) and the
ai-fleet ServiceMonitor's selector; app.kubernetes.io/part-of: ai is what the
llm-log-exporter PodMonitor selects. A new model gets scraped and netpol-covered
from these labels alone — nothing per-model to edit.
Usage: {{- include "ai.modelLabels" $name | nindent 4 }}
*/}}
{{- define "ai.modelLabels" -}}
app: {{ . }}
app.kubernetes.io/part-of: ai
app.kubernetes.io/component: model
{{- end -}}

{{/*
Container hardening. readOnlyRootFilesystem is container-level, not pod-level:
this k3s build's PodSecurityContext struct drops the field (unknown-field
rejection), the container SecurityContext keeps it. The only writable scratch is
the /tmp emptyDir (dies with the pod). Validated on gemma 2026-09-24.
Usage: {{- include "ai.harden" . | nindent 10 }}
*/}}
{{- define "ai.harden" -}}
securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL
  seccompProfile:
    type: RuntimeDefault
  readOnlyRootFilesystem: true
{{- end -}}

{{/*
Graceful-drain pause. The server closes its listener as soon as SIGTERM lands
(llama.cpp in its handler, Strata via httpd.shutdown first), but the pod is only
removed from the EndpointSlices asynchronously and the LiteLLM gateway's view
lags that - requests arriving in the gap get connection-refused instead of being
served or retried. Sleeping before SIGTERM gives propagation time to catch up;
it runs inside terminationGracePeriodSeconds, which is 120s here.
Usage: {{- include "ai.preStopDrain" . | nindent 10 }}
*/}}
{{- define "ai.preStopDrain" -}}
lifecycle:
  preStop:
    exec:
      command: [sh, -c, "sleep 5"]
{{- end -}}

{{/*
The engine adapter sidecar: tails the model's log (shared emptyDir), exposes the
LIVE rate/phase/progress as engine-neutral gauges, emits the per-request record
({"event":"llm_req",...}) that becomes the fleet's performance history, and
echoes each log line to its own stdout so Alloy still ships the model log to
Loki. Port 9399 is scraped by the llm-log-exporter PodMonitor at 2s - that
interval is load-bearing, see the configmap's header comment.

It also POLLS the engine on loopback once a second, which is why it needs two
things a pure log tailer never did:
  ENGINE_URL - the engine listens on localhost inside the pod, on the model's
    own port (the same one the Service targets).
  ENGINE_API_KEY - both engines gate every endpoint except /health behind the
    shared pod key (litellm-keys/pod-api-key: llama-server's --api-key, strata's
    API_KEY). Without it /metrics and /slots answer 401 and the live view is
    silently empty, so this is mounted rather than optional.

MODEL must be the DEPLOYMENT NAME, not modelName: it is the label the fleet
dashboard's $model variable and every {model=~"$model"} panel filter key off,
and it matches the model ServiceMonitor's job label.
Usage: {{- include "ai.logExporterSidecar" (dict "name" $.name "port" $.m.port "engine" "strata") | nindent 8 }}
*/}}
{{- define "ai.logExporterSidecar" -}}
- name: log-exporter
  image: python:3.12-alpine
  command: [python, /exporter.py]
  env:
    - name: LOG_FILE
      value: /var/log/llama.log
    - name: MODEL
      value: {{ .name }}
    - name: POD
      valueFrom:
        fieldRef:
          fieldPath: metadata.name
    - name: PORT
      value: "9399"
    - name: ENGINE
      value: {{ .engine | default "llama" | quote }}
    - name: ENGINE_URL
      value: http://127.0.0.1:{{ required "logExporterSidecar needs the engine port" .port }}
    - name: ENGINE_API_KEY
      valueFrom:
        secretKeyRef:
          name: litellm-keys
          key: pod-api-key
  ports:
    - name: log-exporter
      containerPort: 9399
  # It is a stdlib http.server tailing a file, so the numbers are small - but
  # without a request the container is BestEffort and the first thing evicted
  # under node memory pressure, which silently stops both the live-rate gauges
  # and the model log's trip to Loki. The limit is generous against its working
  # set (one line at a time); OOMKilling the exporter would be the worse failure.
  resources:
    requests:
      cpu: 10m
      memory: 32Mi
    limits:
      memory: 128Mi
  volumeMounts:
    - name: log
      mountPath: /var/log
      readOnly: true
    - name: exporter-script
      mountPath: /exporter.py
      subPath: exporter.py
      readOnly: true
{{- end -}}

{{/*
Volumes every model pod needs, in the order both templates already emit them —
volume order is part of the pod object, so anything engine-specific (nix-store,
chat-template, extraVolumes, shm) is appended by the template, not reordered
here. models is the read-only models PVC; log is the emptyDir the model's stdout
is redirected into and the sidecar tails.
Usage: {{- include "ai.modelCommonVolumes" . | nindent 8 }}
*/}}
{{- define "ai.modelCommonVolumes" -}}
- name: tmp
  emptyDir:
    sizeLimit: 1Gi
- name: models
  persistentVolumeClaim:
    claimName: llama-models-pvc
- name: log
  emptyDir:
    sizeLimit: 200Mi
- name: exporter-script
  configMap:
    name: llm-log-exporter
{{- end -}}
