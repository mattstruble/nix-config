package main

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
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
