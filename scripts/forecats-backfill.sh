#!/usr/bin/env bash
# Backfill the nightly gallery: one render per past day, sequential.
#
#   ssh mjolnir 'sudo /var/lib/llama-models/backfill.sh 2026-11-21 2026-11-22 ...'
#
# Each day gets a manual Job created from the nightly CronJob with
# FORECATS_FOR_DAY patched in before the pod starts (the dry-run/apply dance, so
# there is no race with the pod's own start). The claimer's dedup check reads the
# same override, so a day that already has its panel is skipped, and a failed day
# stops the batch — a half-backfilled gallery is what the next run corrects.
set -euo pipefail

[ "$#" -ge 1 ] || { echo "usage: $0 YYYY-MM-DD [YYYY-MM-DD ...]" >&2; exit 2; }
for day in "$@"; do
  date -d "$day" +%Y-%m-%d >/dev/null 2>&1 || { echo "not a date: $day" >&2; exit 2; }
done

K() { sudo k3s kubectl "$@"; }

for day in "$@"; do
  name="backfill-${day}"
  echo "== $day"
  if K get job -n forecats "$name" >/dev/null 2>&1; then
    status=$(K get job -n forecats "$name" -o jsonpath='{.status.conditions[0].type}' 2>/dev/null || true)
    if [ "$status" = "Complete" ]; then echo "   already complete; skipping"; continue; fi
    echo "   rerunning (was $status)"
    K delete job -n forecats "$name" >/dev/null
  fi
  # The day override is set on the CLAIMER pod (the run script exports it to the
  # render pod beside the card), which is why the patch lands before creation.
  # -o json, not yaml: the file is read back with json.load, and a YAML document
  # parses to nothing from char 0. Via a file, not a pipe, because sudo and a
  # piped stdin disagree on who owns it.
  tmp=$(mktemp)
  K create job --from=cronjob/forecats-nightly "$name" -n forecats --dry-run=client -o json > "$tmp"
  python3 - "$day" "$tmp" <<'PYEOF'
import json, sys
day, path = sys.argv[1], sys.argv[2]
job = json.load(open(path))
env = job["spec"]["template"]["spec"]["containers"][0].setdefault("env", [])
env[:] = [e for e in env if e.get("name") != "FORECATS_FOR_DAY"]
env.append({"name": "FORECATS_FOR_DAY", "value": day})
json.dump(job, open(path, "w"))
PYEOF
  K apply -f "$tmp" >/dev/null
  rm -f "$tmp"
  # Wait for the whole chain: claim -> render -> publish. The job's own
  # backoffLimit bounds a day that keeps failing; the alerting reads the same
  # failure the operator would.
  K wait --for=condition=complete "job/$name" -n forecats --timeout=40m >/dev/null 2>&1 \
    || { echo "   FAILED or timed out; stopping the batch" >&2; exit 1; }
  echo "   published"
done
echo "== gallery manifest:"
K get cm -n forecats forecats-render-job >/dev/null # sanity: the chart is present
