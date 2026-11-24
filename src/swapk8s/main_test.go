package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// The invariant that keeps `kubectl apply` from killing a serving model: the
// update body must never carry .spec.replicas, because the shim owns that field
// and the chart re-applies on every activation.
func TestNormalizeSpecKeepsReplicasOutOfTheUpdate(t *testing.T) {
	in := []byte(`{
	  "apiVersion":"apps/v1","kind":"Deployment",
	  "metadata":{"name":"swift-qwen3-8-27b-g0","namespace":"default",
	    "resourceVersion":"1234","uid":"dead","creationTimestamp":"2026-01-01T00:00:00Z",
	    "labels":{"app":"ai","ai.mestruble.dev/gpu-pool":"0,1","ai.mestruble.dev/gpu-mode":"any"}},
	  "spec":{"replicas":7,"template":{"spec":{"containers":[{"name":"llama-server",
	    "env":[{"name":"NVIDIA_VISIBLE_DEVICES","value":"0,1"}]}]}}},
	  "status":{"readyReplicas":1}
	}`)
	_, patch, err := normalizeSpec("default", "swift-qwen3-8-27b-g0", "1", in)
	if err != nil {
		t.Fatalf("normalizeSpec: %v", err)
	}

	var patchObj map[string]any
	if err := json.Unmarshal(patch, &patchObj); err != nil {
		t.Fatal(err)
	}
	if spec, _ := patchObj["spec"].(map[string]any); spec["replicas"] != nil {
		t.Errorf("update body carries replicas: %v", spec["replicas"])
	}
	if patchObj["status"] != nil {
		t.Error("update body carries status")
	}
	if meta, _ := patchObj["metadata"].(map[string]any); meta["resourceVersion"] != nil || meta["uid"] != nil {
		t.Error("update body carries server-set fields")
	}
	meta, _ := patchObj["metadata"].(map[string]any)
	labels, _ := meta["labels"].(map[string]any)
	if labels[managedLabel] != managedBy || labels[modelLabel] != "swift-qwen3-8-27b-g0" {
		t.Errorf("ownership labels not injected: %v", labels)
	}
	if labels["app"] != "ai" {
		t.Error("chart labels were dropped")
	}
	// the transport labels must be consumed, not applied: "0,1" is an invalid
	// label value (commas are rejected), so carrying them is a 422
	if _, ok := labels[gpuPoolLabel]; ok {
		t.Errorf("pool label reached the API: %v", labels[gpuPoolLabel])
	}
	if _, ok := labels[gpuModeLabel]; ok {
		t.Errorf("mode label reached the API: %v", labels[gpuModeLabel])
	}
	// placement: the pool in the spec must be narrowed to the chosen card, in
	// BOTH bodies - a pod created with "0,1" for a one-card model takes both
	// cards while claiming one.
	for i, body := range [][]byte{patch, mustCreateBody(t, "default", "swift-qwen3-8-27b-g0", "1", in)} {
		var obj map[string]any
		if err := json.Unmarshal(body, &obj); err != nil {
			t.Fatal(err)
		}
		env := envOf(obj)
		if got := env[gpuEnv]; got != "1" {
			t.Errorf("body %d: %s = %q, want the chosen card 1", i, gpuEnv, got)
		}
		if i == 0 { // the patch body: replicas must be absent, not resized
			if spec, _ := obj["spec"].(map[string]any); spec["replicas"] != nil {
				t.Errorf("update body carries replicas: %v", spec["replicas"])
			}
		} else { // the create body: it must start the model
			if spec, _ := obj["spec"].(map[string]any); spec["replicas"] != float64(1) {
				t.Errorf("create body should start the model at 1, got %v", spec["replicas"])
			}
			// and still be a whole object, or POST rejects it
			if obj["apiVersion"] != "apps/v1" || obj["kind"] != "Deployment" {
				t.Error("create body lost apiVersion/kind")
			}
		}
	}
}

