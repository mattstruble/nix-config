// Command swapk8s gives llama-swap a Kubernetes lifecycle handle over model
// Deployments whose pod spec belongs to something else — the helm chart in this
// repo, rendered by nix.
//
// Why this exists: llama-swap ships cmd/kubeswap, a Kubernetes driver that
// renders its own PodSpec. That renderer handles containers, volumes,
// nodeSelector, tolerations and grace period, and nothing else. This cluster
// needs runtimeClassName: nvidia (CDI, deliberately no device plugin), pod and
// container securityContext (namespace PodSecurity is `restricted`), a
// log-exporter sidecar, and ConfigMap mounts. Adopting kubeswap would mean
// making `nvidia` the cluster-default RuntimeClass and relaxing PSS in the
// model namespace — trading away two decisions this repo paid for. So the chart
// keeps the pod spec and swapk8s keeps the lifecycle: create-or-update from a
// spec the chart rendered, scale, wait for readiness, proxy, reap, and hand a
// card to a job that is not a model at all.
//
// The spec arrives as JSON in a ConfigMap, not as a Deployment in the manifest.
// That indirection is the whole point: if the chart rendered the Deployment
// itself, every `kubectl apply` would fight the shim over .spec.replicas and
// silently scale a serving model to zero. With the spec parked in a ConfigMap,
// re-applying the manifest changes data nobody is running, and the new spec is
// picked up on the next wake.
//
// Stdlib only, on purpose. No client-go means no dependency graph to vendor,
// and plain REST plus one-second polling is exactly what kubeswap does.
package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	// managedLabel marks a Deployment this binary created. Reaping keys off it
	// so a Deployment the chart owns outright is never touched by accident.
	managedLabel = "app.kubernetes.io/managed-by"
	managedBy    = "swapk8s"
	// modelLabel carries the llama-swap model ID, which is what the roster
	// speaks. Deployment names are derived from it, not the other way round.
	modelLabel = "ai.mestruble.dev/model"
	// The label that says what a pod in the model namespace is; its value is
	// what decides whether GPU placement sees the pod at all.
	componentLabel = "app.kubernetes.io/component"
	// componentModel is a fleet model (rendered by ai.modelLabels in the chart,
	// and the value the network policies and the ai-fleet ServiceMonitor select
	// on). componentGpuJob is a pod that holds a card and is not a model - a
	// render, a fine-tune run. It must never carry component=model: that label
	// is what puts a pod in the llama-swap roster, the model dashboards and the
	// ai_model_* metrics, and a two-minute batch job belongs in none of them.
	// Without a value of its own such a pod was invisible to placement, which is
	// how a wake landed a model on a card the render already held.
	componentModel  = "model"
	componentGpuJob = "gpu-job"
	// The GPU pool and mode travel as labels on the spec the chart rendered:
	// gpu-pool is the list of cards a model may use ("0", "1", "0,1"), gpu-mode
	// is how to read it - "any" (land on one free card from the pool) or "all"
	// (a spanning model that needs every card in the pool). The chart renders
	// them from the values entry; placement is the shim's, so the contract
	// between them has to be this explicit.
	gpuPoolLabel = "ai.mestruble.dev/gpu-pool"
	gpuModeLabel = "ai.mestruble.dev/gpu-mode"
	// reclaimCostLabel is the third chart-to-shim transport label: what bringing
	// this model back costs whoever loses its card, in whole seconds. It is a
	// label and not a key in llama-swap's config.yaml because the pinned router
	// has no such field and ignores it there; here it decides which idle card a
	// waiting job takes. A model that renders no cost is never reclaimed.
	reclaimCostLabel = "ai.mestruble.dev/reclaim-cost-seconds"
	// appNameLabel is the model ID on a model pod (ai.modelLabels renders it, and
	// it is the Deployment's selector). A reclaim names the model whose card it is
	// taking, and the pod is the only object that says which model holds which
	// card: the Deployment carries the pool, not the card placement resolved.
	appNameLabel = "app"
	// The env var the spec uses to pin a card, rendered from the values entry.
	// In the spec ConfigMap it carries the POOL; at placement time the shim
	// narrows it to the card it chose.
	gpuEnv = "NVIDIA_VISIBLE_DEVICES"
	// Where every shim in the head-end pod serialises placement. /tmp is the
	// one writable path the head-end pod mounts for the shims (an emptyDir);
	// every serve process in the pod sees the same file, and flock is the only
	// coordination that survives a holder's death.
	cardLockPath = "/tmp/swapk8s-cards.lock"
	// jobCardEnv carries the chosen card to the command a claim runs, beside the
	// pin itself. NVIDIA_VISIBLE_DEVICES is what the pod must end up carrying;
	// this is for the caller that names the card somewhere the env is not - a Job
	// template's own label, a log line, a file it renders.
	jobCardEnv = "SWAPK8S_CARD"
)

const (
	// How often the pod-visibility window (--pod-claim-window) re-asks the API
	// whether the pod has appeared. The window itself is deliberately not here:
	// the chart renders it, because llama-swap's wake deadline is summed from that
	// same number (k8s/apps/ai/templates/head-end-configmap.yaml), and a second
	// copy of it in this binary is a term of the deadline no render can see.
	podClaimPoll = 500 * time.Millisecond
	// How long a claim's command gets to die after the caller's SIGTERM before it
	// is killed. The flock must go back either way, and a child that ignores
	// signals must not hold the fleet's placement with it.
	claimKillGrace = 10 * time.Second
)

// cardOwnerComponents is the one list the busy-card scan derives from: the API
// selector and the classifier both read it, so a further category of card holder
// is added here and nowhere else.
var cardOwnerComponents = []string{componentModel, componentGpuJob}

// ---- Kubernetes client -----------------------------------------------------

type client struct {
	base string
	tok  string
	hc   *http.Client
}

type apiErr struct {
	code int
	body string
}

func (e *apiErr) Error() string { return fmt.Sprintf("kubernetes: %d %s", e.code, e.body) }

// status returns the HTTP code, or 0 for a transport error. 404 is a control
// signal here (does the Deployment exist?), not an error.
func (e *apiErr) status() int { return e.code }

