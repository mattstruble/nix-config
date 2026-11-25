package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
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

// ---- the busy-card query ---------------------------------------------------

// testClient points a client at a test server: what the scan sends is only
// observable at the HTTP boundary, and that query is the half of the busy-card
// scan no pod list can stand in for.
func testClient(srv *httptest.Server) *client { return &client{base: srv.URL, hc: srv.Client()} }

// The selector is pinned as the value the API receives, decoded from the request
// the scan really makes. An equality form, a dropped member, a missing space or a
// label constant rename that did not reach this line is a query the API accepts
// and answers with an empty list; an empty list is not an error, it is zero busy
// cards, a card handed to a second job, and a suite that stayed green.
func TestBusyCardsSendsTheCardOwnerSelector(t *testing.T) {
	var selector string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		selector = r.URL.Query().Get("labelSelector")
		fmt.Fprint(w, pods())
	}))
	defer srv.Close()

	if _, err := testClient(srv).busyCards(context.Background(), "ai"); err != nil {
		t.Fatalf("busyCards: %v", err)
	}
	const want = "app.kubernetes.io/component in (model,gpu-job)"
	if selector != want {
		t.Errorf("labelSelector = %q, want %q", selector, want)
	}
}

// The members are cardOwnerComponents, not a second list that happens to match it
// today: a third kind of card holder added to that list and not to the selector is
// a pod placement never sees, which is the bug component=gpu-job was added for.
func TestBusyCardSelectorMembersAreCardOwnerComponents(t *testing.T) {
	selector := busyCardSelector()
	_, members, set := strings.Cut(selector, " in (")
	if !set || !strings.HasSuffix(members, ")") {
		t.Fatalf("selector %q is not the set form the card owners go into", selector)
	}
	got := strings.Split(strings.TrimSuffix(members, ")"), ",")
	if !slices.Equal(got, cardOwnerComponents) {
		t.Errorf("selector selects %v; cardOwnerComponents is %v", got, cardOwnerComponents)
	}
}

// A scan the API refused arrives with no pods in it, exactly like a namespace in
// which nothing holds a card. Read as the second, the first hands out a card a
// running pod owns, so the distinction the caller has to be able to make is the
// error.
func TestBusyCardsSeparatesAnEmptyListFromAFailedScan(t *testing.T) {
	rejected := `{"kind":"Status","status":"Failure","message":"the label selector is invalid"}`
	cases := []struct {
		name    string
		status  int
		body    string
		wantErr bool
	}{
		{"an empty list is a scan that found nothing", http.StatusOK, pods(), false},
		{"a rejected selector is a failure", http.StatusBadRequest, rejected, true},
		{"a scan the ServiceAccount is not allowed to make is a failure", http.StatusForbidden, rejected, true},
		{"a body that is not a pod list is a failure", http.StatusOK, `{"items":[`, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(tc.status)
				fmt.Fprint(w, tc.body)
			}))
			defer srv.Close()

			busy, err := testClient(srv).busyCards(context.Background(), "ai")
			if !tc.wantErr {
				if err != nil {
					t.Fatalf("a namespace with no card holders must scan clean, got %v", err)
				}
				if len(busy) != 0 {
					t.Errorf("busy = %v, want no card held", busy)
				}
				return
			}
			if err == nil {
				t.Fatalf("a scan that failed returned busy=%v and no error; the caller reads that as every card free", busy)
			}
		})
	}
}

// And the error is what a placement does with: a claim whose scan failed must not
// reach the command that starts the pod, and the API's answer has to survive to
// whoever reads the failure.
func TestClaimRefusesWhenTheBusyScanFails(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		fmt.Fprint(w, `{"kind":"Status","status":"Failure","message":"the label selector is invalid"}`)
	}))
	defer srv.Close()

	claimed := false
	card, err := claimJob(t, t.TempDir()+"/cards.lock", testClient(srv).scanCards("ai"), "1", "any",
		func(string) error { claimed = true; return nil })
	if err == nil {
		t.Fatalf("a claim whose scan failed reported card %q", card)
	}
	if claimed {
		t.Error("a claim whose scan failed handed the card to the command it runs")
	}
	if !strings.Contains(err.Error(), "400") {
		t.Errorf("err = %v; want the API's answer, which is the diagnosis", err)
	}
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

