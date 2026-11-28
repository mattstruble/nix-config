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
The two names the nightly's own metrics carry, or a refusal.

kube-state-metrics emits no Kubernetes labels for these objects — this cluster
runs it with no `--metric-labels-allowlist`, so `kube_job_labels` and
`kube_cronjob_labels` do not exist — which leaves the object's name as the only
thing its series carries besides the namespace. templates/nightly-alerts.yaml
therefore selects on these two strings, and every other template that names the
same object reads them from here: the CronJob's `metadata.name`, the `--job` flag
the claimer passes, and the `generateName` of the Job a claim creates.

Kubernetes appends to both names — `-<unix schedule time>` behind a CronJob's
Job and five characters behind a `generateName` — so a selector over them is a
prefix match, and the alerts template asserts its own regex against names of both
shapes rather than trusting it to have been written correctly.
*/ -}}
{{- define "forecats.nightlyName" -}}
{{- required "nightly.name: the CronJob's name, which kube_cronjob_status_last_successful_time carries as cronjob_name and which the Jobs that carry kube_job_status_failed are named from" .Values.nightly.name -}}
{{- end -}}

{{- define "forecats.renderJobGenerateName" -}}
{{- required "nightly.render.jobGenerateName: the generateName prefix of the Job a claim creates; kube_job_status_failed carries that Job's own name, so the failure alert selects on this prefix" .Values.nightly.render.jobGenerateName -}}
{{- end -}}

{{- /*
The nightly's budgets, added in one place.

Four numbers decide whether a night draws: the interval between two schedule
lines, the card wait one attempt gets, the render pod's own deadline, and the
deadline the run inside the claimer stops at. They are not independent and the
relations are what break when one of them moves alone, so each relation is
asserted here, at the addition, and every template that needs a derived number
reads it from here rather than re-adding it:

  - one attempt = the card wait + the pod-claim window + the render's deadline.
    The window is a term because the claimer holds the placement flock for it
    after its command exits, confirming a gpu-job pod carrying the card appeared;
    the render's deadline is a term because the run waits for the Job it created.
  - the run deadline must hold two attempts and the gap between them, or the run
    is a nightly with no retry, and the retry inside the run is the whole reason
    the schedule is one line a day.
  - the missed-start bound plus the run deadline must fit inside the interval,
    or a run that starts late is still running when the next line is due,
    `concurrencyPolicy: Forbid` skips that line, and a skipped line is a day
    without a panel. Asserted by templates/nightly-cronjob.yaml, which owns the
    policy.
  - the ForecatsPanelNotDrawn threshold must clear a whole interval plus a whole
    run, because that is how long a healthy night is silent. Asserted by
    templates/nightly-alerts.yaml, which owns the threshold.
*/ -}}
{{- define "forecats.nightlyAttemptSeconds" -}}
{{- $cardWait := int (required "nightly.claimer.cardWaitSeconds: the card budget one attempt gets" .Values.nightly.claimer.cardWaitSeconds) -}}
{{- $window := int (required "claim.podClaimWindowSeconds: nix renders this from headEnd.podClaimWindowSeconds in the ai chart, because the router's wake deadline is summed from the same number" .Values.claim.podClaimWindowSeconds) -}}
{{- $render := int (required "nightly.render.activeDeadlineSeconds: the render pod's own deadline, and a term of one attempt because the run waits for the Job it created" .Values.nightly.render.activeDeadlineSeconds) -}}
{{- add $cardWait (add $window $render) -}}
{{- end -}}

