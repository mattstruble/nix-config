{{/*
One model's Deployment, rendered from its values entry.

Extracted from model-deployment.yaml so the same body can be emitted two ways:
inline (a model with a static lifecycle, which is what everything has today) and
as JSON inside the head-end's spec ConfigMap (a model the swapper owns the
lifecycle of). Those two must not be able to drift - a model that renders one way
when it is static and another way when it is summoned is a bug you find out about
by waking the model.

Everything here must keep the RENDERED OBJECT unchanged; these pods hold a GPU.
Verified by rendering before and after and diffing the parsed documents:
  helm template ... | python3 scripts/normalize-manifest.py > before.json

Context: dict "name" <model key> "m" <model values>. $ stays that dict inside
nested ranges, which is why the body reads $.m / $.name.
*/}}
{{- define "ai.modelDeployment" -}}
{{- $binary := "" }}
{{- if $.m.binary }}
{{- $binary = $.m.binary }}
{{- else if $.m.command }}
{{- $binary = index $.m.command 0 }}
{{- else }}
{{- $binary = "/app/llama-server" }}
{{- end }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ $.name }}
  labels:
    {{- include "ai.modelLabels" $.name | nindent 4 }}
    # placement contract: the pool this model may land on and how to read it.
    # The shim (src/swapk8s) selects on these when it narrows the spec's
    # NVIDIA_VISIBLE_DEVICES pool to a free card at wake time.
    {{- with $.m.gpu }}
    ai.mestruble.dev/gpu-pool: {{ . | quote }}
    {{- end }}
    ai.mestruble.dev/gpu-mode: {{ $.m.gpuMode | default "any" | quote }}
spec:
  # Recreate: each model owns its whole GPU (20+ GiB of 24 GiB), so a
  # RollingUpdate would run old + new pods concurrently and OOM the load.
  strategy:
    type: Recreate
  replicas: 1
  selector:
    matchLabels:
      app: {{ $.name }}
  template:
    metadata:
      labels:
        {{- include "ai.modelLabels" $.name | nindent 8 }}
    spec:
      runtimeClassName: nvidia
      # let in-flight generations finish on shutdown/rollout (default 30s
      # SIGKILLs mid-token)
      terminationGracePeriodSeconds: 120
      # The pinned images declare no non-root USER, so an explicit non-zero UID
      # forces the process off root (runAsNonRoot alone would be rejected).
      # /models, /nix/store and the GGUFs are world-readable.
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        runAsNonRoot: true
      automountServiceAccountToken: false
      containers:
        - name: llama-server
          {{- include "ai.harden" . | nindent 10 }}
          image: {{ $.m.image }}
          {{- include "ai.preStopDrain" . | nindent 10 }}
          # redirect stdout to /var/log/llama.log so the log-exporter sidecar can
          # tail it and expose the live decode/prefill rates (tg_3s / tokens per
          # second) as gauges — the native gauges only tick at completion
          # (verified live 2026-10-05, see llama-metrics.md). The shell wrapper
          # passes the binary as $0 and all args as $@, so each arg stays a separate
          # parameter (no re-parsing of the JSON chat-template-kwargs) and fork models
          # pinning a /nix/store binary work too. exec keeps the binary as PID 1
          # (no tee: a pipeline would break PID-1 graceful shutdown).
          command:
            - sh
            - -c
            - 'exec "$0" "$@" >> /var/log/llama.log 2>&1'
          # the binary is $0 (first arg); the model args + fleet flags are $@.
          # quote every arg: YAML parses on/off as booleans and bare numbers as ints,
          # and k8s args must all be strings.
          args:
            - {{ $binary | quote }}
            {{- range $.m.args }}
            - {{ . | quote }}
            {{- end }}
            - "--host"
            - "0.0.0.0"
            - "--port"
            - {{ $.m.port | quote }}
            # Prometheus metrics at /metrics (auth: same --api-key as the rest)
            - "--metrics"
            # the running model name: single source of truth (also the gateway's model_name)
            - "--alias"
            - {{ $.m.modelName | quote }}
          env:
            - name: NVIDIA_VISIBLE_DEVICES
              value: {{ $.m.gpu | quote }}
            # authenticates the LiteLLM gateway (and any direct caller): the
            # litellm-keys Secret's pod-api-key, read by llama-server as the
            # --api-key equivalent (llama.cpp tools/server/README.md).
            - name: LLAMA_API_KEY
              valueFrom:
                secretKeyRef:
                  name: litellm-keys
                  key: pod-api-key
            # CORRECTNESS guard, not perf: CUDA graphs + spec decode + a
            # prefix-cache hit corrupt output (repetition collapse / empty
            # completions).
            - name: GGML_CUDA_DISABLE_GRAPHS
              value: "1"
          ports:
            - containerPort: {{ $.m.port }}
          # llama-server serves /health from before the model is loaded and
          # returns 503 "Loading model" until load_model() completes, so
          # /health is a correct ready signal. startupProbe covers the
          # multi-minute 20GB load (30 x 10s = 5 min); readinessProbe gates
          # gateway traffic. No livenessProbe: it would kill pods mid-generation
          # on long prompts.
          startupProbe:
            httpGet:
              path: /health
              port: {{ $.m.port }}
            periodSeconds: 10
            failureThreshold: 30
          readinessProbe:
            httpGet:
              path: /health
              port: {{ $.m.port }}
            periodSeconds: 10
          volumeMounts:
            - name: models
              mountPath: /models
              readOnly: true
            - name: tmp
              mountPath: /tmp
            - name: log
              mountPath: /var/log
            {{- if $.m.nixBinary }}
            - name: nix-store
              mountPath: /nix/store
              readOnly: true
            {{- end }}
            {{- if $.m.chatTemplate }}
            # single-file subPath mount: adds /app/qwen3-chat-template.jinja without
            # shadowing the image's /app (where the llama-server binary lives).
            - name: chat-template
              mountPath: /app/qwen3-chat-template.jinja
              subPath: qwen3-chat-template.jinja
              readOnly: true
            {{- end }}
            {{- range $.m.extraMounts }}
            - name: {{ .name }}
              mountPath: {{ .mountPath }}
              readOnly: {{ .readOnly | default false }}
            {{- end }}
            - name: shm
              mountPath: /dev/shm
          resources:
            requests:
              memory: {{ $.m.memoryRequest }}
            limits:
              memory: {{ $.m.memoryLimit }}
        {{- include "ai.logExporterSidecar" $.name | nindent 8 }}
      volumes:
        {{- include "ai.modelCommonVolumes" . | nindent 8 }}
        {{- if $.m.nixBinary }}
        - name: nix-store
          persistentVolumeClaim:
            claimName: nix-store-pvc
        {{- end }}
        {{- if $.m.chatTemplate }}
        - name: chat-template
          configMap:
            name: qwen3-chat-template
        {{- end }}
        {{- range $.m.extraVolumes }}
        - name: {{ .name }}
          {{- if .emptyDir }}
          emptyDir: {{ toYaml .emptyDir | nindent 12 }}
          {{- end }}
          {{- if .hostPath }}
          hostPath:
            path: {{ .hostPath }}
            type: DirectoryOrCreate
          {{- end }}
        {{- end }}
        - name: shm
          emptyDir:
            medium: Memory
            sizeLimit: 32Gi
{{- end -}}