func envOf(obj map[string]any) map[string]string {
	out := map[string]string{}
	// map[string]any has no dig; walk it explicitly
	spec, _ := obj["spec"].(map[string]any)
	tmpl, _ := spec["template"].(map[string]any)
	pspec, _ := tmpl["spec"].(map[string]any)
	cs, _ := pspec["containers"].([]any)
	if len(cs) == 0 {
		return out
	}
	c0, _ := cs[0].(map[string]any)
	env, _ := c0["env"].([]any)
	for _, e := range env {
		em, ok := e.(map[string]any)
		if !ok {
			continue
		}
		n, _ := em["name"].(string)
		v, _ := em["value"].(string)
		out[n] = v
	}
	return out
}

func mustCreateBody(t *testing.T, ns, name, gpu string, in []byte) []byte {
	t.Helper()
	create, _, err := normalizeSpec(ns, name, gpu, in)
	if err != nil {
		t.Fatalf("normalizeSpec create: %v", err)
	}
	return create
}

// A spec mounted under the wrong name would put one model in another model's
// place, which is the kind of failure that looks like a haunted cluster.
func TestNormalizeSpecRefusesNameMismatch(t *testing.T) {
	in := []byte(`{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"gemma-4-26b-g0"},"spec":{"template":{}}}`)
	_, _, err := normalizeSpec("default", "swift-qwen3-8-27b-g0", "1", in)
	if err == nil || !strings.Contains(err.Error(), "is mounted for") {
		t.Fatalf("want a mount-mismatch refusal, got %v", err)
	}
}

func TestNormalizeSpecRejectsGarbage(t *testing.T) {
	for _, bad := range []string{"", "not json", `{"metadata":{}}`, `{"metadata":{"name":"m"}}`} {
		if _, _, err := normalizeSpec("default", "m", "1", []byte(bad)); err == nil {
			t.Errorf("expected an error for %q", bad)
		}
	}
}

// A spec whose pool never got narrowed must be refused: a pod created with the
// pool pinned takes every card in it while claiming one.
func TestNormalizeSpecRefusesUnresolvedPlacement(t *testing.T) {
	in := []byte(`{"apiVersion":"apps/v1","kind":"Deployment",
	  "metadata":{"name":"m","labels":{}},
	  "spec":{"template":{"spec":{"containers":[{"name":"m","env":[{"name":"NVIDIA_VISIBLE_DEVICES","value":"0,1"}]}]}}}}`)
	if _, _, err := normalizeSpec("default", "m", "", in); err == nil {
		t.Fatal("empty placement must be refused, not created with the pool")
	}
}

// And a spec with no NVIDIA_VISIBLE_DEVICES at all is refused rather than
// scheduled onto whatever the runtime's default visibility is.
func TestNormalizeSpecRefusesSpecWithoutCardEnv(t *testing.T) {
	in := []byte(`{"apiVersion":"apps/v1","kind":"Deployment",
	  "metadata":{"name":"m","labels":{}},
	  "spec":{"template":{"spec":{"containers":[{"name":"m","env":[]}]}}}}`)
	if _, _, err := normalizeSpec("default", "m", "1", in); err == nil {
		t.Fatal("a spec without the card env must be refused")
	}
}