func newClient(apiServer, tokenFile, caFile string) (*client, error) {
	if apiServer == "" {
		host, port := os.Getenv("KUBERNETES_SERVICE_HOST"), os.Getenv("KUBERNETES_SERVICE_PORT")
		if host == "" || port == "" {
			return nil, fmt.Errorf("no --api-server and no KUBERNETES_SERVICE_HOST/PORT (in-cluster config is the default)")
		}
		apiServer = "https://" + host + ":" + port
		tokenFile = "/var/run/secrets/kubernetes.io/serviceaccount/token"
		caFile = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
	}
	tok := ""
	if tokenFile != "" {
		b, err := os.ReadFile(tokenFile)
		if err != nil {
			return nil, fmt.Errorf("read token: %w", err)
		}
		tok = strings.TrimSpace(string(b))
	}
	tlsCfg := &tls.Config{MinVersion: tls.VersionTLS12}
	if caFile != "" {
		pem, err := os.ReadFile(caFile)
		if err != nil {
			return nil, fmt.Errorf("read ca: %w", err)
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(pem) {
			return nil, fmt.Errorf("ca: no certificates parsed")
		}
		tlsCfg.RootCAs = pool
	}
	return &client{
		base: strings.TrimRight(apiServer, "/"),
		tok:  tok,
		// The 30s bound is for API calls only. The proxy path builds its own
		// transport so a long prefill is never cut by a client timeout.
		hc: &http.Client{Transport: &http.Transport{TLSClientConfig: tlsCfg}, Timeout: 30 * time.Second},
	}, nil
}

func (c *client) do(method, path, contentType string, body []byte) ([]byte, error) {
	var rd io.Reader
	if body != nil {
		rd = bytes.NewReader(body)
	}
	req, err := http.NewRequest(method, c.base+path, rd)
	if err != nil {
		return nil, err
	}
	if c.tok != "" {
		req.Header.Set("Authorization", "Bearer "+c.tok)
	}
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	resp, err := c.hc.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 300 {
		return nil, &apiErr{code: resp.StatusCode, body: string(out)}
	}
	return out, nil
}

// deployment is the slice of the object this binary reasons about.
type deployment struct {
	Name       string
	Replicas   int
	ReadyRep   int
	Selector   map[string]string
	Generation int64
}

func (c *client) getDeployment(ns, name string) (*deployment, error) {
	raw, err := c.do(http.MethodGet, fmt.Sprintf("/apis/apps/v1/namespaces/%s/deployments/%s", ns, name), "", nil)
	if err != nil {
		if ae, ok := err.(*apiErr); ok && ae.status() == http.StatusNotFound {
			return nil, nil
		}
		return nil, err
	}
	var obj struct {
		Metadata struct {
			Name       string `json:"name"`
			Generation int64  `json:"generation"`
		} `json:"metadata"`
		Spec struct {
			Replicas *int `json:"replicas"`
			Selector struct {
				MatchLabels map[string]string `json:"matchLabels"`
			} `json:"selector"`
		} `json:"spec"`
		Status struct {
			ReadyReplicas int `json:"readyReplicas"`
		} `json:"status"`
	}
	if err := json.Unmarshal(raw, &obj); err != nil {
		return nil, fmt.Errorf("decode deployment %s: %w", name, err)
	}
	d := &deployment{Name: obj.Metadata.Name, Selector: obj.Spec.Selector.MatchLabels,
		ReadyRep: obj.Status.ReadyReplicas, Generation: obj.Metadata.Generation}
	if obj.Spec.Replicas != nil {
		d.Replicas = *obj.Spec.Replicas
	} else {
		d.Replicas = 1 // the API default; an omitted field is not zero
	}
	return d, nil
}

// scale sets the replica count. It reports whether anything changed, because
// every caller needs that answer: scaling a Deployment that is already at the
// requested count is a no-op at the API level but a model restart at the
// semantic level if it wakes a pod llama-swap is about to adopt.
func (c *client) scale(ns, name string, replicas int) (bool, error) {
	cur, err := c.getDeployment(ns, name)
	if err != nil {
		return false, err
	}
	if cur == nil {
		return false, nil
	}
	if cur.Replicas == replicas {
		return false, nil
	}
	patch, _ := json.Marshal(map[string]any{"spec": map[string]any{"replicas": replicas}})
	_, err = c.do(http.MethodPatch, fmt.Sprintf("/apis/apps/v1/namespaces/%s/deployments/%s/scale", ns, name),
		"application/merge-patch+json", patch)
	return err == nil, err
}

// normalizeSpec turns the chart-rendered spec into the two request bodies this
// binary needs. gpu is the resolved card(s) for NVIDIA_VISIBLE_DEVICES - for an
// "any"-mode model exactly one card, for an "all"-mode (spanning) model the
// pool verbatim. The spec as rendered carries the POOL, and a pool must never
// reach the API unresolved: an "any" model created with "0,1" would take both
// cards while claiming one. It is pure so the guards are testable without an
// API server.
func normalizeSpec(ns, name, gpu string, spec []byte) (create []byte, patch []byte, err error) {
	var body map[string]any
	if err := json.Unmarshal(spec, &body); err != nil {
		return nil, nil, fmt.Errorf("spec for %s is not valid JSON: %w", name, err)
	}
	meta, _ := body["metadata"].(map[string]any)
	if meta == nil {
		return nil, nil, fmt.Errorf("spec for %s has no metadata", name)
	}
	// Belt and braces: a spec that disagrees with where it is being applied is a
	// chart bug, and the failure mode (a model appearing in another model's
	// place) is unpleasant enough to be worth refusing outright.
	if got, _ := meta["name"].(string); got != "" && got != name {
		return nil, nil, fmt.Errorf("spec names %q but is mounted for %q", got, name)
	}
	specMap, ok := body["spec"].(map[string]any)
	if !ok {
		return nil, nil, fmt.Errorf("spec for %s has no .spec", name)
	}

	labels, _ := meta["labels"].(map[string]any)
	if labels == nil {
		labels = map[string]any{}
	}
	labels[managedLabel] = managedBy
	labels[modelLabel] = name
	// The pool, mode and reclaim-cost labels are a transport channel from the
	// chart to this binary's placement logic, not object metadata: the shim reads
	// them from the spec file before it decides a card, and a live object that
	// carried them too would be a second copy of a value with one source - a
	// Deployment keeps the cost it was created with across a values change. A
	// pool like "0,1" is not even a valid label VALUE (kubernetes rejects commas),
	// so applying that one is a 422 rather than a preference.
	delete(labels, gpuPoolLabel)
	delete(labels, gpuModeLabel)
	delete(labels, reclaimCostLabel)
	meta["labels"] = labels
	meta["namespace"] = ns
	// Server-set fields cannot be replayed, and status must never be written by
	// a client.
	delete(meta, "resourceVersion")
	delete(meta, "uid")
	delete(meta, "creationTimestamp")
	delete(body, "status")
	// .spec.replicas is the field this binary owns and the chart must not be
	// able to write: that is the whole reason the spec travels as a ConfigMap
	// instead of as a Deployment in the manifest.
	delete(specMap, "replicas")

	// Placement: the spec arrives with the POOL in NVIDIA_VISIBLE_DEVICES; the
	// chosen card(s) replace it. The mode is the caller's contract: wake passes
	// exactly one card for an any-mode model and the pool verbatim for an
	// all-mode (spanning) one. Only an empty resolution is refused here - it
	// means placement failed and a pool must never reach the API unresolved.
	if gpu == "" {
		return nil, nil, fmt.Errorf("spec for %s: no card resolved for %s (the chart rendered the pool; placement failed to narrow it)", name, gpuEnv)
	}
	{
		tmpl, ok := specMap["template"].(map[string]any)
		if !ok {
			return nil, nil, fmt.Errorf("spec for %s has no .spec.template", name)
		}
		pspec, _ := tmpl["spec"].(map[string]any)
		if pspec == nil {
			return nil, nil, fmt.Errorf("spec for %s has no .spec.template.spec", name)
		}
		containers, _ := pspec["containers"].([]any)
		if len(containers) == 0 {
			return nil, nil, fmt.Errorf("spec for %s has no containers", name)
		}
		c0, _ := containers[0].(map[string]any)
		env, _ := c0["env"].([]any)
		found := false
		for _, e := range env {
			em, ok := e.(map[string]any)
			if !ok || em["name"] != gpuEnv {
				continue
			}
			em["value"] = gpu
			found = true
		}
		if !found {
			return nil, nil, fmt.Errorf("spec for %s has no %s env (the chart must render it from the model's gpu pool)", name, gpuEnv)
		}
	}

	// The update body must not carry a replica count: that is the write conflict
	// the ConfigMap indirection exists to prevent.
	patchBody, err := json.Marshal(map[string]any{
		"metadata": map[string]any{"labels": labels},
		"spec":     specMap,
	})
	if err != nil {
		return nil, nil, err
	}
	// Creating starts the model, so only the create body carries one. Marshalled
	// from the same map afterwards, so the two bodies cannot drift anywhere else.
	specMap["replicas"] = 1
	if create, err = json.Marshal(body); err != nil {
		return nil, nil, err
	}
	return create, patchBody, nil
}

// applyDeployment creates the Deployment from the chart-rendered spec, or
// updates the existing one. spec is the JSON the chart emitted.
func (c *client) applyDeployment(ns, name, gpu string, spec []byte, existing *deployment) error {
	createBody, patchBody, err := normalizeSpec(ns, name, gpu, spec)
	if err != nil {
		return err
	}
	if existing == nil {
		_, err = c.do(http.MethodPost, fmt.Sprintf("/apis/apps/v1/namespaces/%s/deployments", ns),
			"application/json", createBody)
		if ae, ok := err.(*apiErr); ok && ae.status() == http.StatusConflict {
			// Someone created it between our GET and POST. The next wake's update
			// path handles it; racing is not an outage.
			return fmt.Errorf("deployment %s appeared during create; re-run the wake", name)
		}
		return err
	}
	_, err = c.do(http.MethodPatch, fmt.Sprintf("/apis/apps/v1/namespaces/%s/deployments/%s", ns, name),
		"application/merge-patch+json", patchBody)
	return err
}

type podList struct {
	Items []podItem `json:"items"`
}

// podItem is the slice of a pod this binary reasons about: which component it
// belongs to, which card its containers are pinned to, and whether it is still
// around to own it.
type podItem struct {
	Metadata struct {
		Name              string            `json:"name"`
		Labels            map[string]string `json:"labels"`
		DeletionTimestamp any               `json:"deletionTimestamp"`
	} `json:"metadata"`
	Spec struct {
		Containers []struct {
			Env []struct {
				Name  string `json:"name"`
				Value string `json:"value"`
			} `json:"env"`
		} `json:"containers"`
	} `json:"spec"`
	Status struct {
		Phase      string `json:"phase"`
		PodIP      string `json:"podIP"`
		Conditions []struct {
			Type   string `json:"type"`
			Status string `json:"status"`
		} `json:"conditions"`
		ContainerStatuses []struct {
			Name    string `json:"name"`
			Ready   bool   `json:"ready"`
			Waiting *struct {
				Reason string `json:"reason"`
			} `json:"waiting"`
		} `json:"containerStatuses"`
	} `json:"status"`
}

func (c *client) pods(ns string, sel map[string]string) (*podList, error) {
	parts := make([]string, 0, len(sel))
	for k, v := range sel {
		parts = append(parts, k+"="+v)
	}
	sort.Strings(parts)
	q := url.Values{}
	if len(parts) > 0 {
		q.Set("labelSelector", strings.Join(parts, ","))
	}
	raw, err := c.do(http.MethodGet, fmt.Sprintf("/api/v1/namespaces/%s/pods?%s", ns, q.Encode()), "", nil)
	if err != nil {
		return nil, err
	}
	pl := &podList{}
	if err := json.Unmarshal(raw, pl); err != nil {
		return nil, err
	}
	return pl, nil
}

// readyPod returns the IP of the first Ready pod, or a reason the caller can
// log. The reason matters: "pod x waiting: ImagePullBackOff" is a different
// diagnosis from "no pods", and it is the only thing visible to whoever is
// watching a model that will not come up.
func (c *client) readyPod(ns string, sel map[string]string) (string, string, error) {
	pl, err := c.pods(ns, sel)
	if err != nil {
		return "", "", err
	}
	reason := "no pods"
	for _, p := range pl.Items {
		ready := false
		for _, cond := range p.Status.Conditions {
			if cond.Type == "Ready" && cond.Status == "True" {
				ready = true
			}
		}
		if ready && p.Status.PodIP != "" {
			return p.Status.PodIP, "", nil
		}
		reason = fmt.Sprintf("pod %s phase=%s", p.Metadata.Name, p.Status.Phase)
		for _, cs := range p.Status.ContainerStatuses {
			if cs.Waiting != nil && cs.Waiting.Reason != "" {
				reason = fmt.Sprintf("pod %s container %s waiting: %s", p.Metadata.Name, cs.Name, cs.Waiting.Reason)
			}
		}
	}
	return "", reason, nil
}

// busyCardSelector is the labelSelector the busy-card scan sends. It is set-based
// because comma-separated equality terms are a conjunction: naming both
// components that way asks for a pod that is both at once, and the API answers
// with nothing — every card then reads as free.
func busyCardSelector() string {
	return componentLabel + " in (" + strings.Join(cardOwnerComponents, ",") + ")"
}

// busyCards returns the cards held by the pods that own one - models and
// gpu-jobs - in the namespace. A card is busy from the moment a pod claiming it
// exists - not from readiness - because a loading pod already owns its card, and
// treating it otherwise is how a second wake lands on a busy card and
// crashloops. The selector asks the API for the card-owning components only;
// the rules about which of those pods actually holds what live in
// busyFromPods.
func (c *client) busyCards(ctx context.Context, ns string) (map[string]bool, error) {
	pl, err := c.cardOwnerPods(ns)
	if err != nil {
		return nil, err
	}
	return busyFromPods(pl), nil
}

// cardOwnerPods lists the pods that own a card. It is the one list two decisions
// read: placement, which wants the cards that are not free, and a reclaim, which
// wants the model that holds each card that is.
func (c *client) cardOwnerPods(ns string) (*podList, error) {
	q := url.Values{}
	q.Set("labelSelector", busyCardSelector())
	raw, err := c.do(http.MethodGet, fmt.Sprintf("/api/v1/namespaces/%s/pods?%s", ns, q.Encode()), "", nil)
	if err != nil {
		return nil, err
	}
	pl := &podList{}
	if err := json.Unmarshal(raw, pl); err != nil {
		return nil, err
	}
	return pl, nil
}

// cardsFromPods is the pure half of busyCards so the busy-card rules are
// testable without a cluster: only a card-owning component claims, terminating
// and finished pods release, spanning pods claim every card in their pool,
// empty values claim nothing.
func cardsFromPods(raw []byte) (map[string]bool, error) {
	pl := &podList{}
	if err := json.Unmarshal(raw, pl); err != nil {
		return nil, err
	}
	return busyFromPods(pl), nil
}

// busyFromPods is the rule over a list already fetched: only a card-owning
// component claims, terminating and finished pods release, spanning pods claim
// every card in their pool, empty values claim nothing.
func busyFromPods(pl *podList) map[string]bool {
	busy := map[string]bool{}
	for _, p := range pl.Items {
		if holdsNothing(p) {
			continue
		}
		for _, card := range heldCards(p) {
			busy[card] = true
		}
	}
	return busy
}

// holdsNothing reports whether a pod is out of the placement accounting.
//
// A terminating pod is out because its owner has already decided it is over.
//
// A finished pod holds nothing. This is the rule a batch job forces and a
// Deployment never raises: a Job pod that Succeeded or Failed keeps existing
// until jobHistoryLimit reaps it, while its process - and with it the VRAM the
// kernel gave that process - is already gone. Counting it would keep a card
// claimed for a job that will never run again. Unknown is deliberately NOT
// terminal: that is a node that stopped reporting, and the container there may
// still hold its card.
//
// A pod whose component is neither model nor gpu-job (the head-end, a log pod)
// is invisible: a pod that cannot hold a card must not block a wake.
func holdsNothing(p podItem) bool {
	if p.Metadata.DeletionTimestamp != nil {
		return true
	}
	switch p.Status.Phase {
	case "Succeeded", "Failed":
		return true
	}
	return !slices.Contains(cardOwnerComponents, p.Metadata.Labels[componentLabel])
}

// heldCards returns the cards a pod's process owns.
//
// The env is the card the runtime actually gave the container: for a model the
// one card placement narrowed its pool to, for a gpu-job the pool it declared
// verbatim, because nothing narrows a job's spec. The pool label is read only
// when no container names a card, so a job whose env was narrowed to one card is
// never charged for the rest of its pool.
func heldCards(p podItem) []string {
	var held []string
	for _, c := range p.Spec.Containers {
		for _, e := range c.Env {
			if e.Name == gpuEnv {
				held = append(held, splitCards(e.Value)...)
			}
		}
	}
	if len(held) == 0 {
		held = splitCards(p.Metadata.Labels[gpuPoolLabel])
	}
	return held
}

// gpuJobHolds reports whether a live gpu-job pod in the list carries the card.
// A job's claim becomes durable only once its pod exists - the rule a model's
// claim follows too - so this is what a claim waits for before letting go of the
// flock. A model on the card is not a yes here: it says the card is taken, not
// that the job's pod appeared.
func (pl *podList) gpuJobHolds(card string) bool {
	for _, p := range pl.Items {
		if holdsNothing(p) || p.Metadata.Labels[componentLabel] != componentGpuJob {
			continue
		}
		if slices.Contains(heldCards(p), card) {
			return true
		}
	}
	return false
}

// splitCards turns a card list ("0", "0,1") into its members; the empty value a
// pod that declares nothing carries yields none.
func splitCards(v string) []string {
	var out []string
	for _, card := range strings.Split(v, ",") {
		if card != "" {
			out = append(out, card)
		}
	}
	return out
}

// busyScan is the view placement needs of the cluster: which cards a live pod
// already owns. A function so that a model wake and a job claim place against
// one scan, and so the claim path is testable without an API server.
type busyScan func(context.Context) (map[string]bool, error)

// scanCards fixes the namespace for the life of one placement; the scan itself
// is what differs between a cluster and a test.
func (c *client) scanCards(ns string) busyScan {
	return func(ctx context.Context) (map[string]bool, error) { return c.busyCards(ctx, ns) }
}

// errNoFreeCard is one placement round's answer when nothing in the pool was
// free. It is not a failure to report: it is what claimCycle waits on and retries,
// and only the spent card-wait budget turns it into the error a caller sees.
var errNoFreeCard = errors.New("every card in the pool is held")

// claimRound is one holding of the flock: scan, decide, and hand the chosen card
// to onClaim while the lock is still held.
//
// onClaim is handed the instant this round got the flock. Getting it is an
// unbounded blocking wait, so a round that queued behind another shim's hold can
// start after the caller's card-wait budget expired; anything onClaim bounds from
// the claim onward measures from here, or it starts out already spent.
//
// The unlock is deferred rather than repeated at each return. onClaim runs
// whatever the entry point does to make a claim visible - apply and scale for a
// model, an exec for a job - and a panic inside it must not leave the flock held
// by a process that is still running: flock is dropped when the holder dies, so
// a live holder is every placement in the fleet wedged until something kills it.
func claimRound(ctx context.Context, lockPath string, scan busyScan, cards []string, pool, mode string,
	onClaim func(card string, claimedAt time.Time) error) (string, error) {
	lock, err := cardLock(lockPath)
	if err != nil {
		return "", fmt.Errorf("card lock: %w", err)
	}
	defer cardUnlock(lock)
	claimedAt := time.Now()

	busy, err := scan(ctx)
	if err != nil {
		return "", fmt.Errorf("scan card holders: %w", err)
	}
	chosen := chooseCard(busy, cards, pool, mode)
	if chosen == "" {
		return "", errNoFreeCard
	}
	if err := onClaim(chosen, claimedAt); err != nil {
		return "", err
	}
	return chosen, nil
}

// reclaimFunc is a waiting claim's one chance to have a card handed over rather
// than waited for. claimCycle runs it after a round found nothing free and
// before the next wait, outside the flock: holding the placement lock for the
// minutes a model's pod takes to terminate would wedge every other placement in
// the fleet to arbitrate a decision the router makes anyway.
//
// Its failure is a log line and never the claim's failure - a reclaim that did
// not happen is exactly the wait that was already happening - and it is offered
// once, because a second attempt at a card the router would not give back is a
// second model put to sleep for the same card.
//
// budget is the card-wait time left when the attempt starts, and the attempt fits
// inside it: the card wait is the term the router's wake deadline was summed
// from, so a reclaim that outlives it is a wake the router aborts.
type reclaimFunc func(ctx context.Context, budget time.Duration) error

// claimCycle is the choose-and-claim cycle every entry point shares: rounds of
// claimRound until one hands over a card, with the card-wait budget as the only
// thing that turns "nothing free yet" into a failure. That budget bounds the wait
// for a card and nothing after it: a round that got the flock finishes its claim,
// from the instant it got it.
//
// onClaim must make the claim visible to the next shim's scan before it returns -
// for a model the pod the scale produces, for a job the pod the caller's create
// command produces - and the flock goes back the moment it has, on the way out of
// a failure, a panic or a success alike.
//
// reclaim is the one attempt to have a busy card handed over rather than waited
// for; nil, which is what a model wake passes, means this claim only waits.
func claimCycle(ctx context.Context, lockPath string, scan busyScan, cards []string, pool, mode string,
	wait, poll time.Duration, reclaim reclaimFunc, onClaim func(card string, claimedAt time.Time) error) (string, error) {
	deadline := time.Now().Add(wait)
	asked := false
	for {
		chosen, err := claimRound(ctx, lockPath, scan, cards, pool, mode, onClaim)
		if chosen != "" {
			return chosen, nil
		}
		if err != nil && !errors.Is(err, errNoFreeCard) {
			return "", err
		}
		// Nothing free. Before this claim joins the shims waiting for a card to
		// free itself, it spends its one reclaim attempt - paid out of the same
		// card-wait budget, because that wait is the term the router's wake
		// deadline was summed from.
		if reclaim != nil && !asked {
			asked = true
			if rerr := reclaim(ctx, time.Until(deadline)); rerr != nil {
				log.Printf("reclaim: %v", rerr)
			}
		}
		if time.Now().After(deadline) {
			return "", fmt.Errorf("no free card in pool %q after %s: every card in the pool is held by a model or a job that has not finished; retry when one releases", pool, wait)
		}
		log.Printf("all cards in pool %q busy; waiting for one to free (budget %s)", pool, wait)
		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case <-time.After(poll):
		}
	}
}