// claimJob is the cycle a job claim runs, with the claim moment hidden: which
// card a round lands on does not depend on when it got the flock, and only a
// wake bounds anything after the claim by it.
func claimJob(t *testing.T, lockPath string, scan busyScan, pool, mode string, onClaim func(string) error) (string, error) {
	t.Helper()
	return claimCycle(context.Background(), lockPath, scan, splitCards(pool), pool, mode,
		refusalBudget, time.Millisecond, func(card string, _ time.Time) error { return onClaim(card) })
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
		5*time.Second, time.Millisecond, func(string, time.Time) error { return nil })
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

// ---- releasing a card a wake claimed ---------------------------------------

// fakeCluster is the state a release changes: the replica count of every
// Deployment in the namespace, and the error the API answers a write with. A
// release is only observable through the cluster, so this is the fake that
// answers "did the card come back" — and a refused write is a different incident
// from a release, which is why it is a field and not a separate type.
type fakeCluster struct {
	replicas map[string]int
	refuse   error
}

func (f fakeCluster) scale(ns, name string, replicas int) (bool, error) {
	if f.refuse != nil {
		return false, f.refuse
	}
	cur, ok := f.replicas[name]
	if !ok {
		return false, fmt.Errorf("deployments.apps %q not found in namespace %q", name, ns)
	}
	f.replicas[name] = replicas
	return cur != replicas, nil
}

// The pod-visibility window is bounded by the card-wait budget counted from the
// claim and not only by its own window: a wake that fell through to the readiness
// wait after its budget ran out holds the card for the whole startup timeout,
// which on a two-card host is half the fleet.
func TestPodVisibilityWindowEndsWithTheCardWaitBudget(t *testing.T) {
	cases := []struct {
		name                      string
		window, poll, budgetLeft  time.Duration
		appears                   bool
		probeErr                  error
		cancel                    bool
		wantAppeared, wantRelease bool
		maxElapsed                time.Duration
	}{
		{
			name:   "the pod appeared, so the flock can go back",
			window: 10 * time.Second, poll: 5 * time.Millisecond, budgetLeft: 10 * time.Second,
			appears: true, wantAppeared: true, maxElapsed: time.Second,
		},
		{
			name:   "the window ended with budget left: waitReady reports the cluster problem",
			window: 20 * time.Millisecond, poll: 5 * time.Millisecond, budgetLeft: time.Hour,
		},
		{
			name:   "the card-wait budget ended the window: the card goes back",
			window: 10 * time.Second, poll: 5 * time.Millisecond, budgetLeft: 20 * time.Millisecond,
			wantRelease: true, maxElapsed: 2 * time.Second,
		},
		{
			// A cancelled context is this process dying, not this model being
			// stopped: the Deployment keeps what it reached and the next wake
			// adopts it.
			name:   "the caller went away after the scale: the card stays claimed",
			window: 10 * time.Second, poll: 5 * time.Millisecond, budgetLeft: 10 * time.Second,
			cancel: true, maxElapsed: time.Second,
		},
		{
			// An unreachable API must not be read as a pod that will never appear:
			// the card of a pod that is coming must not be handed to a second owner.
			name:   "an unreachable API is not a release",
			window: 20 * time.Millisecond, poll: 5 * time.Millisecond, budgetLeft: time.Hour,
			probeErr: errors.New("connection refused"),
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ctx := context.Background()
			if tc.cancel {
				var cancel context.CancelFunc
				ctx, cancel = context.WithCancel(ctx)
				cancel()
			}

			started := time.Now()
			w := awaitPodVisible(ctx, tc.window, tc.poll, time.Now().Add(tc.budgetLeft),
				func() (bool, error) { return tc.appears, tc.probeErr })
			elapsed := time.Since(started)

			if w.appeared != tc.wantAppeared {
				t.Errorf("appeared = %v, want %v", w.appeared, tc.wantAppeared)
			}
			if (w.release != nil) != tc.wantRelease {
				t.Errorf("release = %v, want a release: %v", w.release, tc.wantRelease)
			}
			// The window is longer than the budget in the releasing cases, so a
			// wait past the bound means it ignored the budget and waited anyway.
			if tc.maxElapsed > 0 && elapsed > tc.maxElapsed {
				t.Errorf("the window took %s (budget %s, window %s)", elapsed, tc.budgetLeft, tc.window)
			}
		})
	}
}