// The busy-card rules: existence claims (not readiness), only a card-owning
// component claims at all, terminating and finished pods release, spanning pods
// claim every card in their pool, empty values claim nothing. Every one of these
// rules exists because its opposite crashloops a pod onto a busy card, or holds
// a card for a pod that will never run again.
func TestCardsFromPods(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want []string
	}{
		{"a running model pod claims its card", pods(model(sref("1"))), []string{"1"}},
		{"a terminating model pod releases its card", pods(podSpec{component: componentModel, env: sref("1"), deleting: true}), []string{}},
		{"a spanning model pod claims every card in its pool", pods(model(sref("0,1"))), []string{"0", "1"}},
		{"an empty value claims nothing", pods(model(sref(""))), []string{}},
		{"two pods claim their own cards", pods(model(sref("0")), model(sref("1"))), []string{"0", "1"}},
		{"a finished model pod releases its card", pods(podSpec{component: componentModel, env: sref("1"), phase: "Failed"}), []string{}},

		// A pod that owns no card is invisible to placement: the head-end pod and
		// every log pod share the namespace with the models.
		{"a pod of another component claims nothing", pods(podSpec{component: "head-end", env: sref("0")}), []string{}},
		{"a pod with no component label claims nothing", pods(podSpec{env: sref("0")}), []string{}},

		// gpu-job: a pod that holds a card and is not a model. It carries only
		// component=gpu-job, which is the point of the category — component=model
		// is what puts a pod in the llama-swap roster, the model dashboards and the
		// ai_model_* metrics.
		{"a gpu-job pod claims its card without being a model", pods(gpuJob(sref("1"))), []string{"1"}},
		{"a gpu-job pod claims every card in its pool", pods(gpuJob(sref("0,1"))), []string{"0", "1"}},
		{"a gpu-job pod that declares only the pool label claims it", pods(podSpec{component: componentGpuJob, pool: "0,1"}), []string{"0", "1"}},
		{"a gpu-job pod narrowed to one card is not charged for its pool", pods(podSpec{component: componentGpuJob, pool: "0,1", env: sref("1")}), []string{"1"}},
		{"a terminating gpu-job pod releases its card", pods(podSpec{component: componentGpuJob, env: sref("1"), deleting: true}), []string{}},
		{"a failed gpu-job pod releases its card", pods(podSpec{component: componentGpuJob, env: sref("1"), phase: "Failed"}), []string{}},
		{"a succeeded gpu-job pod releases its card", pods(podSpec{component: componentGpuJob, env: sref("1"), phase: "Succeeded"}), []string{}},
		// Unknown is a node that stopped reporting, not a pod that finished; the
		// container there may still hold its card.
		{"a gpu-job pod on a silent node keeps its card", pods(podSpec{component: componentGpuJob, env: sref("1"), phase: "Unknown"}), []string{"1"}},
		{"a gpu-job and a model claim their own cards", pods(gpuJob(sref("0")), model(sref("1"))), []string{"0", "1"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := cardsFromPods([]byte(tc.in))
			if err != nil {
				t.Fatal(err)
			}
			if len(got) != len(tc.want) {
				t.Fatalf("busy = %v, want %v", got, tc.want)
			}
			for _, c := range tc.want {
				if !got[c] {
					t.Errorf("card %s not busy in %v", c, got)
				}
			}
		})
	}
}

// podSpec builds a pod for the scan tests; every field left zero is a field the
// API did not send, so a case states only what its scenario is about.
type podSpec struct {
	component string  // app.kubernetes.io/component
	pool      string  // ai.mestruble.dev/gpu-pool label
	env       *string // NVIDIA_VISIBLE_DEVICES; nil omits the variable entirely
	phase     string  // status.phase; "" omits the field, which is a pod that has not finished
	deleting  bool
}

func model(gpu *string) podSpec  { return podSpec{component: componentModel, env: gpu} }
func gpuJob(gpu *string) podSpec { return podSpec{component: componentGpuJob, env: gpu} }

func sref(s string) *string { return &s }

// json renders the pod as the API returns it, so the rules are tested against
// the JSON a cluster sends rather than against a struct the test invented.
func (s podSpec) json() string {
	var labels []string
	if s.component != "" {
		labels = append(labels, fmt.Sprintf("%q:%q", componentLabel, s.component))
	}
	if s.pool != "" {
		labels = append(labels, fmt.Sprintf("%q:%q", gpuPoolLabel, s.pool))
	}
	dt := "null"
	if s.deleting {
		dt = `"2026-10-12T00:00:00Z"`
	}
	env := ""
	if s.env != nil {
		env = fmt.Sprintf(`"env":[{"name":%q,"value":%q}]`, gpuEnv, *s.env)
	}
	phase := ""
	if s.phase != "" {
		phase = fmt.Sprintf(`"phase":%q`, s.phase)
	}
	return fmt.Sprintf(`{"metadata":{"name":"p","labels":{%s},"deletionTimestamp":%s},`+
		`"spec":{"containers":[{%s}]},"status":{%s}}`, strings.Join(labels, ","), dt, env, phase)
}