// podWait is what the lock-hold window after a scale answers: whether the
// Deployment produced a pod, and when it did not, what the wake owes the fleet.
// The endings are data rather than control flow so the release decision is
// testable without a cluster, and wake() has one place that gives a card back.
type podWait struct {
	appeared bool
	// release is why the card this wake scaled up must go back now, already
	// worded for an operator; nil means the card stays claimed — the pod may still
	// arrive, or this process is going away and the next wake adopts whatever the
	// Deployment reached.
	release error
}

// awaitPodVisible is the window between a scale and a visible pod, with the
// "has it appeared yet" probe injected so its endings are testable without an
// API server. It ends at the earliest of: the pod existing, the caller going
// away, the pod-visibility window, and the card-wait budget counted from the
// instant the round claimed the card.
//
// The budget is the only ending that releases: --card-wait is the most anyone is
// promised a card, and a Deployment that has produced no pod by the end of it is
// a card held for nothing. The window ending without release is not a verdict — a
// Deployment whose pods take longer than the window to appear is a cluster
// problem, the pod may still be coming, and waitReady is where the caller learns
// about it.
//
// Nor is the caller going away: a cancelled context here is this process dying,
// and SIGTERM means llama-swap is going away, not that this model should be
// (cmdServe). A Deployment at one replica is what the next wake adopts; scaling it
// on the way out is how a head-end restart puts a healthy model to sleep mid-wake.
func awaitPodVisible(ctx context.Context, window, poll time.Duration, budgetDeadline time.Time,
	probe func() (bool, error)) podWait {
	windowEnds := time.Now().Add(window)
	for {
		if has, err := probe(); err == nil && has {
			return podWait{appeared: true}
		}
		if !time.Now().Before(budgetDeadline) {
			return podWait{release: errors.New("no pod appeared before the card-wait budget ran out")}
		}
		if !time.Now().Before(windowEnds) {
			return podWait{}
		}
		select {
		case <-ctx.Done():
			return podWait{}
		case <-time.After(poll):
		}
	}
}

