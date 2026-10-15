package main

import (
	"encoding/json"
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
	    "labels":{"app":"ai"}},
	  "spec":{"replicas":7,"template":{"spec":{"containers":[{"name":"llama-server"}]}}},
	  "status":{"readyReplicas":1}
	}`)
	create, patch, err := normalizeSpec("default", "swift-qwen3-8-27b-g0", in)
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

	var createObj map[string]any
	if err := json.Unmarshal(create, &createObj); err != nil {
		t.Fatal(err)
	}
	if spec, _ := createObj["spec"].(map[string]any); spec["replicas"] != float64(1) {
		t.Errorf("create body should start the model at 1, got %v", spec["replicas"])
	}
	// The create body must still be a whole object, or POST rejects it.
	if createObj["apiVersion"] != "apps/v1" || createObj["kind"] != "Deployment" {
		t.Error("create body lost apiVersion/kind")
	}
}

// A spec mounted under the wrong name would put one model in another model's
// place, which is the kind of failure that looks like a haunted cluster.
func TestNormalizeSpecRefusesNameMismatch(t *testing.T) {
	in := []byte(`{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"gemma-4-26b-g0"},"spec":{"template":{}}}`)
	_, _, err := normalizeSpec("default", "swift-qwen3-8-27b-g0", in)
	if err == nil || !strings.Contains(err.Error(), "is mounted for") {
		t.Fatalf("want a mount-mismatch refusal, got %v", err)
	}
}

func TestNormalizeSpecRejectsGarbage(t *testing.T) {
	for _, bad := range []string{"", "not json", `{"metadata":{}}`, `{"metadata":{"name":"m"}}`} {
		if _, _, err := normalizeSpec("default", "m", []byte(bad)); err == nil {
			t.Errorf("expected an error for %q", bad)
		}
	}
}