func pods(specs ...podSpec) string {
	items := make([]string, 0, len(specs))
	for _, s := range specs {
		items = append(items, s.json())
	}
	return `{"items":[` + strings.Join(items, ",") + `]}`
}

// A card held by a gpu-job refuses a wake exactly as a card held by a model
// does: chooseCard reads the busy set and cannot tell which kind of pod put the
// card in it. Both busy sets below come from cardsFromPods, so the chain from
// scan to decision is covered without a cluster; wake() wraps the decision in
// the flock and the card-wait loop, so a refusal here is a wait there.
func TestChooseCardRefusesCardsHeldByGpuJobs(t *testing.T) {
	busy := func(spec podSpec) map[string]bool {
		t.Helper()
		got, err := cardsFromPods([]byte(pods(spec)))
		if err != nil {
			t.Fatalf("cardsFromPods: %v", err)
		}
		return got
	}
	heldByJob, heldByModel := busy(gpuJob(sref("1"))), busy(model(sref("1")))

	cases := []struct {
		name  string
		busy  map[string]bool
		cards []string
		pool  string
		mode  string
		want  string
	}{
		{"a one-card pool held by a gpu-job is refused", heldByJob, []string{"1"}, "1", "any", ""},
		{"a one-card pool held by a model is refused", heldByModel, []string{"1"}, "1", "any", ""},
		{"an any-mode wake takes the free card of its pool", heldByJob, []string{"0", "1"}, "0,1", "any", "0"},
		{"a spanning wake is refused when a gpu-job holds one of its cards", heldByJob, []string{"0", "1"}, "0,1", "all", ""},
		{"a spanning wake takes its pool when a gpu-job holds another card",
			busy(gpuJob(sref("2"))), []string{"0", "1"}, "0,1", "all", "0,1"},
		{"an unheld card is free", busy(gpuJob(sref("2"))), []string{"1"}, "1", "any", "1"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := chooseCard(tc.busy, tc.cards, tc.pool, tc.mode); got != tc.want {
				t.Errorf("chooseCard = %q, want %q", got, tc.want)
			}
		})
	}
}

// ---- claiming a card for a job ---------------------------------------------

// scanOf is the cluster placement reads: the same cardsFromPods the shim runs
// against a pod list, so a claim test covers the chain from "a pod holds this
// card" to "the job is refused it" without an API server.
func scanOf(specs ...podSpec) busyScan {
	raw := []byte(pods(specs...))
	return func(context.Context) (map[string]bool, error) { return cardsFromPods(raw) }
}

// refusalBudget is a card-wait short enough that a refusal is a test result and
// not a wait; the cycle is the same one a five-minute wake runs.
const refusalBudget = 50 * time.Millisecond

func claimJob(t *testing.T, lockPath string, scan busyScan, pool, mode string, onClaim func(string) error) (string, error) {
	t.Helper()
	return claimCycle(context.Background(), lockPath, scan, splitCards(pool), pool, mode,
		refusalBudget, time.Millisecond, onClaim)
}

// A job asks for a card and is told which one it got. The busy set below is a
// model holding card 1, so the job lands on 0 of its pool and is never handed
// the card the model is serving on.
func TestClaimCycleHandsTheJobAFreeCard(t *testing.T) {
	claimed := ""
	card, err := claimJob(t, t.TempDir()+"/cards.lock", scanOf(model(sref("1"))), "0,1", "any",
		func(c string) error { claimed = c; return nil })
	if err != nil {
		t.Fatalf("claim: %v", err)
	}
	if card != "0" || claimed != "0" {
		t.Errorf("claim = %q, the command was told %q; want the free card 0 in both", card, claimed)
	}
}