// A wake whose pod never becomes ready must give the card back: a Deployment
// left at one replica with a pod in ImagePullBackOff holds its card until someone
// notices it and scales it by hand, and nothing in the process ever notices.
func TestWakeReleasesTheCardOfAPodThatNeverBecomesReady(t *testing.T) {
	cluster := fakeCluster{replicas: map[string]int{"swift-qwen3-8-27b-g0": 1}}

	cause := fmt.Errorf("%w after 10m0s: pod swift-qwen3-7d4 container llama-server waiting: ImagePullBackOff", errStartupTimeout)
	err := giveBackCard(cluster, "default", "swift-qwen3-8-27b-g0", "1", cause)

	if cluster.replicas["swift-qwen3-8-27b-g0"] != 0 {
		t.Errorf("gpu 1 is still claimed: the Deployment is at %d replicas",
			cluster.replicas["swift-qwen3-8-27b-g0"])
	}
	// Whoever reads the log has to know which card came back and why it went.
	for _, want := range []string{"gpu 1", "swift-qwen3-8-27b-g0", "ImagePullBackOff"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("the release error does not name %q: %v", want, err)
		}
	}
}

// The line an operator reads when a readiness wait ends in a timeout says what
// the last poll actually saw, because the two readings are different incidents
// debugged by different people: "pod x waiting: ImagePullBackOff" is the pod, and
// "cannot read pods: 503" is a cluster that stopped answering, which the pod knows
// nothing about.
func TestTheReadinessTimeoutSaysWhatTheLastPollSaw(t *testing.T) {
	o := &options{namespace: "default", poll: time.Millisecond, startupTimeout: 20 * time.Millisecond}
	sel := map[string]string{modelLabel: "swift-qwen3-8-27b"}

	cases := []struct {
		name    string
		answers []readyAnswer
		wants   []string
		not     string
	}{
		{
			name:    "a pod the API has described as stuck",
			answers: []readyAnswer{{reason: "pod swift-qwen3-7d4 container llama-server waiting: ImagePullBackOff"}},
			wants:   []string{"startup timeout", "ImagePullBackOff"},
			not:     "cannot read pods",
		},
		{
			name:    "an API that never answered the last poll",
			answers: []readyAnswer{{err: errors.New("503 Service Unavailable: apiserver is restarting")}},
			wants:   []string{"startup timeout", "cannot read pods", "503"},
			not:     "ImagePullBackOff",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := waitReady(context.Background(), &fakeWake{answers: tc.answers}, o, sel)
			if !errors.Is(err, errStartupTimeout) {
				t.Fatalf("waitReady = %v, want a startup timeout", err)
			}
			for _, want := range tc.wants {
				if !strings.Contains(err.Error(), want) {
					t.Errorf("the timeout does not say %q: %v", want, err)
				}
			}
			if strings.Contains(err.Error(), tc.not) {
				t.Errorf("the timeout claims %q as well: %v", tc.not, err)
			}
		})
	}
}