// wakeCluster is everything a wake asks the cluster for. An interface so that the
// endings of a wake — which of them scale the Deployment down and which leave it
// at one — are testable without an API server: that rule lives in wake's own
// control flow, where a test of the extracted helpers cannot reach it.
type wakeCluster interface {
	getDeployment(ns, name string) (*deployment, error)
	podsForDeployment(ns string, sel map[string]string) (bool, error)
	readyPod(ns string, sel map[string]string) (ip, reason string, err error)
	applyDeployment(ns, name, gpu string, spec []byte, existing *deployment) error
	scale(ns, name string, replicas int) (bool, error)
	scanCards(ns string) busyScan
}

var _ wakeCluster = (*client)(nil)

// awaitDeploymentPod holds the flock until the Deployment has produced a pod,
// bounded as awaitPodVisible describes; budgetDeadline is counted from the
// instant the round claimed the card, not from the instant the wake began.
func awaitDeploymentPod(ctx context.Context, kc wakeCluster, ns, name string, window time.Duration, budgetDeadline time.Time) podWait {
	return awaitPodVisible(ctx, window, podClaimPoll, budgetDeadline, func() (bool, error) {
		d, err := kc.getDeployment(ns, name)
		if err != nil || d == nil {
			return false, err
		}
		return kc.podsForDeployment(ns, d.Selector)
	})
}

// cardReleaser is the one Deployment write a release needs. An interface so the
// release paths are testable without a cluster: what a release has to get right
// is which Deployment ends at zero replicas, and a fake answers with the replica
// counts it changed.
type cardReleaser interface {
	scale(ns, name string, replicas int) (bool, error)
}

var _ cardReleaser = (*client)(nil)

// giveBackCard is the release every path that has already made a claim visible
// shares: scale the Deployment that owns the pod to zero, so the next shim's
// busy-card scan sees the card free, and return the error the operator reads.
//
// The card is named in both outcomes because they differ in the worst way: a
// released card means one model is down, a failed release means a card is out of
// the fleet — on a two-card host half its capacity — until someone scales it by
// hand. So the failure says so, and says what to do.
func giveBackCard(kc cardReleaser, ns, name, card string, cause error) error {
	_, rerr := kc.scale(ns, name, 0)
	if rerr != nil {
		return fmt.Errorf("gpu %s is still held by %s/%s (%v); releasing it failed: %w — scale %s to 0 by hand",
			card, ns, name, cause, rerr, name)
	}
	return fmt.Errorf("released gpu %s claimed by %s: %w", card, name, cause)
}

// awaitJobPod holds the flock until a gpu-job pod carrying the card is visible,
// and reports whether it ever was; the error is the last scan failure, which is
// a different diagnosis from "the pod never appeared". Same rule as a model's
// claim: until the pod exists the card reads as free to the next shim. After the
// window a claim that produced no pod simply is not a claim - nothing was written
// to the cluster, so nothing holds the card.
func (c *client) awaitJobPod(ctx context.Context, ns, card string, window time.Duration) (bool, error) {
	deadline := time.Now().Add(window)
	var lastErr error
	for time.Now().Before(deadline) {
		pl, err := c.pods(ns, map[string]string{componentLabel: componentGpuJob})
		if err == nil && pl.gpuJobHolds(card) {
			return true, nil
		}
		lastErr = err
		select {
		case <-ctx.Done():
			return false, lastErr
		case <-time.After(podClaimPoll):
		}
	}
	return false, lastErr
}

// chooseCard is the placement decision, pure so it is testable without a
// cluster: an any-mode model takes the first free card of its pool, an all-mode
// (spanning) model takes the pool only when every card in it is free. An empty
// answer means nothing is free, and wake() waits under the flock rather than
// failing fast: a busy card is a temporary condition and the request should
// outlive it. A card held by a gpu-job refuses exactly as one held by a model
// does - the two categories differ in who created them, not in what they block.
func chooseCard(busy map[string]bool, cards []string, pool, mode string) string {
	if mode == "all" {
		for _, card := range cards {
			if busy[card] {
				return ""
			}
		}
		return pool
	}
	for _, card := range cards {
		if !busy[card] {
			return card
		}
	}
	return ""
}

// ---- reclaiming a card from an idle model ----------------------------------

// stateIdle is the one router state a card may be reclaimed from. prefill,
// decode and loading each have a request in flight or about to be, and taking a
// card out of one of them is preemption, which this fleet does not do. A state
// this binary has never seen is refused for the same reason it is unknown.
const stateIdle = "idle"

// reclaimCandidate is one loaded model a waiting job may take a card from.
type reclaimCandidate struct {
	model string
	card  string
	cost  int64
}

// reclaimPlan is one reclaim decision: the card to ask the router for, and why
// each card that could not be reclaimed was not. The reasons come out of the
// same pass as the decision, so the line the claim logs cannot disagree with
// the rule that refused the card.
type reclaimPlan struct {
	target  reclaimCandidate
	ok      bool
	refused []string
}

// planReclaim is the reclaim decision, pure so the ranking and both refusals are
// testable without a cluster or a router: of the cards the pool holds, only a
// model the router itself reports idle is a candidate, and only one this host
// measured a cost for. The lowest cost wins; a tie goes to the earlier card of
// the pool, so two claims deciding at the same instant choose the same card
// instead of each choosing a victim.
//
// holders maps a card to the model that holds it, or to the empty string when a
// live card owner is not a named model; states is the router's answer, and a
// model absent from it is not running as far as the router is concerned. A card
// nothing holds is not the reclaim's business: it is free, and the next
// placement round takes it.
func planReclaim(pool []string, holders, states map[string]string, costs map[string]int64) reclaimPlan {
	plan := reclaimPlan{}
	for _, card := range pool {
		model, held := holders[card]
		if !held {
			plan.refused = append(plan.refused, fmt.Sprintf("gpu %s is free", card))
			continue
		}
		if model == "" {
			plan.refused = append(plan.refused, fmt.Sprintf("gpu %s is held by a card owner that is not a named model", card))
			continue
		}
		if state := states[model]; state != stateIdle {
			if state == "" {
				state = "not in the router's running list"
			}
			plan.refused = append(plan.refused, fmt.Sprintf("gpu %s: %s is %s", card, model, state))
			continue
		}
		cost, measured := costs[model]
		if !measured {
			// An unmeasured cost is not a cheap card. It is a card nobody has
			// agreed what it costs to take, which is the one thing a reclaim may
			// not guess at.
			plan.refused = append(plan.refused, fmt.Sprintf("gpu %s: %s declares no reclaim cost", card, model))
			continue
		}
		if plan.ok && cost >= plan.target.cost {
			continue
		}
		plan.target, plan.ok = reclaimCandidate{model: model, card: card, cost: cost}, true
	}
	return plan
}

// reclaimHolders is the reclaim's view of a pod list: the model that holds each
// card. A card two pods hold, or one a gpu-job holds, or one a model pod that
// names no model holds, maps to the empty string - the reclaim takes a card from
// one named model, and "something is on that card" is not a model to unload.
func reclaimHolders(pl *podList) map[string]string {
	holders := map[string]string{}
	for _, p := range pl.Items {
		if holdsNothing(p) {
			continue
		}
		name := ""
		if p.Metadata.Labels[componentLabel] == componentModel {
			name = p.Metadata.Labels[appNameLabel]
		}
		for _, card := range heldCards(p) {
			holder := name
			if prev, seen := holders[card]; seen && prev != holder {
				holder = "" // two owners, or an owner and a job: no single model to unload
			}
			holders[card] = holder
		}
	}
	return holders
}

// cardLock serialises placement across every shim in the head-end pod. The
// race it closes is real: two wakes deciding at the same moment see the same
// free card, and the losing pod lands on a busy card - the exact crashloop the
// first cutover produced. The lock must be held until the chosen pod EXISTS in
// the API (a scaled Deployment takes seconds to produce a visible pod), not
// just until the scale call returns; only then is the claim visible to the
// next shim's busy-card scan. flock, not a lock file: the kernel releases it
// if the holder dies, so a crashed shim cannot wedge the fleet's placement.
func cardLock(path string) (*os.File, error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		f.Close()
		return nil, err
	}
	return f, nil
}

func cardUnlock(f *os.File) {
	if f == nil {
		return
	}
	syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	f.Close()
}

// podsForDeployment reports whether the Deployment has at least one pod (any
// state, including terminating: the claim only has to be visible). Used both
// for adoption (a pod means a card is already claimed for this model) and for
// the lock-hold window after scaling.
func (c *client) podsForDeployment(ns string, sel map[string]string) (bool, error) {
	pl, err := c.pods(ns, sel)
	if err != nil {
		return false, err
	}
	return len(pl.Items) > 0, nil
}

func (c *client) listManaged(ns string) ([]string, error) {
	raw, err := c.do(http.MethodGet,
		fmt.Sprintf("/apis/apps/v1/namespaces/%s/deployments?labelSelector=%s%%3D%s",
			ns, managedLabel, managedBy), "", nil)
	if err != nil {
		return nil, err
	}
	var list struct {
		Items []struct {
			Metadata struct {
				Name string `json:"name"`
			} `json:"metadata"`
		} `json:"items"`
	}
	if err := json.Unmarshal(raw, &list); err != nil {
		return nil, err
	}
	out := make([]string, 0, len(list.Items))
	for _, i := range list.Items {
		out = append(out, i.Metadata.Name)
	}
	return out, nil
}

// ---- commands --------------------------------------------------------------

