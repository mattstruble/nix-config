#!/usr/bin/env bash
# arms.sh — nix-config-qjz: measure the 27B coding endpoint config arms ON mjolnir.
# Runs on mjolnir as mestruble. GPU1 sandbox on :8558; the fleet container on GPU1 is
# stopped for the duration (user approved; n8n/HA idle). GPU0 / :8556 flash-next untouched.
#
# Each arm = one server config: start container -> wait health -> run harness.py -> tear down.
# Resumable: an arm with <label>.done is skipped. Failures do not abort the queue.
#
#   nohup ./arms.sh > /var/lib/llama-quality/nohup.log 2>&1 &
#   tail -f /var/lib/llama-quality/driver.log
#
# Args are ';'-delimited, never eval'd: the chat-template-kwargs JSON contains braces and
# commas, which bash brace-expands out of an eval'd string.
set -uo pipefail

OUT=/var/lib/llama-quality
HARNESS=$OUT/harness.py
TEMPLATE=$OUT/qwen3-chat-template.jinja
HARDTPL=$OUT/qwen3-chat-template-hardened.jinja
TB=/nix/store/hcjwnnl6g6hycvm6qa17dc8nc7x8hxpp-llama-cpp-turboq-0.3.0-8f2b243/bin/llama-server
IMG=nvidia/cuda@sha256:af25d2ef68f7aedaf0eb179e67773e64feefc3b65a12f59a6cd604ca7c53bb57
MODEL=/models/Qwen3.8-27B-UD-Q4_K_XL.gguf
GPU=1
PORT=8558
CONT=q27b-sbx
LOG=$OUT/driver.log
FLEET_UNIT=docker-llama-qwen3-6-35b-iq4xs.service

KW_PROD='{"reasoning_effort":"medium","preserve_thinking":true}'
KW_NOPRES='{"reasoning_effort":"medium","preserve_thinking":false}'
KW_JSON='{"reasoning_effort":"medium","preserve_thinking":true,"tool_call_format":"json"}'

# prod args (modules/hosts/mjolnir/_llama-models.nix qwen3-8-27b), with -cram reduced
# 16384 -> 1024: the host holds flash-next's 92 GiB mmap, and -cram only affects
# cross-prompt persistence, which none of these suites use.
CORE="-ngl;99;-c;131072;-ub;1024;-np;1;--flash-attn;on;-cram;1024"
KV="--cache-type-k;q8_0;--cache-type-v;q8_0"
SWA="--override-kv;qwen35.attention.sliding_window=int:4096,qwen35.attention.swa_global_layers=int:8"
TPL="--jinja;--chat-template-file;/app/qwen3-chat-template.jinja"
THINK="--reasoning-budget;8192;--reasoning-format;deepseek"
MTP="--spec-type;draft-mtp;--spec-draft-n-max;2;--spec-draft-n-min;1"
SAMP="--temp;0.8;--top-k;40;--top-p;0.95;--min-p;0;--repeat-penalty;1.05"
BASE="$CORE;$KV;$SWA;$TPL;--chat-template-kwargs;$KW_PROD;$THINK;$MTP;$SAMP"

# label | server args | harness args | extra container env | fallback extra args
ARMS=(
  "A0_prod|$BASE|--depths 2000,20000,50000,80000 --greedy-tools||"
  "S1_qwen_think|$CORE;$KV;$SWA;$TPL;--chat-template-kwargs;$KW_PROD;$THINK;$MTP;--temp;1.0;--top-k;20;--top-p;0.95;--min-p;0;--repeat-penalty;1.0|||"
  "S2_coding|$CORE;$KV;$SWA;$TPL;--chat-template-kwargs;$KW_PROD;$THINK;$MTP;--temp;0.6;--top-p;0.8;--top-k;20;--min-p;0;--repeat-penalty;1.0|||"
  "S3_norepeat|$CORE;$KV;$SWA;$TPL;--chat-template-kwargs;$KW_PROD;$THINK;$MTP;--temp;0.8;--top-k;40;--top-p;0.95;--min-p;0;--repeat-penalty;1.0|||"
  "S4_topk20|$CORE;$KV;$SWA;$TPL;--chat-template-kwargs;$KW_PROD;$THINK;$MTP;--temp;0.8;--top-k;20;--top-p;0.95;--min-p;0;--repeat-penalty;1.05|||"
  "S5_nopreserve|$CORE;$KV;$SWA;$TPL;--chat-template-kwargs;$KW_NOPRES;$THINK;$MTP;$SAMP|||"
  "K1_swafull|$CORE;$KV;--swa-full;$TPL;--chat-template-kwargs;$KW_PROD;$THINK;$MTP;$SAMP|||-c;65536"
  "K2_native|$CORE;$KV;$TPL;--chat-template-kwargs;$KW_PROD;$THINK;$MTP;$SAMP||||"
  "K3_f16v|$CORE;--cache-type-k;q8_0;--cache-type-v;f16;$SWA;$TPL;--chat-template-kwargs;$KW_PROD;$THINK;$MTP;$SAMP||||"
  "K4_creuse0|$BASE;--cache-reuse;0||||"
  "T1_hardtpl|$CORE;$KV;$SWA;--jinja;--chat-template-file;/app/hardened.jinja;--chat-template-kwargs;$KW_PROD;$THINK;$MTP;$SAMP||||"
  "T2_json|$CORE;$KV;$SWA;$TPL;--chat-template-kwargs;$KW_JSON;$THINK;$MTP;$SAMP|--tools-only||"
  "M1_nomtp|$CORE;$KV;$SWA;$TPL;--chat-template-kwargs;$KW_PROD;$THINK;$SAMP||||"
  "M2_graphs|$BASE||GGML_CUDA_DISABLE_GRAPHS=0||"
)