{{- define "forecats.nightlyRunDeadlineSeconds" -}}
{{- $deadline := int (required "nightly.run.deadlineSeconds: the wall-clock bound on one run, inside which every attempt and every gap between them has to fit" .Values.nightly.run.deadlineSeconds) -}}
{{- $attempt := int (include "forecats.nightlyAttemptSeconds" .) -}}
{{- $gap := int (required "nightly.run.attemptGapSeconds: what the run waits after an attempt that got no card or drew nothing" .Values.nightly.run.attemptGapSeconds) -}}
{{- $twoAttempts := add (mul 2 $attempt) $gap -}}
{{- if lt $deadline $twoAttempts -}}
{{- fail (printf "nightly.run.deadlineSeconds is %d, and one attempt costs %d — the card wait, the pod-claim window and the render's deadline, added in templates/_helpers.tpl. Two attempts and the gap between them need %d, so this deadline admits one try and is therefore a nightly with no retry. The retry lives inside the run because the schedule is one line a day; raise the deadline or lower nightly.claimer.cardWaitSeconds." $deadline $attempt $twoAttempts) -}}
{{- end -}}
{{- $deadline -}}
{{- end -}}

{{- /*
The seconds between two lines of `nightly.schedule`, or a refusal.

The interval is what the alert threshold and the missed-start bound are measured
against, and a fifth number hand-written next to the schedule to state it is a
number nothing checks. Reading it back out of the schedule is only honest for the
shapes this chart can price: one fixed minute of one fixed hour, every day. A
schedule with a step, a list, a range or a day restriction has an interval this
helper does not compute, and the honest answer for it is a render that names the
file — the alternative is a threshold derived from a guess, which is the alert
that fires every morning, or never.
*/ -}}
{{- define "forecats.nightlyScheduleIntervalSeconds" -}}
{{- $schedule := trim (required "nightly.schedule" .Values.nightly.schedule) -}}
{{- $fields := regexFindAll "[^[:space:]]+" $schedule -1 -}}
{{- if ne (len $fields) 5 -}}
{{- fail (printf "nightly.schedule %q is not five whitespace-separated fields, so its interval cannot be read. The alert threshold that watches this schedule is derived from that interval; refusing the render is cheaper than deriving it from a guess." $schedule) -}}
{{- end -}}
{{- $minute := index $fields 0 -}}
{{- $hour := index $fields 1 -}}
{{- if or (not (regexMatch "^[0-9]+$" $minute)) (not (regexMatch "^[0-9]+$" $hour)) (ne (index $fields 2) "*") (ne (index $fields 3) "*") (ne (index $fields 4) "*") -}}
{{- fail (printf "nightly.schedule %q is not one fixed minute of one fixed hour every day. The interval between two lines is 86400 s only for that shape, and the run deadline, the missed-start bound and the ForecatsPanelNotDrawn threshold are all budgeted against a day. A schedule that runs more or less often means re-deriving those three in this helper's own file and in the two templates that call it — not editing the threshold." $schedule) -}}
{{- end -}}
{{- if or (gt (int $minute) 59) (gt (int $hour) 23) -}}
{{- fail (printf "nightly.schedule %q names a minute or an hour outside a day. The CronJob controller would reject the object and no line would ever run, which no alert below can tell from a namespace that was paused." $schedule) -}}
{{- end -}}
86400
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
The published names the viewer answers, or a refusal.

`viewer.published` is not this chart's to write. nix renders it from
`src/forecats-pipeline/forecats_pipeline/published-artefacts.json`, the same file
the publish step names its own writes with, and this helper renders both halves
of the viewer out of it: the whitelist `server.py` matches a request against, and
the two names `index.html` fetches before it knows a date. A path the page asks
for that the publish step does not write is therefore not a bug this chart can
introduce — it has no other source for a name — which is why there is no checker
for the agreement and a great deal of refusal here.