type options struct {
	namespace, model, listen, checkPath, specDir, apiServer, tokenFile, caFile string
	port                                                                       int
	// job, gpuPool, gpuMode and jobCmd are the claim's: a job that is not a model
	// has no spec ConfigMap to read its pool from, so the pool, the mode and the
	// name it is attributed by arrive as flags, and the command it runs is what
	// makes the claim outlive the decision.
	job, gpuPool, gpuMode, cardLock string
	jobCmd                          []string
	// routerURL is the llama-swap API a waiting claim asks for a card, and empty
	// means the claim only waits. It is a flag and not a default because the port
	// is a value of the chart's, and a shim that guesses it reclaims through a URL
	// nothing agreed to.
	routerURL string
	// reclaimDeadline bounds "the router took the unload" until "the reclaimed
	// model's pod is gone". It is paid out of --card-wait, because that wait is
	// the term the router's wake deadline was summed from.
	reclaimDeadline time.Duration
	// cmdPid is llama-swap's ${PID}: the pid of the serve process it is
	// stopping. cmdStop is responsible for stopping the cmd process itself
	// (internal/process/process_command.go: sendStopSignal runs CmdStop and
	// returns without touching the tree), so stop without a pid can only
	// scale - useful by hand, not enough for the swapper.
	cmdPid                                       int
	poll, startupTimeout, stopDeadline, cardWait time.Duration
	// Set by --pod-claim-window and by nothing else; see its flag for why.
	podClaimWindow time.Duration
}

func main() {
	log.SetFlags(log.Ltime)
	if len(os.Args) < 2 {
		log.Fatalf("usage: swapk8s serve|start|stop|claim|reap [flags]")
	}
	cmd := os.Args[1]
	fs := flag.NewFlagSet(cmd, flag.ExitOnError)
	o := &options{}
	fs.StringVar(&o.namespace, "namespace", "default", "namespace holding the model Deployments")
	fs.StringVar(&o.model, "model", "", "llama-swap model ID (also the Deployment name)")
	fs.StringVar(&o.listen, "listen", "127.0.0.1:0", "address to proxy the backend on (serve)")
	fs.IntVar(&o.port, "port", 8080, "backend container port")
	fs.StringVar(&o.checkPath, "health-path", "/health", "backend path that answers once the model serves")
	fs.StringVar(&o.specDir, "spec-dir", "/etc/swapk8s/specs", "directory of <model>.json pod specs from the chart")
	fs.DurationVar(&o.poll, "poll", time.Second, "cluster poll interval")
	fs.DurationVar(&o.startupTimeout, "startup-timeout", 10*time.Minute, "wait for a pod to become ready this long; a wake that placed the pod releases its card when it expires")
	fs.DurationVar(&o.cardWait, "card-wait", 5*time.Minute, "wait for a free GPU this long; it bounds the wait for a card, not the wake that follows one")
	// The window a placement holds the flock for its own scale to produce a pod.
	// The claim is the pod, so releasing before it exists lets the next shim place
	// on the same card; holding indefinitely lets a cluster problem wedge every
	// placement in the fleet. Bounded, and a timeout is a log line: the pod, if it
	// is coming, still arrives.
	fs.DurationVar(&o.podClaimWindow, "pod-claim-window", 0, "hold the placement lock this long for a scale to produce a pod; required, because the router's wake deadline is summed from this value")
	fs.DurationVar(&o.stopDeadline, "stop-deadline", 5*time.Minute, "hard bound on stop; it must never block the router")
	fs.IntVar(&o.cmdPid, "pid", 0, "pid of the serve process to stop (llama-swap substitutes ${PID})")
	fs.StringVar(&o.apiServer, "api-server", "", "kube API base (default: in-cluster)")
	fs.StringVar(&o.tokenFile, "token-file", "", "bearer token file (default: in-cluster)")
	fs.StringVar(&o.caFile, "ca-file", "", "CA bundle (default: in-cluster)")
	fs.StringVar(&o.cardLock, "card-lock", cardLockPath, "flock file placement serialises on; it is only the same lock if the path is")
	fs.StringVar(&o.job, "job", "", "name a card claim is attributed to (claim)")
	fs.StringVar(&o.gpuPool, "gpu-pool", "", `card pool a job may run on: "0", "1", "0,1" (claim)`)
	fs.StringVar(&o.gpuMode, "gpu-mode", "any", `"any" free card of the pool, "all" every card of it (claim)`)
	fs.StringVar(&o.routerURL, "router-url", "", "llama-swap API a claim reclaims a busy card through, e.g. http://127.0.0.1:8080 from inside the head-end pod; empty means a claim whose pool is full only waits (claim)")
	fs.DurationVar(&o.reclaimDeadline, "reclaim-deadline", 2*time.Minute, "wait this long for the reclaimed model's pod to go away after the router took the unload; it is paid out of --card-wait, and a stop still running when it expires is left to a human")
	if err := fs.Parse(os.Args[2:]); err != nil {
		log.Fatal(err)
	}
	// A claim has no model: it is the entry point for a job that never enters the
	// roster, which is the reason it exists.
	if cmd != "reap" && cmd != "claim" && o.model == "" {
		log.Fatal("--model is required")
	}
	// A wake's worst case is the card wait, then this window, then the load, and
	// healthCheckTimeout is that sum: a shim that runs with a window nobody budgeted
	// puts a model seconds from Ready back to sleep (awaitPodVisible).
	if cmd != "reap" && cmd != "stop" && o.podClaimWindow <= 0 {
		log.Fatal("--pod-claim-window is required: the head-end config sums it into the router's wake deadline, so the chart supplies it and an invented default here is a wake the router aborts")
	}
	o.jobCmd = fs.Args()

	kc, err := newClient(o.apiServer, o.tokenFile, o.caFile)
	if err != nil {
		log.Fatalf("client: %v", err)
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	var runErr error
	switch cmd {
	case "serve":
		runErr = cmdServe(ctx, kc, o)
	case "start":
		runErr = cmdStart(ctx, kc, o)
	case "stop":
		// stop runs with a deadline derived from its own flag, not the caller's
		// context: see cmdStop for why blocking here is the worst failure mode.
		runErr = cmdStop(kc, o)
	case "claim":
		runErr = cmdClaim(ctx, kc, o)
	case "reap":
		runErr = cmdReap(kc, o)
	default:
		log.Fatalf("unknown command %q", cmd)
	}
	if runErr != nil {
		log.Print(runErr)
		// A claim's command failing is the job failing, and its exit code is the
		// answer the caller acts on: a nightly that found no card and one that was
		// killed are different incidents, and a Job retries them differently.
		var ee *exec.ExitError
		if errors.As(runErr, &ee) && ee.ExitCode() > 0 {
			os.Exit(ee.ExitCode())
		}
		os.Exit(1)
	}
}

// wake brings the model up: apply the chart's spec if we have one, create the
// Deployment if it does not exist, scale to one, wait for a Ready pod.
func wake(ctx context.Context, kc wakeCluster, o *options) (*deployment, error) {
	name := o.model
	cur, err := kc.getDeployment(o.namespace, name)
	if err != nil {
		return nil, err
	}

	// ADOPTION: a Deployment that already has a pod - running, loading, or
	// crashlooping - has already claimed its card, and its applied spec already
	// carries the resolved card (the spec ConfigMap's copy still has the pool;
	// patching with it would UN-resolve placement for a live pod). So a pod
	// means: do not touch the spec, do not re-place, just make sure it is at
	// one and wait. This is also the head-end-restart path: a roster model
	// orphaned at replicas=1 by a dead head-end is adopted, not evicted.
	if cur != nil {
		if has, err := kc.podsForDeployment(o.namespace, cur.Selector); err == nil && has {
			changed, err := kc.scale(o.namespace, name, 1)
			if err != nil {
				return nil, fmt.Errorf("scale up: %w", err)
			}
			if changed {
				log.Printf("adopted %s: pod already claimed its card, left spec untouched", name)
			} else {
				log.Printf("adopted %s: already running", name)
			}
			// No release here however long the pod takes: the pod predates this wake,
			// and a wake that did not place it is not the thing that decides to put it
			// to sleep — cmdStop and cmdReap are.
			return cur, waitReady(ctx, kc, o, cur.Selector)
		}
	}

	// FRESH PLACEMENT. The spec arrives with the card POOL; the shim narrows it
	// to a card no existing holder - model or gpu-job - claims, or waits for one,
	// or fails with a reason a client can act on. The chart's spec is applied only here, on the
	// way up: patching a Deployment while it serves would roll the pod out from
	// under a router that believes it has a healthy backend, so a chart change
	// takes effect on the next wake after sleep. That staleness is bounded by
	// one idle timeout, same as the model's own image.
	spec, err := os.ReadFile(o.specDir + "/" + name + ".json")
	if err != nil {
		if os.IsNotExist(err) && cur == nil {
			return nil, fmt.Errorf("no deployment %s/%s and no spec at %s/%s.json", o.namespace, name, o.specDir, name)
		}
		if !os.IsNotExist(err) {
			return nil, fmt.Errorf("read spec: %w", err)
		}
		// No spec but a Deployment exists (scaled to zero by a previous life):
		// scale without re-applying. The applied spec still carries the last
		// resolved card, which stays claimed by this model until it sleeps — and
		// this path releases none of it, because it resolved no card and so has no
		// card to name in the error an operator would have to act on.
		changed, err := kc.scale(o.namespace, name, 1)
		if err != nil {
			return nil, fmt.Errorf("scale up: %w", err)
		}
		if changed {
			log.Printf("scaled %s/%s to 1 on its existing spec", o.namespace, name)
		}
		return cur, waitReady(ctx, kc, o, cur.Selector)
	}

	// Pool and mode travel as labels on the chart-rendered spec.
	var specMeta struct {
		Metadata struct {
			Labels map[string]string `json:"labels"`
		} `json:"metadata"`
	}
	if err := json.Unmarshal(spec, &specMeta); err != nil {
		return nil, fmt.Errorf("spec for %s is not valid JSON: %w", name, err)
	}
	pool := strings.TrimSpace(specMeta.Metadata.Labels[gpuPoolLabel])
	mode := strings.TrimSpace(specMeta.Metadata.Labels[gpuModeLabel])
	if pool == "" {
		return nil, fmt.Errorf("spec for %s carries no %s label; the chart must render the card pool it declares in values", name, gpuPoolLabel)
	}
	if mode == "" {
		mode = "any"
	}
	cards := strings.Split(pool, ",")

	// The choose-and-claim cycle, under the flock, until a card is free or the
	// card-wait budget is spent. Waiting - rather than failing fast - is the
	// point of the design: the fleet is adaptive, every model has a ttl, so a
	// busy card is a temporary condition and the request should outlive it.
	// llama-swap holds the request (its queue) while the shim waits here, and
	// the client sees the loading stream.
	//
	// --card-wait bounds the wait for a card and nothing after it. The window that
	// waits for the scale to produce a pod starts from the instant this round got
	// the flock, because getting the flock blocks: anchored at the wake instead, a
	// round that queued behind another shim's hold would find its budget already
	// spent, probe once - no pod exists milliseconds after its own scale - and hand
	// the card back blaming the pod.
	chosen, err := claimCycle(ctx, o.cardLock, kc.scanCards(o.namespace), cards, pool, mode, o.cardWait, o.poll,
		// No reclaim for a model wake: taking a card off an idle model is a one-off
		// job's move, never a model's. Two models reclaiming from each other is the
		// swap storm the router's exclusive groups exist to prevent, and it is the
		// same decision that stopped coding agents from evicting each other.
		nil,
		func(card string, claimedAt time.Time) error {
			if err := kc.applyDeployment(o.namespace, name, card, spec, cur); err != nil {
				return fmt.Errorf("apply spec (gpu %s): %w", card, err)
			}
			if _, err := kc.scale(o.namespace, name, 1); err != nil {
				return fmt.Errorf("scale up: %w", err)
			}
			log.Printf("placed %s on gpu %s (pool %q, mode %s)", name, card, pool, mode)
			// Hold the lock until the pod is visible: a scaled Deployment takes
			// seconds to produce a pod, and until it exists the next shim's
			// busy-card scan would see the card as free. The claim is the pod.
			// From here the card is this wake's to give back, but only on the one
			// ending that says the pod is not coming: awaitPodVisible.
			if w := awaitDeploymentPod(ctx, kc, o.namespace, name, o.podClaimWindow, claimedAt.Add(o.cardWait)); w.release != nil {
				return giveBackCard(kc, o.namespace, name, card, w.release)
			}
			return nil
		})
	if err != nil {
		return nil, err
	}

	cur, err = kc.getDeployment(o.namespace, name)
	if err != nil || cur == nil {
		return nil, fmt.Errorf("deployment %s did not appear after placement: %v", name, err)
	}
	if err := waitReady(ctx, kc, o, cur.Selector); err != nil {
		// A startup timeout is the one ending that releases: the pod had the whole
		// timeout and the API still does not call it Ready, so it is not coming, and
		// a Deployment left at one replica holds its card until a human scales it.
		// Every other ending - this process going away, an API that never answered
		// the last poll - says nothing about the pod and leaves the Deployment at one
		// for the next wake to adopt.
		if errors.Is(err, errStartupTimeout) {
			return cur, giveBackCard(kc, o.namespace, name, chosen, err)
		}
		return cur, err
	}
	return cur, nil
}

// errStartupTimeout marks the one readiness failure a wake releases its card
// for: the pod had the whole --startup-timeout and is still not Ready. Every
// other way waitReady stops is the caller or the API, not the pod, and wake()
// releases on none of them.
var errStartupTimeout = errors.New("startup timeout")

// waitReady polls until a pod of the Deployment is Ready, the startup timeout
// ends the wait, or the caller goes away.
//
// A failed poll is the API, not the pod: a 429 from API priority-and-fairness, a
// 500 or 503 during a k3s apiserver restart, a connection reset, this client's
// own 30s timeout. A readiness wait polls once a second for the whole startup
// timeout - thousands of calls for a 27B model - so one blip is routine, and
// ending the wait on one would scale a nearly-ready pod to zero and log the pod
// as the culprit. The rule awaitPodVisible already follows, applied here.
//
// So the only error is the timeout, and it carries what the last poll saw: a pod
// state, or the fault that was still failing when the deadline passed. Only the
// first is about the pod at all, and whoever reads the line is debugging
// different things.
func waitReady(ctx context.Context, kc wakeCluster, o *options, sel map[string]string) error {
	deadline := time.Now().Add(o.startupTimeout)
	last := ""
	for {
		ip, reason, err := kc.readyPod(o.namespace, sel)
		switch {
		case err != nil:
			reason = fmt.Sprintf("cannot read pods: %v", err)
		case ip != "":
			return nil
		}
		if reason != last {
			log.Printf("not ready: %s", reason)
			last = reason
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("%w after %s: %s", errStartupTimeout, o.startupTimeout, last)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(o.poll):
		}
	}
}

// cmdServe is what llama-swap runs as a model's `cmd`. It stays alive for as
// long as the model is loaded, and its health endpoint is the readiness signal
// the router polls.
//
// The 503 on that endpoint is the contract, not a defect: it answers
// llama-swap's health-check loop (internal/process/process_command.go tags
// those requests), and the router holds client requests until it goes away.
// Nothing client-facing ever sees it.
func cmdServe(ctx context.Context, kc *client, o *options) error {
	if _, err := wake(ctx, kc, o); err != nil {
		return err
	}
	log.Printf("backend ready for %s", o.model)

	var (
		upstream *url.URL
		proxy    *httputil.ReverseProxy
		reason   = "starting"
	)
	setUpstream := func(ip string) {
		upstream, _ = url.Parse(fmt.Sprintf("http://%s:%d", ip, o.port))
		proxy = httputil.NewSingleHostReverseProxy(upstream)
		// -1 flushes every chunk: SSE has to reach the client as it is produced.
		proxy.FlushInterval = -1
		// No ResponseHeaderTimeout, and no timeout on the transport. kubeswap
		// defaults this to 300s; on this hardware a 262k-token prefill after a
		// wake is longer than that, and cutting it is a wrong answer, not a slow
		// one. The bound belongs on the client.
		proxy.Transport = &http.Transport{}
	}

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// The health path reports pod readiness, so the router's own health
		// check cannot be satisfied by a stale upstream pointer.
		isHealth := r.URL.Path == o.checkPath
		if upstream == nil {
			if !isHealth {
				log.Printf("request to a model that is not ready: %s", reason)
			}
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusServiceUnavailable)
			json.NewEncoder(w).Encode(map[string]string{"status": "not-ready", "reason": reason})
			return
		}
		if isHealth {
			http.Error(w, "ok", http.StatusOK)
			return
		}
		proxy.ServeHTTP(w, r)
	})

	// ReadHeaderTimeout only. A read or write timeout on the server would bound
	// the response body, which is the generation.
	srv := &http.Server{Handler: handler, ReadHeaderTimeout: 30 * time.Second}
	ln, err := (&net.ListenConfig{}).Listen(ctx, "tcp", o.listen)
	if err != nil {
		return fmt.Errorf("listen %s: %w", o.listen, err)
	}
	go func() {
		if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
			log.Printf("listen: %v", err)
		}
	}()
	log.Printf("proxying %s -> %s/%s", o.listen, o.namespace, o.model)

	tick := time.NewTicker(o.poll)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			// SIGTERM means llama-swap is going away, not that this model should
			// be. Scaling to zero here would take the model down with the
			// head-end; reaping is cmdReap's job, on purpose. It is the rule for
			// every cancellation in this binary, wake included: a process that is
			// only dying never releases a card, whatever the Deployment reached.
			log.Printf("signal: exiting without touching the Deployment")
			srv.Close()
			return nil
		case <-tick.C:
		}
		live, err := kc.getDeployment(o.namespace, o.model)
		if err != nil {
			log.Printf("api: %v", err)
			continue
		}
		if live == nil {
			log.Printf("deployment deleted; exiting")
			srv.Close()
			return nil
		}
		ip, why, err := kc.readyPod(o.namespace, live.Selector)
		if err != nil {
			log.Printf("pods: %v", err)
			continue
		}
		if ip == "" {
			upstream = nil
			reason = why
			continue
		}
		if upstream == nil || upstream.Hostname() != ip {
			setUpstream(ip)
			log.Printf("backend at %s:%d", ip, o.port)
		}
	}
}

