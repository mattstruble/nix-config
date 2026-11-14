#!/usr/bin/env bash
#
# Fail when a chart under k8s/apps/ is wired into only part of the path its
# manifests travel down: the nix render derivations, the CI render step, and
# Renovate's managerFilePatterns.
#
#   ./scripts/check-app-wiring.sh
#
# `just k8s-render` discovers a chart by finding a Chart.yaml, so a new app
# renders locally the moment its directory lands and looks finished, while the
# nix render, the PR preview and update automation — which each name their apps
# by hand — go on ignoring it. None of the three misses is visible on the PR that
# adds the app, and one of them is not visible until a deploy.
#
# This replaced the three-file half of the checklist in k8s/README.md: a checklist
# restates the live state of three other files and is wrong the first time any of
# them is refactored. This asks each of them, at the time it matters, whether the
# code that does the work names the app's chart directory.
#
# A green run claims these three places only, and is not "the app is wired": still
# hand-wired, and still silent when missing, are `system.build.<app>ChartRendered`
# (without it the render never reaches the system closure), the
# `sops.secrets."services/<app>/*"` declarations with their `.sops.yaml` path rule,
# the apply oneshot that creates the Secret the chart references and must not
# define, `services.k3s.manifests.<app>-pvs`, and the per-app lists in
# renovate-config-check.yml and chart-image-digests.yml.
set -euo pipefail

# `CDPATH= cd` is a prefix assignment, not an empty one: CDPATH must not redirect this.
# shellcheck disable=SC1007
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

nix_file=nix/services/k3s.nix
diff_file=.github/workflows/k8s-manifest-diff.yml
renovate_file=renovate.json

for f in "$nix_file" "$diff_file" "$renovate_file"; do
  [ -f "$f" ] || {
    echo "::error::$f is missing, so every app would read as unwired and the run would report a problem that is not in the tree" >&2
    exit 1
  }
done

# Each place is reduced to the text that does the work before it is asked about an
# app, because a mention elsewhere in the same file is not a wire: the k3s
# activation script echoes paths under k8s/apps/ into operator messages, and two
# steps of the manifest-diff workflow read app files without rendering them.