// A release the API refused leaves the card held, and the only way back is a
// human with a kubectl: the error has to say the card is still held and what to
// do, or the operator reads a release that never happened.
func TestAReleaseTheAPIRefusedSaysTheCardIsStillHeld(t *testing.T) {
	cluster := fakeCluster{
		replicas: map[string]int{"gemma-4-26b-g0": 1},
		refuse:   errors.New("403 deployments/scale is forbidden"),
	}

	err := giveBackCard(cluster, "default", "gemma-4-26b-g0", "0",
		fmt.Errorf("%w after 10m0s: pod gemma-4-26b-9x2f waiting: CreateContainerConfigError", errStartupTimeout))

	for _, want := range []string{"gpu 0", "still held", "403", "by hand"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("the error does not say %q: %v", want, err)
		}
	}
}

// ---- what a wake does to the cluster ----------------------------------------

// wakeModel is the model every wake test names: the 27B coder, whose startup is
// long enough that a readiness wait is thousands of polls.
const wakeModel = "swift-qwen3-8-27b"

// readyAnswer is one readiness poll: the IP of a Ready pod, the reason there is
// no such pod yet, or the fault the API answered with.
type readyAnswer struct {
	ip     string
	reason string
	err    error
}

// fakeWake is the cluster a wake talks to, and the only place a wake's decision
// is observable: the replica count the Deployment ends at. The readiness answers
// are a queue because the rule at issue is what a wake does with a fault in the
// middle of a wait of thousands of polls; the last answer repeats once the queue
// runs out, so a scenario states only the polls it cares about, and one entry is
// an API that never recovers.
//
// Every test reads this state after the wake it started has returned.
type fakeWake struct {
	// replicas is the state a release changes. A Deployment absent from the map
	// does not exist yet, which is where a fresh placement starts.
	replicas map[string]int
	// podAppearsAtProbe is the visibility probe at which the Deployment's pod
	// becomes visible. A scaled Deployment takes seconds to produce one, so a
	// window that ends on its first probe has not looked yet. Zero, the zero value,
	// means the pod never appears.
	podAppearsAtProbe int
	// answers is what readyPod replies, one entry per poll.
	answers []readyAnswer

	// probes and visits count the polls the wake made: whether a second visibility
	// probe happened at all is what says whether its window ran.
	probes int
	visits int
}

func (f *fakeWake) getDeployment(ns, name string) (*deployment, error) {
	r, ok := f.replicas[name]
	if !ok {
		return nil, nil
	}
	return &deployment{Name: name, Replicas: r, Selector: map[string]string{modelLabel: name}}, nil
}

func (f *fakeWake) podsForDeployment(ns string, sel map[string]string) (bool, error) {
	f.probes++
	return f.podAppearsAtProbe > 0 && f.probes >= f.podAppearsAtProbe, nil
}

func (f *fakeWake) readyPod(ns string, sel map[string]string) (string, string, error) {
	if len(f.answers) == 0 {
		return "", "no pods", nil
	}
	i := min(f.visits, len(f.answers)-1)
	f.visits++
	return f.answers[i].ip, f.answers[i].reason, f.answers[i].err
}

// applyDeployment creates the Deployment at one replica, which is what the create
// body normalizeSpec emits carries; an update leaves the count alone, because that
// is the write the ConfigMap indirection exists to keep from the chart.
func (f *fakeWake) applyDeployment(ns, name, gpu string, spec []byte, existing *deployment) error {
	if f.replicas == nil {
		f.replicas = map[string]int{}
	}
	if existing == nil {
		f.replicas[name] = 1
	}
	return nil
}

func (f *fakeWake) scale(ns, name string, replicas int) (bool, error) {
	cur, ok := f.replicas[name]
	if !ok {
		return false, fmt.Errorf("deployments.apps %q not found in namespace %q", name, ns)
	}
	f.replicas[name] = replicas
	return cur != replicas, nil
}

// scanCards sees an empty namespace: the card the wake's pool names is free, so
// these tests say nothing about placement and everything about what follows it.
func (f *fakeWake) scanCards(ns string) busyScan {
	return func(context.Context) (map[string]bool, error) { return map[string]bool{}, nil }
}