log() { echo "[$(date +%m-%d' '%H:%M:%S)] $*" | tee -a "$LOG"; }

start_container() { # $1=label $2=args-string(-delimited) $3=env $4=logfile
  local label=$1 args=$2 envs=$3 lf=$4
  local -a srv=() envarr=(-e GGML_CUDA_DISABLE_GRAPHS=1) x
  IFS=';' read -r -a srv <<<"$args"
  local -a clean=()   # drop empties from a trailing delimiter
  for x in "${srv[@]}"; do [ -n "$x" ] && clean+=("$x"); done
  srv=("${clean[@]}")
  [ -n "$envs" ] && envarr+=(-e "$envs")
  sudo docker rm -f "$CONT" >/dev/null 2>&1
  sudo docker run -d --name "$CONT" --device "nvidia.com/gpu=$GPU" --ipc=host --shm-size 32g \
    -v /nix/store:/nix/store:ro -v /var/lib/llama-models:/models \
    -v "$TEMPLATE:/app/qwen3-chat-template.jinja:ro" -v "$HARDTPL:/app/hardened.jinja:ro" \
    -p "$PORT:8080" "${envarr[@]}" "$IMG" "$TB" -m "$MODEL" --alias q27b-sbx \
    --host 0.0.0.0 --port 8080 --api-key foo "${srv[@]}" >"$lf" 2>&1
}

wait_health() { # $1=label $2=logfile
  local label=$1 lf=$2 i vram
  for i in $(seq 1 150); do
    if curl -sf "http://localhost:$PORT/health" >/dev/null 2>&1; then
      vram=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits -i "$GPU" | head -1)
      log "$label: healthy after $((i * 4))s, GPU$GPU ${vram} MiB"
      grep -iE "sliding|swa|n_ctx_slot|type_k|type_v|draft|grammar|MTP|error" "$lf" | head -20 >>"$LOG"
      return 0
    fi
    if tail -60 "$lf" | grep -qiE "out of memory|CUDA error|failed to load|exiting due to"; then
      log "$label: startup failure"
      tail -20 "$lf" >>"$LOG"
      return 1
    fi
    sleep 4
  done
  log "$label: HEALTH TIMEOUT"
  tail -30 "$lf" >>"$LOG"
  return 1
}

run_arm() { # $1=label $2=args $3=harness args $4=env $5=fallback extra args
  local label=$1 args=$2 hargs=$3 envs=$4 fb=$5
  local lf="$OUT/$label.startup.log" rl runs i
  [ -f "$OUT/$label.done" ] && { log "$label: already done, skipping"; return 0; }
  log "$label: starting [${args//;/ }]"
  start_container "$label" "$args" "$envs" "$lf"
  if ! wait_health "$label" "$lf"; then
    if [ -n "$fb" ]; then
      log "$label: retrying with fallback [${fb//;/ }]"
      start_container "$label" "$args;$fb" "$envs" "$lf"
      wait_health "$label" "$lf" || { log "$label: FAILED"; return 1; }
      label="${label}_fb"   # keep results under the actually-used config
    else
      log "$label: FAILED to start"
      return 1
    fi
  fi
  runs=1
  [ "$label" = "A0_prod" ] && runs=2   # repeat the control to measure the noise floor
  for i in $(seq 1 $runs); do
    rl="$label"
    [ "$i" = "2" ] && rl="${label}_run2"
    log "$rl: harness running"
    # shellcheck disable=SC2086
    python3 "$HARNESS" --base "http://localhost:$PORT" --label "$rl" --outdir "$OUT" \
      --gpu "$GPU" --corpus "$OUT/corpus.txt" $hargs >"$OUT/$rl.harness.log" 2>&1
    log "$rl: harness exit=$? :: $(tr '\n' ' ' <"$OUT/$rl.harness.log" | tail -c 380)"
  done
  sudo docker logs "$CONT" >>"$lf" 2>&1
  sudo docker rm -f "$CONT" >/dev/null 2>&1
  touch "$OUT/$label.done"
  log "$label: DONE"
}

mkdir -p "$OUT"
if systemctl is-active --quiet "$FLEET_UNIT"; then
  log "stopping $FLEET_UNIT (GPU1 sandbox; user approved, n8n/HA idle)"
  sudo systemctl stop "$FLEET_UNIT" 2>&1 | tee -a "$LOG"
fi
log "=== queue start: ${#ARMS[@]} arms ==="
for entry in "${ARMS[@]}"; do
  IFS='|' read -r label args hargs envs fb <<<"$entry"
  run_arm "$label" "$args" "$hargs" "$envs" "$fb" || log "$label: continuing after failure"
done
log "=== ALL ARMS DONE ==="