What is refused is what a name could otherwise be: a path (`../`, a slash), a
staging name (the publish step writes under a dot-prefixed sibling and renames,
so serving one would publish a half-written artefact), a variant with no date in
it (one file the next day overwrote), a fixed name with a date in it (the page
fetches it before it knows a date), two artefacts answering one path, or a
private name that walked into the served list. The last of those is the boundary
the tailnet-only decision rests on: the provenance sidecar carries the reference
photo paths, the weight paths and the report address, and it is served to nobody.
*/ -}}
{{- define "forecats.publishedArtefacts" -}}
{{- $published := required "viewer.published: set by services.k3s.appChartValues.forecats in nix/services/k3s.nix, which reads src/forecats-pipeline/forecats_pipeline/published-artefacts.json — the names the publish step writes and the names the page fetches are that one file, and a copy of it here is the drift this excludes" .Values.viewer.published -}}
{{- $items := list
      (dict "what" "viewer.published.manifest" "name" $published.manifest "dated" false)
      (dict "what" "viewer.published.freshness" "name" $published.freshness "dated" false)
      (dict "what" "viewer.published.prompt" "name" $published.prompt "dated" true) -}}
{{- range $variant, $name := (required "viewer.published.variants: the public variant names and the files each is written under, keyed by the name a page shows beside the picture; a variant added there is served, linked and rendered by this chart without an edit to it" $published.variants) -}}
{{- $items = append $items (dict "what" (printf "viewer.published.variants.%s" $variant) "name" $name "dated" true) -}}
{{- end -}}
{{- $served := list -}}
{{- $seen := dict -}}
{{- range $item := $items -}}
{{- $name := include "forecats.publishedArtefactName" $item -}}
{{- if hasKey $seen $name -}}
{{- fail (printf "%s is %q, which another published name already is; one request would answer two artefacts and one of them would be the one nobody meant" $item.what $name) -}}
{{- end -}}
{{- $_ := set $seen $name true -}}
{{- $served = append $served (dict "name" $name "pattern" (include "forecats.publishedArtefactPattern" $item) "contentType" (include "forecats.publishedArtefactType" $name)) -}}
{{- end -}}
{{- $private := required "viewer.published.private: the names the publish step writes and the viewer never serves — the provenance sidecar among them, which carries the reference photo paths, the weight paths and the report address" $published.private -}}
{{- $privateNames := list -}}
{{- range $entry := $private -}}
{{- $name := include "forecats.publishedArtefactName" (dict "what" "viewer.published.private" "name" $entry "dated" true) -}}
{{- if hasKey $seen $name -}}
{{- fail (printf "viewer.published.private names %q and the same name is in the served list; the private artefacts are the ones the panel's privacy argument says are not published, and a whitelist that answers one is not a boundary" $name) -}}
{{- end -}}
{{- $privateNames = append $privateNames $name -}}
{{- end -}}
{{- dict "manifest" $published.manifest "freshness" $published.freshness "variants" $published.variants "served" $served "private" $privateNames | toYaml -}}
{{- end -}}

{{- /*
One published name, checked for the shape a name has to keep for the server to be
able to serve it safely, and returned unchanged.
*/ -}}
{{- define "forecats.publishedArtefactName" -}}
{{- $name := required (printf "%s: the publish step writes no file under this name, so there is nothing for the page to fetch" .what) .name -}}
{{- if not (regexMatch "^[A-Za-z0-9._-]+$" (replace "{date}" "0" $name)) -}}
{{- fail (printf "%s is %q: a published name is letters, digits, dots, dashes and underscores around the one variable {date}. A name carrying a slash is a path, and this server resolves names inside the published directory and nothing else." .what $name) -}}
{{- end -}}
{{- if or (hasPrefix "." $name) (contains ".." $name) -}}
{{- fail (printf "%s is %q: a dot-prefixed name is the publish step's staging namespace, where a half-written artefact waits for a rename. The names the viewer serves are finished artefacts." .what $name) -}}
{{- end -}}
{{- if and .dated (not (contains "{date}" $name)) -}}
{{- fail (printf "%s is %q and carries no {date}: a published artefact named for no day is one file every nightly overwrites, and a gallery in which every date is the same picture." .what $name) -}}
{{- end -}}
{{- if and (not .dated) (contains "{date}" $name) -}}
{{- fail (printf "%s is %q and carries {date}: the page fetches this name before it knows a date, because it is the artefact that tells the page what dates there are." .what $name) -}}
{{- end -}}
{{- $name -}}
{{- end -}}