# The shell scripts of the nix render derivations: the body of every '' string
# literal opened by pkgs.runCommand, written to the file named by $1, with
# "<bodies opened> <pkgs.runCommand in code> <bodies left unterminated> <openers that
# belonged to another binding>" on stdout. The caller stops the run unless every call
# it counted yielded a body that closed and nothing was left over: a haystack that
# silently lost a body reports the app wired inside it as MISSING.
#
# Two facts about nix set the boundaries this follows. Inside an indented string the
# delimiter ends the string only when the next character is none of dollar, backtick
# or quote, so a body line that begins ''${FOO} — the way a body writes a literal
# ${FOO} — is text and not a delimiter. And the delimiter that opens a body may sit
# at the end of the closing brace line rather than alone on its own line, which is
# why an opener has to be attributed to the call that armed it and not merely counted.
render_derivations() {
  awk -v q="''" -v out="$1" '
    BEGIN {
      esc = sprintf("%c%c%c", 36, 96, 39)  # dollar, backtick, quote
      binding = sprintf("^[A-Za-z_][A-Za-z0-9_%c%c_.-]*[[:space:]]*=", 39, 34)  # quote, double quote
    }
    # A comment, or a line of a script already being read, is nix being talked about
    # rather than nix calling the function: counting it would make a sentence in a
    # comment look like a script this failed to read.
    !open {
      code = $0
      sub(/^[[:space:]]*/, "", code)
      if (code ~ /^#/) { next }
      sub(/#.*/, "", code)
      if ((n = gsub(/pkgs\.runCommand/, "@", code)) > 0) { want += n; der = 1 }
    }
    der {
      t = $0; sub(/^[[:space:]]*/, "", t)
      if (open) {
        c3 = substr(t, 3, 1)
        if (substr(t, 1, 2) == q && (c3 == "" || index(esc, c3) == 0)) { open = 0; der = 0; next }
        print > out
        next
      }
      if (length(t) >= 2 && substr(t, length(t) - 1) == q) {
        # A line that opens a binding of its own is some other definition, not the
        # script of the armed call: the call was missed, and reading on would hand
        # that unrelated string to whichever app is asked about next.
        if (t ~ binding) { unbound++; der = 0 } else { open = 1; opened++ }
      }
    }
    END { printf "%d %d %d %d\n", opened + 0, want + 0, open + 0, unbound + 0 }
  ' "$nix_file"
}

# The script of the workflow step that defines render(): the block scalar under
# its `run:` key, which also holds wiki_render() that render() ends with.
render_step() {
  awk '
    function flush() { if (index(buf, "render() {") > 0) emit = emit buf; buf = "" }
    /^[[:space:]]*run:[[:space:]]*[|>][-+]?[[:space:]]*$/ {
      if (inblock) flush()
      col = index($0, "run:"); inblock = 1; next
    }
    inblock {
      if ($0 ~ /^[[:space:]]*$/) { buf = buf "\n"; next }
      if (match($0, /[^[:space:]]/) > col) { buf = buf $0 "\n"; next }
      inblock = 0; flush()
    }
    END { if (inblock) flush(); printf "%s", emit }
  ' "$diff_file"
}

# The file list Renovate's regex managers actually read. Only managerFilePatterns
# counts: packageRules also names files, and a file that appears only there is
# grouped and automerged by rules that never see anything extracted from it.
manager_patterns() {
  awk '
    !inblock && /"managerFilePatterns"[[:space:]]*:[[:space:]]*\[/ { inblock = 1; sub(/^.*\[/, "") }
    inblock {
      line = $0
      if ((p = index(line, "]")) > 0) { inblock = 0; line = substr(line, 1, p - 1) }
      while (match(line, /"[^"]*"/)) {
        print substr(line, RSTART + 1, RLENGTH - 2)
        line = substr(line, RLENGTH + 1)
      }
    }
  ' "$renovate_file"
}

hay_nix=$(mktemp)
hay_preview=$(mktemp)
hay_renovate=$(mktemp)
trap 'rm -f "$hay_nix" "$hay_preview" "$hay_renovate"' EXIT
nix_counts=$(render_derivations "$hay_nix")
read -r nix_bodies nix_run_commands nix_unterminated nix_unbound <<<"$nix_counts"
{ [ "$nix_bodies" = "$nix_run_commands" ] && [ "$nix_unterminated" = 0 ] && [ "$nix_unbound" = 0 ]; } || {
  echo "::error::$nix_file could not be read: $nix_bodies of its $nix_run_commands pkgs.runCommand scripts were opened ($nix_unterminated unterminated, $nix_unbound followed by another binding); the nix half of this check would report an app wired inside a script it never read as MISSING" >&2
  exit 1
}
[ -s "$hay_nix" ] || {
  echo "::error::no pkgs.runCommand script could be read from $nix_file; the nix half of this check would neither pass anything nor fail anything" >&2
  exit 1
}
render_step >"$hay_preview"
[ -s "$hay_preview" ] || {
  echo "::error::no step defining render() could be read from $diff_file; the preview half of this check would neither pass anything nor fail anything" >&2
  exit 1
}
manager_patterns >"$hay_renovate"
[ -s "$hay_renovate" ] || {
  echo "::error::no managerFilePatterns could be read from $renovate_file; the Renovate half of this check would neither pass anything nor fail anything" >&2
  exit 1
}

# Does the place's own text name apps/<app>? Comment lines never count — prose
# about an app is the thing this check replaced. A neighbour that continues the
# name never counts either, so `apps/probee` is not a wire to probe: a wire with a
# typo in it is the defect this exists to catch.
#
# `dir` mode additionally rejects a neighbour `/`, so the app directory itself has
# to be named — a render that reads apps/wiki/values.yaml while pointing its chart
# at apps/wikii is not a render of wiki. `under` mode accepts anything beneath the
# directory, because Renovate is handed values files and never the chart directory.
# Neither mode judges whether the render is well formed: a step that still names
# the directory and lost its `helm template` line reads ok, because naming the
# chart directory is the whole of what a text-only check can claim.
named() {
  awk -v app="$2" -v mode="$3" '
    /^[[:space:]]*#/ { next }
    {
      line = $0
      while ((p = index(line, "apps/" app)) > 0) {
        line = substr(line, p + 5 + length(app))
        c = substr(line, 1, 1)
        if (c ~ /[A-Za-z0-9_-]/) { continue }
        if (c == "/") {
          if (mode == "under") { found = 1; exit }
          continue
        }
        found = 1; exit
      }
    }
    END { exit found ? 0 : 1 }
  ' "$1"
}

apps=()
for d in k8s/apps/*/; do
  [ -f "${d}Chart.yaml" ] || continue
  a=${d%/}
  apps+=("${a##*/}")
done
[ "${#apps[@]}" -gt 0 ] || {
  echo "::error::no directory under k8s/apps/ carries a Chart.yaml; this check would report success for any app, which is not a pass" >&2
  exit 1
}

# text to ask | what the place fails to do, read after "app 'X' has a Chart.yaml but" |
# what breaks when it is silent | match mode
places=(
  "$hay_nix|no pkgs.runCommand script in $nix_file names its chart directory|nothing builds the chart, so it never reaches the system closure and nothing applies it; the failure lands on the cluster at switch time|dir"
  "$hay_preview|the render step of $diff_file does not name its chart directory|the PR preview renders without it, so the manifest diff reviewers approve is missing the new app|dir"
  "$hay_renovate|no managerFilePatterns entry in $renovate_file reaches its files|its image pins are never extracted, so nothing bumps them and no PR is ever filed for them|under"
)

status=0
unwired=
report=
printf '%-14s %-10s %-10s %s\n' app "nix render" preview renovate
for a in "${apps[@]}"; do
  row=("$a")
  for place in "${places[@]}"; do
    IFS='|' read -r haystack clause consequence mode <<<"$place"
    if named "$haystack" "$a" "$mode"; then
      row+=(ok)
    else
      row+=(MISSING)
      report="${report}::error::app '$a' has k8s/apps/$a/Chart.yaml but $clause — $consequence
"
      status=1
    fi
  done
  printf '%-14s %-10s %-10s %s\n' "${row[@]}"
  case " ${row[*]} " in
    *MISSING*) unwired="$unwired $a" ;;
  esac
done

if [ "$status" -ne 0 ]; then
  printf '%s' "$report"
  echo "wire$unwired into every place marked MISSING above, or drop the chart: an app chart nothing points at is not an app that is merely not deployed yet"
  exit $status
fi

# A green run is what an operator reads as "wired", so the success line names what
# it did not check; the points themselves are listed under "Adding an app".
echo "every app chart under k8s/apps/ is named by a nix render derivation, the PR preview render and renovate"
echo "those three places only: the sops secrets, the apply oneshot, the system.build and PV entries, and the per-app workflow lists are unchecked (k8s/README.md)"