// replicasOf is the assertion every wake test makes: which replica count the
// Deployment ended at.
func (f *fakeWake) replicasOf(name string) int { return f.replicas[name] }

// visibilityProbes counts the polls the pod-visibility window made: a second one
// is a window that waited, and one is a window that gave up.
func (f *fakeWake) visibilityProbes() int { return f.probes }

// wakeSpec writes the chart-rendered spec a fresh placement reads: the POOL in the
// labels and in NVIDIA_VISIBLE_DEVICES, which is what the shim narrows to a card.
func wakeSpec(t *testing.T, dir, name, pool string) {
	t.Helper()
	spec := fmt.Sprintf(`{"apiVersion":"apps/v1","kind":"Deployment",`+
		`"metadata":{"name":%q,"labels":{%q:%q,%q:"any"}},`+
		`"spec":{"template":{"spec":{"containers":[{"name":"llama-server",`+
		`"env":[{"name":%q,"value":%q}]}]}}}}`, name, gpuPoolLabel, pool, gpuModeLabel, gpuEnv, pool)
	if err := os.WriteFile(filepath.Join(dir, name+".json"), []byte(spec), 0o644); err != nil {
		t.Fatal(err)
	}
}

// wakeOptions is the flag set a wake test runs with: budgets short enough that a
// timeout is a test result and not a wait. The pod-claim window is the value the
// chart renders, because none of these wakes is bounded by it - the two budgets
// above are what the test is measuring.
func wakeOptions(dir, lock string, cardWait, startupTimeout time.Duration) *options {
	return &options{namespace: "default", model: wakeModel, specDir: dir, cardLock: lock,
		poll: 5 * time.Millisecond, cardWait: cardWait, startupTimeout: startupTimeout,
		podClaimWindow: time.Minute}
}

// A 429 from API priority-and-fairness, a 500 or 503 during a k3s apiserver
// restart, a connection reset, this client's own 30s timeout: a readiness wait
// polls once a second for the whole startup timeout, so one blip in thousands of
// calls is routine. A failed poll is the API, not the pod, and the pod behind it
// is nearly ready — ending the wait on the blip would scale that pod to zero and
// log the pod as the culprit.
func TestWakeTreatsAFailedPollAsNotReadyYet(t *testing.T) {
	dir := t.TempDir()
	wakeSpec(t, dir, wakeModel, "1")
	kc := &fakeWake{podAppearsAtProbe: 1, answers: []readyAnswer{
		{err: errors.New("429 Too Many Requests: global rate limit exceeded")},
		{err: errors.New("read tcp 10.43.0.1:443: connection reset by peer")},
		{ip: "10.42.0.17"},
	}}

	if _, err := wake(context.Background(), kc, wakeOptions(dir, dir+"/cards.lock", time.Minute, time.Minute)); err != nil {
		t.Fatalf("wake: %v", err)
	}
	if got := kc.replicasOf(wakeModel); got != 1 {
		t.Errorf("gpu 1 is gone: the Deployment is at %d replicas after two failed polls", got)
	}
}

// The other end of the same rule: a fault is never a reason to take a card away,
// but a startup timeout spent entirely without an answer still ends the wait.
// Somebody has to notice an API that stopped answering, and the line says the wait
// last saw a fault rather than a pod in a bad state, because that is all it saw.
func TestWakeReleasesTheCardOnATimeoutItCouldNotSeePast(t *testing.T) {
	dir := t.TempDir()
	wakeSpec(t, dir, wakeModel, "1")
	kc := &fakeWake{podAppearsAtProbe: 1, answers: []readyAnswer{
		{err: errors.New("503 Service Unavailable: etcdserver: request timed out")},
	}}

	_, err := wake(context.Background(), kc, wakeOptions(dir, dir+"/cards.lock", time.Minute, 30*time.Millisecond))

	if !errors.Is(err, errStartupTimeout) {
		t.Fatalf("wake = %v, want a startup timeout", err)
	}
	if got := kc.replicasOf(wakeModel); got != 0 {
		t.Errorf("gpu 1 is still claimed: the Deployment is at %d replicas", got)
	}
	for _, want := range []string{"gpu 1", "cannot read pods"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("the release does not say %q: %v", want, err)
		}
	}
}