// A card a model serves on is refused, not shared: the refusal is the whole
// reason a job goes through the shim instead of naming a card in its own
// manifest, and the command must never see a card the cycle refused.
func TestClaimCycleRefusesACardAModelHolds(t *testing.T) {
	claimed := ""
	_, err := claimJob(t, t.TempDir()+"/cards.lock", scanOf(model(sref("1"))), "1", "any",
		func(c string) error { claimed = c; return nil })
	if err == nil || !strings.Contains(err.Error(), `no free card in pool "1"`) {
		t.Fatalf("want a refusal naming the pool, got %v", err)
	}
	if claimed != "" {
		t.Errorf("the command was handed a refused card: %q", claimed)
	}
}

// A card another gpu-job holds is refused exactly the same way: the two
// categories differ in who created them, not in what they block.
func TestClaimCycleRefusesACardAnotherJobHolds(t *testing.T) {
	claimed := ""
	_, err := claimJob(t, t.TempDir()+"/cards.lock", scanOf(gpuJob(sref("1"))), "1", "any",
		func(c string) error { claimed = c; return nil })
	if err == nil {
		t.Fatal("a card another job holds must be refused")
	}
	if claimed != "" {
		t.Errorf("the command was handed a refused card: %q", claimed)
	}
}

// A spanning job is refused unless every card of its pool is free, whoever holds
// one of them.
func TestClaimCycleRefusesASpanningJobWhenAModelHoldsOneOfItsCards(t *testing.T) {
	_, err := claimJob(t, t.TempDir()+"/cards.lock", scanOf(model(sref("1"))), "0,1", "all",
		func(string) error { t.Error("a spanning claim must not be handed a partial pool"); return nil })
	if err == nil {
		t.Fatal("a spanning job must be refused a pool one of whose cards is held")
	}
}

// A job that finished releases its card, and the claim is what proves the
// release means something: the nightly that failed last night must not be the
// reason tonight's render waits five minutes and gives up.
func TestClaimCycleClaimsTheCardAFailedJobReleased(t *testing.T) {
	card, err := claimJob(t, t.TempDir()+"/cards.lock",
		scanOf(podSpec{component: componentGpuJob, env: sref("1"), phase: "Failed"}), "1", "any",
		func(string) error { return nil })
	if err != nil {
		t.Fatalf("a failed job holds nothing: %v", err)
	}
	if card != "1" {
		t.Errorf("claim = %q, want the card the failed job released", card)
	}
}

// A busy card is a temporary condition: the job waits under the flock for the
// holder to finish rather than failing on the first scan, which is the same
// bargain a model wake makes.
func TestClaimCycleWaitsForAHeldCardToRelease(t *testing.T) {
	rounds := 0
	scan := func(ctx context.Context) (map[string]bool, error) {
		rounds++
		if rounds < 3 {
			return cardsFromPods([]byte(pods(gpuJob(sref("1")))))
		}
		return cardsFromPods([]byte(pods()))
	}
	card, err := claimCycle(context.Background(), t.TempDir()+"/cards.lock", scan, []string{"1"}, "1", "any",
		5*time.Second, time.Millisecond, func(string) error { return nil })
	if err != nil {
		t.Fatalf("claim: %v", err)
	}
	if rounds < 3 {
		t.Errorf("the cycle claimed after %d scan(s) of a held card", rounds)
	}
	if card != "1" {
		t.Errorf("claim = %q, want the card once it released", card)
	}
}