// cmdStart pre-warms a model without proxying: the CLI handle for warming a
// model before a known burst of work.
func cmdStart(ctx context.Context, kc *client, o *options) error {
	_, err := wake(ctx, kc, o)
	return err
}

// cmdStop scales a model to zero — unconditionally, and always within a
// deadline.
//
// Two rules, both learned on this cluster:
//
//  1. It must not have conditions. An earlier version refused to stop a model
//     still in the roster, on the theory that a config reload calls cmdStop for
//     models it is about to re-adopt, so obeying it would sleep a model the new
//     config keeps. A reload really does call cmdStop for every loaded model, and
//     a stop that arrives is the router's decision, not advice. The conditional
//     broke the first real swap: gemma held the GPU while swift crashlooped
//     against a full card. cmdStop means stop.
//  2. It must exit. cmdStop runs on the router's reconcile path, so a stop that
//     blocks stops the whole head-end — every model, not this one. The wait for
//     pods to disappear is therefore bounded and a timeout is a log line, not a
//     failure.
func cmdStop(kc *client, o *options) error {
	ctx, cancel := context.WithTimeout(context.Background(), o.stopDeadline)
	defer cancel()

	// No conditions. An earlier version refused to stop a model that was still
	// in the roster, on the README's theory that a config reload calls cmdStop
	// for models it is about to re-adopt, so obeying it would sleep a model the
	// new config keeps. The README is wrong: at the pinned revision (v264,
	// a025e03) a reload runs cmdStop for every loaded model - --watch-config
	// polls the file, the change handler builds a new server and shuts the old
	// one down, and that shutdown stops every process (llama-swap.go reload ->
	// server.Server.Shutdown -> baseRouter.handleShutdown -> ProcessCommand.Stop
	// -> killProcess -> sendStopSignal -> this command). What a reload does not
	// do is restart the container, so readiness never flips while the fleet is
	// scaled out from under a running request - which is why the chart runs
	// llama-swap without --watch-config and turns a roster edit into a pod
	// rollout (k8s/apps/ai/templates/head-end-deployment.yaml). cmdStop is
	// called for exactly the reasons that mean it: eviction out of an exclusive
	// group, ttl expiry, unload. Making it conditional broke the first real swap
	// on this cluster - gemma held the GPU while swift crashlooped against a full
	// card. cmdStop means stop; the shim is hands, and the router is the only
	// brain in the room.
	//
	// And cmdStop owns the whole stop, process included: sendStopSignal runs
	// CmdStop and returns without ever touching the process tree, so stopping
	// the serve process is this command's job. The second bug on this cluster
	// was exactly that: stop scaled the Deployment to zero and returned, the
	// serve process kept running in its not-ready-forever loop, llama-swap's
	// process handle never closed, and the exclusive group never freed - the
	// next wake queued forever. SIGTERM the pid first; serve handles it by
	// exiting without touching the Deployment, which is why the scaling stays
	// here.
	if o.cmdPid > 0 {
		if err := syscall.Kill(o.cmdPid, syscall.SIGTERM); err != nil && err != syscall.ESRCH {
			log.Printf("SIGTERM %d: %v (scaling anyway)", o.cmdPid, err)
		} else if err == nil {
			log.Printf("sent SIGTERM to serve pid %d", o.cmdPid)
		}
		// Bounded: the process has its own shutdown path, and stop must never
		// block the router - a straggler is logged, not waited on forever.
		for i := 0; i < 100; i++ {
			if err := syscall.Kill(o.cmdPid, 0); err != nil {
				break // gone (ESRCH) or not ours (EPERM): either way, done here
			}
			select {
			case <-ctx.Done():
				i = 100
			case <-time.After(100 * time.Millisecond):
			}
		}
	}
	cur, err := kc.getDeployment(o.namespace, o.model)
	if err != nil {
		return err
	}
	if cur == nil {
		log.Printf("deployment %s/%s already gone", o.namespace, o.model)
		return nil
	}
	changed, err := kc.scale(o.namespace, o.model, 0)
	if err != nil {
		return fmt.Errorf("scale down: %w", err)
	}
	if !changed {
		log.Printf("stop is a no-op: %s is already scaled to 0", o.model)
		return nil
	}
	log.Printf("scaled %s/%s to 0", o.namespace, o.model)

	for {
		pl, err := kc.pods(o.namespace, cur.Selector)
		if err != nil {
			log.Printf("cannot confirm termination (%v); leaving the Deployment scaled to 0", err)
			return nil
		}
		if len(pl.Items) == 0 {
			log.Printf("no pods remain; VRAM and host RAM released")
			return nil
		}
		select {
		case <-ctx.Done():
			log.Printf("stop deadline reached with %d pod(s) still terminating; the kubelet will finish the job", len(pl.Items))
			return nil
		case <-time.After(o.poll):
		}
	}
}

