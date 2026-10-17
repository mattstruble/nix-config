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

// The busy-card rules: existence claims (not readiness), terminating pods
// release, spanning pods claim every card in their pool, empty values claim
// nothing. Every one of these rules exists because its opposite crashloops a
// pod onto a busy card.
func TestCardsFromPods(t *testing.T) {
	pod := func(deleting bool, gpuVal string) string {
		dt := `"deletionTimestamp":null`
		if deleting {
			dt = `"deletionTimestamp":"2026-10-12T00:00:00Z"`
		}
		return fmt.Sprintf(`{"metadata":{"name":"p",%s},"spec":{"containers":[{"env":[{"name":"NVIDIA_VISIBLE_DEVICES","value":%q}]}]},"status":{}}`, dt, gpuVal)
	}
	cases := []struct {
		name string
		in   string
		want []string
	}{
		{"a running pod claims its card", `{"items":[` + pod(false, "1") + `]}`, []string{"1"}},
		{"a terminating pod releases its card", `{"items":[` + pod(true, "1") + `]}`, []string{}},
		{"a spanning pod claims every card in its pool", `{"items":[` + pod(false, "0,1") + `]}`, []string{"0", "1"}},
		{"an empty value claims nothing", `{"items":[` + pod(false, "") + `]}`, []string{}},
		{"two pods claim their own cards", `{"items":[` + pod(false, "0") + `,` + pod(false, "1") + `]}`, []string{"0", "1"}},
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