// The flock is never held past one cycle, on any way out of it. A claim that
// died holding it would wedge every wake in the fleet, and flock is the
// mechanism that promises it cannot: the kernel drops it with the process.
func TestClaimCycleNeverOutlivesTheFlock(t *testing.T) {
	failingClaim := func(string) error { return errors.New("the command that creates the pod failed") }
	cases := []struct {
		name    string
		scan    busyScan
		pool    string
		onClaim func(string) error
	}{
		{"after the card was claimed", scanOf(), "1", func(string) error { return nil }},
		{"after every card was held", scanOf(model(sref("1"))), "1", func(string) error { return nil }},
		{"after the claim's command failed", scanOf(), "1", failingClaim},
		{"after the scan failed", func(context.Context) (map[string]bool, error) {
			return nil, errors.New("api unavailable")
		}, "1", func(string) error { return nil }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			lock := t.TempDir() + "/cards.lock"
			// The outcome is not what this test is about: only that every way out of
			// the cycle leaves the lock alone.
			_, _ = claimJob(t, lock, tc.scan, tc.pool, "any", tc.onClaim)
			if !flockIsFree(t, lock) {
				t.Error("the placement lock is still held; every wake in the fleet now waits on a dead claim")
			}
		})
	}
}

// The release assertions are only evidence if two opens of one file do conflict,
// which flock guarantees because its lock belongs to the open file description
// and not the process. This is the assumption they rest on, so it is asserted.
func TestAFlockHolderIsVisibleToAnotherOpen(t *testing.T) {
	lock := t.TempDir() + "/cards.lock"
	held, err := cardLock(lock)
	if err != nil {
		t.Fatal(err)
	}
	if flockIsFree(t, lock) {
		cardUnlock(held)
		t.Fatal("a held lock read as free: every release assertion is vacuous")
	}
	cardUnlock(held)
	if !flockIsFree(t, lock) {
		t.Error("cardUnlock did not release the lock")
	}
}

// A claim whose pod never started holds nothing: the create command failed, so
// nothing was written to the cluster, and the card must read as free again to
// the next scan and to the next claim.
func TestClaimCycleReleasesTheCardWhenThePodNeverStarted(t *testing.T) {
	lock := t.TempDir() + "/cards.lock"
	_, err := claimJob(t, lock, scanOf(), "1", "any", func(string) error {
		return fmt.Errorf("kubectl apply: %w", errors.New("job spec rejected"))
	})
	if err == nil {
		t.Fatal("a claim whose command failed must not report success")
	}
	if !flockIsFree(t, lock) {
		t.Error("the placement lock is still held")
	}
	busy, err := cardsFromPods([]byte(pods()))
	if err != nil {
		t.Fatal(err)
	}
	if busy["1"] {
		t.Error("a pod that never existed is holding the card")
	}
	again, err := claimJob(t, lock, scanOf(), "1", "any", func(string) error { return nil })
	if err != nil || again != "1" {
		t.Errorf("the next claim after a failed one: %q, %v; want card 1", again, err)
	}
}

// flockIsFree reports whether nothing holds the placement lock, taken the way
// cardLock takes it. A blocking LOCK_EX would hang the suite instead of failing
// this test, so the assertion takes the non-blocking form.
func flockIsFree(t *testing.T, path string) bool {
	t.Helper()
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return false
	}
	syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	return true
}

// The card reaches the job's pod as the pin the ai chart already uses, and the
// pool the caller's own env carries must not survive into it: a pod rendered
// with "0,1" takes both cards while claiming one.
func TestPinChildEnvPinsTheChosenCardNotThePool(t *testing.T) {
	got := pinChildEnv([]string{"PATH=/usr/bin", gpuEnv + "=0,1", jobCardEnv + "=stale"}, "1", "forecats-nightly")
	if values := envValues(got, gpuEnv); len(values) != 1 || values[0] != "1" {
		t.Errorf("%s = %v, want exactly the chosen card", gpuEnv, values)
	}
	if values := envValues(got, jobCardEnv); len(values) != 1 || values[0] != "forecats-nightly" {
		t.Errorf("%s = %v, want the job name once", jobCardEnv, values)
	}
	if values := envValues(got, "PATH"); len(values) != 1 || values[0] != "/usr/bin" {
		t.Errorf("the caller's environment did not survive the pin: %v", values)
	}
}

func envValues(env []string, key string) []string {
	var out []string
	for _, kv := range env {
		if v, ok := strings.CutPrefix(kv, key+"="); ok {
			out = append(out, v)
		}
	}
	return out
}

