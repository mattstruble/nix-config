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
The log-exporter sidecar: tails the model's log (shared emptyDir), exposes the
live decode/prefill rates, and echoes each line to its own stdout so Alloy ships
the model log to Loki. Port 9399 is scraped by the llm-log-exporter PodMonitor
at 2s — that interval is load-bearing, see the configmap's header comment.
MODEL must be the DEPLOYMENT NAME, not modelName: it is the label the fleet
dashboard's $model variable and every {model=~"$model"} panel filter key off,
and it matches the model ServiceMonitor's job label.
Usage: {{- include "ai.logExporterSidecar" $name | nindent 8 }}
*/}}
{{- define "ai.logExporterSidecar" -}}
- name: log-exporter
  image: python:3.12-alpine
  command: [python, /exporter.py]
  env:
    - name: LOG_FILE
      value: /var/log/llama.log
    - name: MODEL
      value: {{ . }}
    - name: POD
      valueFrom:
        fieldRef:
          fieldPath: metadata.name
    - name: PORT
      value: "9399"
  ports:
    - name: log-exporter
      containerPort: 9399
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