// A pod the API has described as not-ready for its whole startup timeout is not
// coming, and a Deployment left at one replica holds that card until a human
// scales it by hand: this is the one ending a wake gives the card back for.
func TestWakeReleasesTheCardWhenTheStartupTimeoutExpires(t *testing.T) {
	dir := t.TempDir()
	wakeSpec(t, dir, wakeModel, "1")
	kc := &fakeWake{podAppearsAtProbe: 1, answers: []readyAnswer{
		{reason: "pod swift-qwen3-7d4 container llama-server waiting: ImagePullBackOff"},
	}}

	_, err := wake(context.Background(), kc, wakeOptions(dir, dir+"/cards.lock", time.Minute, 30*time.Millisecond))

	if err == nil {
		t.Fatal("a pod that never became ready is not a successful wake")
	}
	if got := kc.replicasOf(wakeModel); got != 0 {
		t.Errorf("gpu 1 is still claimed: the Deployment is at %d replicas", got)
	}
	for _, want := range []string{"gpu 1", wakeModel, "ImagePullBackOff"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("the release does not name %q: %v", want, err)
		}
	}
}

// A wake that adopted a pod it did not place leaves the Deployment alone however
// the pod is doing: the pod predates the wake, and putting a model to sleep is
// cmdStop's and cmdReap's job. Evicting an adopted pod turns a slow load into an
// eviction, killing the pod that was loading.
func TestAWakeThatAdoptedAPodLeavesTheDeploymentAtOne(t *testing.T) {
	dir := t.TempDir()
	kc := &fakeWake{
		replicas:          map[string]int{wakeModel: 1},
		podAppearsAtProbe: 1,
		answers:           []readyAnswer{{reason: "pod swift-qwen3-7d4 phase=Pending"}},
	}

	if _, err := wake(context.Background(), kc, wakeOptions(dir, dir+"/cards.lock", time.Minute, 30*time.Millisecond)); err == nil {
		t.Error("a model that never became ready is not a successful wake")
	}
	if got := kc.replicasOf(wakeModel); got != 1 {
		t.Errorf("the adopted pod was evicted: the Deployment is at %d replicas, want 1", got)
	}
}

// SIGTERM means llama-swap is going away, not that this model should be: cmdServe
// says so, and cmdStop is what stops a model. A wake cancelled mid-flight
// therefore leaves the Deployment at whatever it reached. Scaling on the way out
// is how a head-end container restart kills a model mid-wake, racily, in exactly
// the case the adoption path exists to survive.
func TestACancelledWakeLeavesTheDeploymentAtOne(t *testing.T) {
	cases := []struct {
		name              string
		podAppearsAtProbe int
		answers           []readyAnswer
	}{
		{"cancelled while waiting for the pod to appear", 0, nil},
		{"cancelled while waiting for readiness", 1, []readyAnswer{{reason: "pod swift-qwen3-7d4 phase=Pending"}}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			wakeSpec(t, dir, wakeModel, "1")
			kc := &fakeWake{podAppearsAtProbe: tc.podAppearsAtProbe, answers: tc.answers}
			ctx, cancel := context.WithCancel(context.Background())
			go func() {
				time.Sleep(50 * time.Millisecond)
				cancel()
			}()

			_, err := wake(ctx, kc, wakeOptions(dir, dir+"/cards.lock", time.Minute, time.Minute))

			if !errors.Is(err, context.Canceled) {
				t.Errorf("wake = %v, want the cancellation reported", err)
			}
			if got := kc.replicasOf(wakeModel); got != 1 {
				t.Errorf("gpu 1 was released on the way out: the Deployment is at %d replicas", got)
			}
		})
	}
}