// ---- the reclaiming claim --------------------------------------------------

// unloadRequestTimeout bounds one router request. llama-swap holds the unload
// POST open for its own unloadTimeout (10s at the pinned revision, and the chart
// renders no such key), so a client bound under that abandons a request the
// router is still working on; this sits above that default and well under the
// reclaim window it is paid from.
const unloadRequestTimeout = 30 * time.Second

// reclaimCosts reads what each model this head-end can render costs to bring
// back, off the chart-rendered specs - the same files a wake reads its card pool
// from, and the only place the cost exists once the shim consumes the label.
//
// A model with no cost is absent from the map. That is not zero: an unmeasured
// card must never rank as the cheapest one on the box.
func reclaimCosts(dir string) (map[string]int64, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("read spec dir %s: %w", dir, err)
	}
	costs := map[string]int64{}
	for _, e := range entries {
		name, isSpec := strings.CutSuffix(e.Name(), ".json")
		if e.IsDir() || !isSpec {
			continue
		}
		raw, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			return nil, fmt.Errorf("read spec %s: %w", e.Name(), err)
		}
		var spec struct {
			Metadata struct {
				Labels map[string]json.RawMessage `json:"labels"`
			} `json:"metadata"`
		}
		if err := json.Unmarshal(raw, &spec); err != nil {
			return nil, fmt.Errorf("spec %s is not valid JSON: %w", e.Name(), err)
		}
		rawCost, declared := spec.Metadata.Labels[reclaimCostLabel]
		if !declared {
			continue
		}
		cost, err := parseReclaimCost(rawCost)
		if err != nil {
			// A figure that is not a positive number of seconds is not a cost, and
			// reading one as a cost would rank this card against measured ones. The
			// model keeps its card and the line names the file to fix.
			log.Printf("spec %s: %v; %s stays unreclaimable", e.Name(), err, name)
			continue
		}
		costs[name] = cost
	}
	return costs, nil
}

// parseReclaimCost reads the label's value: a label value is a string, which is
// what the chart quotes it into, and a bare number is what a spec written by hand
// carries.
func parseReclaimCost(raw json.RawMessage) (int64, error) {
	seconds, err := strconv.ParseInt(strings.Trim(string(raw), `"`), 10, 64)
	if err != nil || seconds <= 0 {
		return 0, fmt.Errorf("%s is not a positive whole number of seconds", raw)
	}
	return seconds, nil
}

// reclaimer is a waiting job's one attempt to have the router hand a card over:
// read what each card of the pool costs to bring back, ask for the cheapest one
// whose model is idle, and wait for the pod that holds it to actually go away.
//
// The router is asked rather than the Deployment scaled, because the router is
// the one process that holds the model's connections and its queue: between "the
// scan says idle" and "the unload lands" a request can arrive, and only the
// router can tell that from an idle model at the instant the card changes hands.
// Asking it is also what leaves the reclaimed model in the roster, so its next
// request wakes it on the ordinary path and the client sees the loading stream
// instead of an error.
//
// Nothing here forces a card. A reclaim the router did not carry out is reported
// and the claim goes back to waiting under the flock, exactly as it did before
// the attempt.
type reclaimer struct {
	kc      *client
	ns      string
	pool    []string
	mode    string
	specDir string
	window  time.Duration
	poll    time.Duration
	// router is the llama-swap API base, and empty is this claim not reclaiming:
	// a claim that cannot reach the router waits, because waiting is what a claim
	// did before reclaim existed.
	router string
	hc     *http.Client
}

func newReclaimer(kc *client, o *options) *reclaimer {
	return &reclaimer{
		kc:      kc,
		ns:      o.namespace,
		pool:    splitCards(strings.TrimSpace(o.gpuPool)),
		mode:    strings.TrimSpace(o.gpuMode),
		specDir: o.specDir,
		window:  o.reclaimDeadline,
		poll:    o.poll,
		router:  strings.TrimRight(o.routerURL, "/"),
		// No credential: the router's routes are default-allow in this pod (the
		// chart renders no apiKeys), and the head-end's service account token has
		// no business leaving the kube API for a localhost proxy.
		hc: &http.Client{Timeout: unloadRequestTimeout},
	}
}

// try spends the claim's one reclaim attempt, bounded by the card-wait budget
// still left. Every way out of here is a log line and a claim that keeps waiting:
// what this returns is the reason it is still waiting, not the claim's failure.
func (r *reclaimer) try(ctx context.Context, budget time.Duration) error {
	if r.router == "" {
		return errors.New("not attempted: no --router-url, so nothing here can ask the router for a card back")
	}
	if r.mode == "all" {
		return errors.New("not attempted: a spanning claim needs every card of its pool free at once, and unloading several models to race for them is not one decision")
	}
	within := r.window
	if budget < within {
		within = budget
	}
	if within <= 0 {
		return errors.New("not attempted: the card-wait budget has no time left to wait an unload out")
	}

	costs, err := reclaimCosts(r.specDir)
	if err != nil {
		return err
	}
	pl, err := r.kc.cardOwnerPods(r.ns)
	if err != nil {
		return fmt.Errorf("scan card owners: %w", err)
	}
	states, err := r.runningStates(ctx)
	if err != nil {
		return err
	}
	plan := planReclaim(r.pool, reclaimHolders(pl), states, costs)
	if !plan.ok {
		return fmt.Errorf("no card of %s can be reclaimed: %s", strings.Join(r.pool, ","), strings.Join(plan.refused, "; "))
	}
	log.Printf("reclaim: taking gpu %s from %s, the idle card that costs least to bring back (%ds)",
		plan.target.card, plan.target.model, plan.target.cost)
	if err := r.requestUnload(ctx, plan.target.model); err != nil {
		return err
	}
	// A 200 is the router accepting the request, not the card coming back: an
	// unload it does carry out hands cmdStop to a goroutine the POST never waits
	// for, and one it does not carry out answers 200 having run nothing at all.
	// The card is back when the pod that holds it is gone.
	return r.awaitRelease(ctx, plan.target, within)
}

// awaitRelease waits out the stop the router started: the reclaimed model's pods
// are gone, not merely terminating. A pod with a deletion timestamp still holds
// its VRAM, and a job placed on it is a container waiting on a cudaMalloc that
// cannot succeed - which is the difference between this wait and the busy-card
// scan, and the reason the reclaim waits for the pod and not for the scan.
//
// The cost is latency in one case: a stop that wedges while another card frees
// itself is waited out for the window instead of taken. The next placement round
// re-scans after this returns, so the wait is bounded by the window and the
// card-wait budget, and the failure line says which one it was.
//
// A failed poll is the API, not the pod, so the loop keeps going: the rule
// waitReady follows, for the reason it gives.
func (r *reclaimer) awaitRelease(ctx context.Context, target reclaimCandidate, within time.Duration) error {
	deadline := time.Now().Add(within)
	var lastErr error
	for {
		pl, err := r.kc.pods(r.ns, map[string]string{componentLabel: componentModel, appNameLabel: target.model})
		if err == nil && len(pl.Items) == 0 {
			log.Printf("reclaim: gpu %s is free; %s sleeps and its next request wakes it", target.card, target.model)
			return nil
		}
		lastErr = err
		if !time.Now().Before(deadline) {
			return r.unreleasedCardError(target, within, lastErr)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(r.poll):
		}
	}
}

// unreleasedCardError is the outcome a human has to hear about, so it says what
// to do about it. llama-swap gives the stop command its own process group and the
// escalation SIGKILLs only the serve group, so a cmdStop that outlives
// unloadTimeout is never killed: the card is claimed by a stop that is not coming
// back, with no process holding it. Taking it anyway would be this shim writing
// .spec.replicas behind the router's back - the one field the spec ConfigMap
// exists to keep from everyone else - so the claim reports it and keeps waiting.
func (r *reclaimer) unreleasedCardError(target reclaimCandidate, within time.Duration, lastErr error) error {
	msg := fmt.Sprintf("gpu %s is still held by %s after %s: the router took the unload and the pod is still there. "+
		"A cmdStop that outlives llama-swap's unloadTimeout is never killed, so this card is claimed by a stop that is not coming back, and this claim will not take it by force. "+
		"A human decides: kubectl -n %s scale deploy/%s --replicas=0 and delete the pod that will not die",
		target.card, target.model, within, r.ns, target.model)
	if lastErr != nil {
		msg += fmt.Sprintf(" (the last look at the pod failed: %v)", lastErr)
	}
	return errors.New(msg)
}

