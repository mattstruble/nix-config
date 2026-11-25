package main

import (
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// The head end's deployment shape, asserted against a render rather than
// asserted about.
//
// llama-swap's --watch-config reload stops every loaded model: the reload builds
// a new server and shuts the old one down, and that shutdown runs each loaded
// model's cmdStop (read at the pinned revision v264 / a025e03: llama-swap.go
// reload -> server.Server.Shutdown -> baseRouter.handleShutdown ->
// ProcessCommand.Stop -> killProcess -> sendStopSignal). The container is not
// restarted, so the pod stays Ready: a roster edit that lands in place sleeps
// the fleet under live requests and reports nothing in the one place anyone is
// watching.
//
// The chart answers by making a head-end ConfigMap edit a pod rollout. These
// tests render the chart and fail if that stops being true. They shell out to
// helm, and skip when it is not on PATH - the nix build of this package runs
// this binary with no helm in the sandbox.

// headEndChart is the chart whose head-end Deployment decides how a roster edit
// reaches a running router.
var headEndChart = filepath.Join("..", "..", "k8s", "apps", "ai")

const checksumKey = "checksum/config:"

// renderHeadEnd renders only the head-end Deployment, the way the nix render
// does: every values/<model>.yaml the chart carries, plus the two store paths
// the nix render injects and the head-end templates gate on. overrides go last,
// so a test can change exactly one value.
func renderHeadEnd(t *testing.T, overrides ...string) string {
	t.Helper()
	helmBin, err := exec.LookPath("helm")
	if err != nil {
		t.Skip("helm is not on PATH; these assertions are about a rendered manifest")
	}
	values, err := filepath.Glob(filepath.Join(headEndChart, "values", "*.yaml"))
	if err != nil || len(values) == 0 {
		t.Fatalf("no model values files under %s: %v", headEndChart, err)
	}
	args := []string{"template", "ai", headEndChart,
		"--show-only", "templates/head-end-deployment.yaml",
		"--set", "global.hostDataRoot=/tmp",
		"--set", "headEnd.bundle=/nix/store/00000000000000000000000000-swap-head-end",
		"--set", "strataBundle=/nix/store/00000000000000000000000000-strata",
	}
	for _, v := range values {
		args = append(args, "-f", v)
	}
	args = append(args, overrides...)
	out, err := exec.Command(helmBin, args...).CombinedOutput()
	if err != nil {
		t.Fatalf("helm template %s: %v\n%s", strings.Join(args, " "), err, out)
	}
	return string(out)
}

// podChecksum returns the head-end Pod template's checksum over its ConfigMap.
func podChecksum(t *testing.T, rendered string) string {
	t.Helper()
	if n := strings.Count(rendered, checksumKey); n != 1 {
		t.Fatalf("the head-end render carries %d %s annotations, want exactly 1", n, checksumKey)
	}
	re := regexp.MustCompile(`(?m)^[ \t]*` + regexp.QuoteMeta(checksumKey) + `[ \t]*([0-9a-f]{64})[ \t]*$`)
	m := re.FindStringSubmatch(rendered)
	if m == nil {
		t.Fatalf("no 64-hex %s value in the head-end render:\n%s", checksumKey, rendered)
	}
	return m[1]
}

// withoutComments drops whole-line YAML comments, which helm passes through from
// the templates: what the pod runs is in the fields, not the prose beside them.
func withoutComments(rendered string) string {
	kept := []string{}
	for _, line := range strings.Split(rendered, "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), "#") {
			continue
		}
		kept = append(kept, line)
	}
	return strings.Join(kept, "\n")
}

// withoutChecksum is the render as it would have been before the roster was
// summed - what is left of the Pod template once the checksum is discounted.
func withoutChecksum(rendered string) string {
	re := regexp.MustCompile(`(?m)^[ \t]*` + regexp.QuoteMeta(checksumKey) + `[ \t]*[0-9a-f]{64}[ \t]*\n`)
	return re.ReplaceAllString(rendered, "")
}

// TestHeadEndRunsNoConfigWatcher: an in-place reload is the failure this file is
// about, so the flag that turns it on must not reach the container.
func TestHeadEndRunsNoConfigWatcher(t *testing.T) {
	rendered := withoutComments(renderHeadEnd(t))

	if strings.Contains(rendered, "--watch-config") {
		t.Error("the head-end container runs llama-swap with --watch-config: a head-end " +
			"ConfigMap edit then reloads in place, which runs cmdStop for every loaded " +
			"model while the pod stays Ready. The roster reaches the router through a " +
			"rollout, which is what the checksum/config annotation is for.")
	}
	if !strings.Contains(rendered, "--config /etc/llama-swap/config.yaml") {
		t.Error("the head-end container no longer runs llama-swap against the rendered " +
			"config, so the assertion above is passing about some other process")
	}
}

// TestHeadEndConfigChecksumIsInThePodTemplate: an annotation on the Deployment's
// own metadata rolls nothing, and every other assertion here would still pass.
func TestHeadEndConfigChecksumIsInThePodTemplate(t *testing.T) {
	rendered := renderHeadEnd(t)

	podChecksum(t, rendered)
	templateAt, checksumAt := strings.Index(rendered, "\n  template:\n"), strings.Index(rendered, checksumKey)
	if templateAt < 0 {
		t.Fatalf("the head-end render has no Pod template:\n%s", rendered)
	}
	if checksumAt < templateAt {
		t.Error("checksum/config sits above spec.template, where Kubernetes ignores it: " +
			"only a change inside the Pod template rolls the pods")
	}
}

// TestHeadEndConfigOnlyEditRollsThePod is the finding: editing the roster has to
// change the head-end Pod template, and change nothing else in it, so that the
// only thing a roster edit does to a running head end is schedule a rollout.
func TestHeadEndConfigOnlyEditRollsThePod(t *testing.T) {
	// headEnd.ttlSeconds is the idle budget written into config.yaml for every
	// model that sets no ttl of its own, and the head-end Deployment reads
	// nothing from it - so it moves the roster and nothing else.
	const rosterEdit = "headEnd.ttlSeconds=1234"

	before := renderHeadEnd(t)
	after := renderHeadEnd(t, "--set", rosterEdit)

	if oldSum, newSum := podChecksum(t, before), podChecksum(t, after); oldSum == newSum {
		t.Errorf("editing %s left %s at %s: a roster edit changes no Pod template, so it "+
			"lands in place on a running head end and stops every loaded model "+
			"mid-request", rosterEdit, checksumKey, oldSum)
	}
	if a, b := withoutChecksum(before), withoutChecksum(after); a != b {
		t.Errorf("editing %s changed the head-end Deployment beyond %s, so the rollout is "+
			"not carried by the checksum alone:\n--- before ---\n%s\n--- after ---\n%s",
			rosterEdit, checksumKey, a, b)
	}
}