// A claim is durable when its pod exists, and not before: this is what the cycle
// holds the flock for. A model on the card says the card is taken, not that the
// job's pod appeared, so it is not a yes here.
func TestGpuJobPodCarryingTheCardIsTheClaim(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want bool
	}{
		{"a live gpu-job pod on the card", pods(gpuJob(sref("1"))), true},
		{"a gpu-job pod that declared only the pool label", pods(podSpec{component: componentGpuJob, pool: "0,1"}), true},
		{"a gpu-job pod on another card", pods(gpuJob(sref("0"))), false},
		{"a model pod on the card", pods(model(sref("1"))), false},
		{"a terminating gpu-job pod", pods(podSpec{component: componentGpuJob, env: sref("1"), deleting: true}), false},
		{"a succeeded gpu-job pod", pods(podSpec{component: componentGpuJob, env: sref("1"), phase: "Succeeded"}), false},
		{"no pods at all", pods(), false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			pl := &podList{}
			if err := json.Unmarshal([]byte(tc.in), pl); err != nil {
				t.Fatal(err)
			}
			if got := pl.gpuJobHolds("1"); got != tc.want {
				t.Errorf("gpuJobHolds(1) = %v, want %v", got, tc.want)
			}
		})
	}
}

// A panic inside the claim must not leave the flock held by a process that is
// still running: flock belongs to the open file, so only the holder's death would
// give it back, and a live holder wedges every placement in the fleet.
func TestClaimCycleReleasesTheFlockWhenTheClaimPanics(t *testing.T) {
	lock := t.TempDir() + "/cards.lock"
	func() {
		defer func() {
			if recover() == nil {
				t.Error("the panic never reached the caller; the cycle swallowed it")
			}
		}()
		_, _ = claimJob(t, lock, scanOf(), "1", "any", func(string) error {
			panic("the exec machinery blew up")
		})
	}()
	if !flockIsFree(t, lock) {
		t.Error("a panic inside the claim left the placement lock held")
	}
}

// The pin reaches the command through the real exec path and not just the env
// builder: that value is what the caller renders into the pod spec, and the pod
// spec is where the nvidia runtime hook reads it.
func TestRunClaimedPinsTheCardForTheCommandItRuns(t *testing.T) {
	cardFile := filepath.Join(t.TempDir(), "card")
	o := &options{job: "forecats-nightly", jobCmd: []string{
		"sh", "-c", `printf '%s' "$NVIDIA_VISIBLE_DEVICES" >"$1"`, "sh", cardFile,
	}}

	if err := runClaimed(context.Background(), o, "1"); err != nil {
		t.Fatalf("runClaimed: %v", err)
	}

	got, err := os.ReadFile(cardFile)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "1" {
		t.Errorf("the command ran with %s=%q, want the chosen card", gpuEnv, got)
	}
}

// A claim's command failing is the job failing, and its exit code is the thing
// the caller acts on: main hands it back as the process's own, so a nightly that
// found no card and one whose apply was rejected stay different incidents.
func TestRunClaimedHandsBackTheCommandsExitCode(t *testing.T) {
	o := &options{job: "forecats-nightly", jobCmd: []string{"sh", "-c", "exit 3"}}

	err := runClaimed(context.Background(), o, "1")

	var ee *exec.ExitError
	if !errors.As(err, &ee) || ee.ExitCode() != 3 {
		t.Fatalf("runClaimed = %v, want the command's exit code 3", err)
	}
}

// A command that never started is a refusal, not a hang: Start fails before there
// is a process for anyone to wait on.
func TestRunClaimedReportsACommandThatNeverStarted(t *testing.T) {
	o := &options{job: "forecats-nightly", jobCmd: []string{"/does/not/exist/forecats-render"}}

	err := runClaimed(context.Background(), o, "1")

	if err == nil || !strings.Contains(err.Error(), "start") {
		t.Fatalf("runClaimed = %v, want a start failure", err)
	}
}