// runningStates is the router's own answer about what is loaded and what each one
// is doing. Idle here means what llama-swap reports, not what a ttl implies: a
// model the router does not list is not running as far as the only process that
// routes it is concerned, and it is not a card to reclaim.
func (r *reclaimer) runningStates(ctx context.Context) (map[string]string, error) {
	body, err := r.routerDo(ctx, http.MethodGet, "/running")
	if err != nil {
		return nil, err
	}
	var doc struct {
		Models []struct {
			Model string `json:"model"`
			State string `json:"state"`
		} `json:"models"`
	}
	if err := json.Unmarshal(body, &doc); err != nil {
		return nil, fmt.Errorf("the router's running list is not the shape this shim reads: %w", err)
	}
	states := make(map[string]string, len(doc.Models))
	for _, m := range doc.Models {
		states[m.Model] = m.State
	}
	return states, nil
}

// requestUnload asks the router to stop one model. The response is not the
// release; awaitRelease is what says the card came back.
func (r *reclaimer) requestUnload(ctx context.Context, model string) error {
	_, err := r.routerDo(ctx, http.MethodPost, "/api/models/unload/"+url.PathEscape(model))
	return err
}

func (r *reclaimer) routerDo(ctx context.Context, method, path string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, method, r.router+path, nil)
	if err != nil {
		return nil, err
	}
	resp, err := r.hc.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%s %s: %w", method, path, err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 300 {
		return nil, fmt.Errorf("%s %s: %d %s", method, path, resp.StatusCode, brief(body))
	}
	return body, nil
}

// brief keeps an HTTP failure's body to something a log line can carry: the
// router's own error text is the diagnosis, and everything after it is noise.
func brief(body []byte) string {
	text := strings.FieldsFunc(string(body), func(r rune) bool { return r == '\n' || r == '\r' || r == '\t' })
	line := strings.Join(text, " ")
	line = strings.Join(strings.Fields(line), " ")
	runes := []rune(line)
	if len(runes) > 200 {
		return string(runes[:200]) + "…"
	}
	return line
}

// cmdClaim is how a job that is not a model gets a card: it takes the flock a
// model wake takes, chooses a card the shared scan says is free, prints it, and
// hands the pin to the command that creates the pod.
//
// When no card in the pool is free it also gets one reclaim attempt: the router is
// asked to unload the idle model whose card costs least to bring back, and the
// claim waits for that pod to go away before it places. That is reclaim and not
// preemption — a model with a request in flight is never a candidate, whatever it
// would cost to move it — and the details, including what a stop that never
// finishes leaves behind, are the reclaimer's comment.
//
// The other mechanism on the ticket was a Job the shim creates itself, from a
// spec ConfigMap, the way a model Deployment is created. Rejected, on three
// grounds. (1) This binary exists because the pod spec belongs to something
// else; a Job it creates makes it a batch controller, and parallelism,
// backoffLimit, podFailurePolicy, history limits and TTL are batch/v1's
// semantics - a partial reimplementation of them is how a nightly quietly stops
// running. (2) A Job the shim creates is released by the shim, so the claim's
// lifetime becomes a controller's lifetime, and the only long-lived process is
// the head-end: a head-end restart would then orphan or kill a running render,
// and reap - which scales everything it manages to zero - would have to learn
// job semantics. Here the claim's lifetime is the caller's process, so it ends
// when the caller ends, failure included. (3) The spec ConfigMap exists to stop
// `kubectl apply` fighting the shim over .spec.replicas, and a Job's pod
// template has no contested field: the indirection would add a second write path
// and buy nothing. The head-end Role creates one kind of Deployment and nothing
// else, so a Job needs new RBAC while a claim needs only the pod list the scan
// already reads.
//
// Release is the same two facts a model's release is: the flock is gone when this
// process exits - completion, failure and a killed caller alike - and the card
// stays claimed while the job's pod exists because the scan counts the pod, which
// is also what releases it once the pod finishes or fails. A claim whose pod never
// appeared holds nothing: nothing was written to the cluster, and the lock is off.
//
// The card leaves this process the way it enters a model's pod - as
// NVIDIA_VISIBLE_DEVICES, in the environment of the command it runs, and on
// stdout for a caller that renders a manifest. The pod spec is where the pin has
// to land, because that is where the nvidia runtime hook reads it; nothing this
// command can do to a container already created would narrow the cards inside it.
func cmdClaim(ctx context.Context, kc *client, o *options) error {
	if o.job == "" {
		return fmt.Errorf("claim: --job is required; it is the name every log line about this card is attributed to")
	}
	pool := strings.TrimSpace(o.gpuPool)
	if pool == "" {
		return fmt.Errorf("claim: --gpu-pool is required; a job that will not say which cards it may run on is a job that takes the model's card")
	}
	if len(o.jobCmd) == 0 {
		return fmt.Errorf("claim: the command that creates the pod is required (swapk8s claim --job NAME --gpu-pool POOL -- CMD); a card released before its pod exists is a card two owners can hold")
	}
	mode := strings.TrimSpace(o.gpuMode)
	if mode == "" {
		mode = "any"
	}

	chosen, err := claimCycle(ctx, o.cardLock, kc.scanCards(o.namespace), splitCards(pool), pool, mode, o.cardWait, o.poll,
		newReclaimer(kc, o).try,
		func(card string, _ time.Time) error {
			// stdout is the machine-readable answer (`card=$(swapk8s claim ...)`);
			// every diagnostic goes to the log, which is stderr. The command inherits
			// this process's stdout, so a caller whose command prints reads the card
			// from the environment instead.
			fmt.Println(card)
			if err := runClaimed(ctx, o, card); err != nil {
				return err
			}
			appeared, err := kc.awaitJobPod(ctx, o.namespace, card, o.podClaimWindow)
			if err != nil {
				log.Printf("claim %s: cannot confirm a gpu-job pod on gpu %s: %v", o.job, card, err)
			} else if !appeared {
				log.Printf("claim %s: no gpu-job pod on gpu %s appeared within %s; the card is free again",
					o.job, card, o.podClaimWindow)
			}
			return nil
		})
	if err != nil {
		return fmt.Errorf("claim %s: %w", o.job, err)
	}
	log.Printf("claim %s released gpu %s", o.job, chosen)
	return nil
}

// runClaimed runs the caller's command with the card pinned, and returns its
// failure as an error so main can hand back its exit code.
//
// The command is the thing that creates the pod, not the workload: the nvidia
// runtime hook reads NVIDIA_VISIBLE_DEVICES when the container is created, so
// pinning a process already inside one changes nothing the runtime can see.
//
// The goroutine that waits the command comes after Start succeeds, and every path
// out of this function reads its channel: a Wait nobody drains is a child nobody
// reaped.
func runClaimed(ctx context.Context, o *options, card string) error {
	cmd := exec.Command(o.jobCmd[0], o.jobCmd[1:]...)
	cmd.Env = pinChildEnv(os.Environ(), card, o.job)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start %s: %w", o.jobCmd[0], err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		if err != nil {
			return fmt.Errorf("%s on gpu %s: %w", o.jobCmd[0], card, err)
		}
		return nil
	case <-ctx.Done():
		// The caller is going away, and the command it started must not outlive
		// the claim it was made under. Bounded: a child that ignores SIGTERM must
		// not hold the fleet's placement lock forever.
		_ = cmd.Process.Signal(syscall.SIGTERM)
		select {
		case <-done:
		case <-time.After(claimKillGrace):
			_ = cmd.Process.Kill()
			// Wait is what reaps the child and ends the goroutine, and a kill is
			// not a reap: nothing else in the process reads this channel again.
			<-done
		}
		return ctx.Err()
	}
}

// pinChildEnv returns base with the chosen card pinned the way the chart pins a
// model's pod - NVIDIA_VISIBLE_DEVICES, the variable the nvidia runtime hook
// reads - plus the job name, for a caller that names the card in a field of its
// own rather than in the env. An existing value is replaced, not carried: the
// caller's env holds the POOL it was told to hand out, and a pod rendered from
// it would take every card in the pool while claiming one.
func pinChildEnv(base []string, card, job string) []string {
	out := make([]string, 0, len(base)+2)
	for _, kv := range base {
		if strings.HasPrefix(kv, gpuEnv+"=") || strings.HasPrefix(kv, jobCardEnv+"=") {
			continue
		}
		out = append(out, kv)
	}
	return append(out, gpuEnv+"="+card, jobCardEnv+"="+job)
}

// cmdReap runs at head-end startup and scales to zero every Deployment this
// binary has ever created. It is the answer to the kill criterion "an orphan
// backend survives a shim restart": reaping is driven by head-end process
// lifetime, so nothing the swapper ever created outlives it.
//
// It scales down EVERYTHING it manages, not just models that left the roster,
// because it runs only in an initContainer - i.e. only when the head-end pod is
// starting, which is the one moment when nothing it manages is legitimately
// serving. A running model at that point is an orphan by definition: the
// process that was proxying it is gone. This is what makes a head-end restart
// deterministic - the fleet restarts asleep. A roster edit reaches this pod as
// one of those restarts rather than as a config reload: the chart checksums the
// roster into the pod template and runs llama-swap without --watch-config.
//
// It scales down rather than deleting: the GPU and the RAM come back either
// way, and deleting an object the chart might still describe trades a small
// amount of clutter for a much worse failure mode.
func cmdReap(kc *client, o *options) error {
	owned, err := kc.listManaged(o.namespace)
	if err != nil {
		return err
	}
	sort.Strings(owned)
	reaped := 0
	for _, name := range owned {
		changed, err := kc.scale(o.namespace, name, 0)
		if err != nil {
			log.Printf("reap %s: %v", name, err)
			continue
		}
		if changed {
			log.Printf("reaped %s: the head-end restarted, so it sleeps", name)
			reaped++
		}
	}
	log.Printf("reap complete: %d of %d managed Deployment(s) put to sleep", reaped, len(owned))
	return nil
}