{{- /*
The name as the server matches it: anchored, escaped, and with the date left as
the one open variable. Escaped before the date is substituted, so the only
metacharacters in the result are the ones the date pattern brings with it — the
same order `artefact_pattern` in the publish step uses, because a whitelist that
matched something other than what the publish step wrote would be a whitelist
that serves a file no page links.
*/ -}}
{{- define "forecats.publishedArtefactPattern" -}}
{{- $name := include "forecats.publishedArtefactName" . -}}
{{- $pattern := replace "." "\\." $name -}}
{{- printf "\\A/%s\\Z" (replace "{date}" "[0-9]{4}-[0-9]{2}-[0-9]{2}" $pattern) -}}
{{- end -}}

{{- /*
The content type a published name is served as, from its suffix. A name with no
suffix the viewer knows is refused rather than guessed at: a panel served as
`text/plain` is a broken picture and a prompt served as `image/png` is a broken
prompt, and neither says what it was served as.
*/ -}}
{{- define "forecats.publishedArtefactType" -}}
{{- if hasSuffix ".png" . -}}
image/png
{{- else if hasSuffix ".json" . -}}
application/json
{{- else -}}
{{- fail (printf "%q is a published name with no suffix this viewer knows a content type for; the server answers a published name as the type its suffix names and nothing else" .) -}}
{{- end -}}
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

{{- /*
The ids every pod in this chart runs as, and the pod securityContext around them.

The uid is not this chart's to choose. The panels volume is a bind mount of a host
directory nix creates 0770 owned by `forecatsStorage.uid`, and a pod that is
neither that uid nor that group reaches it as "other", which has no bits: every
read of the mount answers EACCES, and no event, condition or log line says so. The
viewer keeps serving the page it mounts from its ConfigMap, so it is Ready through
a panel that cannot be read, and the nightly's dedup test answers "not published"
forever.

So the relationship is asserted here rather than trusted: every declared volume
must be reachable by the uid and group below, as its owner, as its group, or
because the declaration made it readable by everyone. The modes that declaration
produces give the group the owner's bits, so reaching a volume as its group is also
reaching it for writing. A volume declared under a third owner fails the render,
and the failure names the file that owns the id.
*/ -}}
{{- define "forecats.podSecurityContext" -}}
{{- $uid := int (required "pod.uid: set by forecatsStorage in nix/services/k3s.nix, which also owns the host directory the writable volume is a bind mount of" .Values.pod.uid) -}}
{{- $gid := int (required "pod.gid: set by forecatsStorage in nix/services/k3s.nix, which also owns the host directory the writable volume is a bind mount of" .Values.pod.gid) -}}
{{- range .Values.persistence.volumes -}}
{{- $ownerUid := int (required "persistence.volumes[].ownerUid is generated from forecatsStorage in nix/services/k3s.nix, beside the tmpfiles rule that creates the host directory with that owner" .ownerUid) -}}
{{- $ownerGid := int (required "persistence.volumes[].ownerGid is generated from forecatsStorage in nix/services/k3s.nix, beside the tmpfiles rule that creates the host directory with that group" .ownerGid) -}}
{{- if not (has .readableByAll (list true false)) -}}
{{- fail "persistence.volumes[].readableByAll is generated from the mode forecatsStorage's host directory is created with, and it is what lets a pod that is neither the owner nor the group read the volume. It is missing, so the render cannot tell whether the uid below reaches this volume." -}}
{{- end -}}
{{- $reaches := or (eq $uid $ownerUid) (or (eq $gid $ownerGid) .readableByAll) -}}
{{- if not $reaches -}}
{{- fail (printf "the pods of this chart run as uid %d group %d, and the volume %q is a bind mount of a host directory that is %s owned by %d:%d, which gives neither. A local PV passes the host's modes into the pod unchanged, so every read of the mount answers EACCES with nothing on any object to say so. Move the uid in forecatsStorage in nix/services/k3s.nix, or the mode the same declaration creates the host directory with." $uid $gid .name (default "?" .mode) $ownerUid $ownerGid) -}}
{{- end -}}
{{- end -}}
runAsUser: {{ $uid }}
runAsGroup: {{ $gid }}
runAsNonRoot: true
seccompProfile:
  type: RuntimeDefault
{{- end -}}