// A round that queued behind another shim's hold on the flock starts its
// visibility window when it got the card, not when the wake began. A scaled
// Deployment takes seconds to produce a pod, so a window's first answer is normally
// "not yet" and the pod turns up on a later poll; anchored at the wake, a round
// that got the flock after the card-wait budget had been spent ends on that first
// answer and hands the card back blaming a pod it never looked at twice. Not a
// race: two shims on one host do this whenever one holds the flock for its own
// visibility window.
func TestAWakeThatQueuedForTheCardStillGetsItsWindow(t *testing.T) {
	dir := t.TempDir()
	wakeSpec(t, dir, wakeModel, "1")
	lock := dir + "/cards.lock"
	anotherShim, err := cardLock(lock)
	if err != nil {
		t.Fatal(err)
	}

	// The pod is there for the window's second probe, one podClaimPoll after the
	// first. Only a window that started at the claim has that much budget left: the
	// flock goes back to this wake a whole card-wait after its budget was spent.
	kc := &fakeWake{podAppearsAtProbe: 2, answers: []readyAnswer{{ip: "10.42.0.17"}}}
	done := make(chan error, 1)
	go func() {
		_, err := wake(context.Background(), kc, wakeOptions(dir, lock, time.Second, 50*time.Millisecond))
		done <- err
	}()

	// The other shim lets go only after the wake's whole card-wait budget is spent.
	time.Sleep(1100 * time.Millisecond)
	cardUnlock(anotherShim)

	if err := <-done; err != nil {
		t.Errorf("wake: %v", err)
	}
	if got := kc.visibilityProbes(); got < 2 {
		t.Errorf("the window probed %d time(s) and gave up: it was anchored at the wake, not at the claim", got)
	}
	if got := kc.replicasOf(wakeModel); got != 1 {
		t.Errorf("gpu 1 was handed back unseen: the Deployment is at %d replicas, want 1", got)
	}
}

// The pod-visibility window re-checks the card-wait budget instead of falling
// through to the readiness wait: a Deployment that has produced no pod when the
// budget runs out is a card this wake holds for nothing, and the wake fails with
// the card named.
func TestClaimReleasesTheCardWhenNoPodAppearedWithinTheBudget(t *testing.T) {
	lock := t.TempDir() + "/cards.lock"
	cluster := fakeCluster{replicas: map[string]int{"swift-qwen3-8-27b-g0": 0}}

	_, err := claimCycle(context.Background(), lock, scanOf(), []string{"1"}, "1", "any",
		time.Minute, time.Millisecond, func(card string, _ time.Time) error {
			if _, err := cluster.scale("default", "swift-qwen3-8-27b-g0", 1); err != nil {
				t.Error(err)
			}
			// The wake's card-wait is shorter than the pod-visibility window, so the
			// budget — counted from the claim — ends the window before the window does.
			w := awaitPodVisible(context.Background(), 30*time.Second, time.Millisecond,
				time.Now().Add(20*time.Millisecond), func() (bool, error) { return false, nil })
			if w.release == nil {
				t.Error("the window fell through to the readiness wait instead of ending with the budget")
				return nil
			}
			return giveBackCard(cluster, "default", "swift-qwen3-8-27b-g0", card, w.release)
		})

	if err == nil || !strings.Contains(err.Error(), "gpu 1") {
		t.Fatalf("want a failure naming the released card, got %v", err)
	}
	if cluster.replicas["swift-qwen3-8-27b-g0"] != 0 {
		t.Errorf("gpu 1 is still claimed: the Deployment is at %d replicas",
			cluster.replicas["swift-qwen3-8-27b-g0"])
	}
	if !flockIsFree(t, lock) {
		t.Error("the placement lock is still held")
	}

	again, err := claimJob(t, lock, scanOf(), "1", "any", func(string) error { return nil })
	if err != nil || again != "1" {
		t.Errorf("the next wake after the release got %q (%v); want card 1", again, err)
	}
}
