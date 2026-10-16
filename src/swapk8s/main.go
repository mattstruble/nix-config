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
// spec the chart rendered, scale, wait for readiness, proxy, reap.
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
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/signal"
	"sort"
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
	// The label every model pod carries (rendered by ai.modelLabels in the
	// chart): the busy-card scan selects on it so only model pods count as
	// holding cards.
	modelComponentLabel = "app.kubernetes.io/component"
	// The GPU pool and mode travel as labels on the spec the chart rendered:
	// gpu-pool is the list of cards a model may use ("0", "1", "0,1"), gpu-mode
	// is how to read it - "any" (land on one free card from the pool) or "all"
	// (a spanning model that needs every card in the pool). The chart renders
	// them from the values entry; placement is the shim's, so the contract
	// between them has to be this explicit.
	gpuPoolLabel = "ai.mestruble.dev/gpu-pool"
	gpuModeLabel = "ai.mestruble.dev/gpu-mode"
	// The env var the spec uses to pin a card, rendered from the values entry.
	// In the spec ConfigMap it carries the POOL; at placement time the shim
	// narrows it to the card it chose.
	gpuEnv = "NVIDIA_VISIBLE_DEVICES"
	// Where every shim in the head-end pod serialises placement. /tmp is the
	// one writable path the head-end pod mounts for the shims (an emptyDir);
	// every serve process in the pod sees the same file, and flock is the only
	// coordination that survives a holder's death.
	cardLockPath = "/tmp/swapk8s-cards.lock"
)

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
	Items []struct {
		Metadata struct {
			Name              string `json:"name"`
			DeletionTimestamp any    `json:"deletionTimestamp"`
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
	} `json:"items"`
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

// busyCards returns the cards held by model pods in the namespace. A card is
// busy from the moment a pod claiming it exists - not from readiness - because
// a loading pod already owns its card, and treating it otherwise is how a
// second wake lands on a busy card and crashloops. Terminating pods are
// excluded: their card is going back on its own.
func (c *client) busyCards(ctx context.Context, ns string) (map[string]bool, error) {
	q := url.Values{}
	q.Set("labelSelector", modelComponentLabel+"=model")
	raw, err := c.do(http.MethodGet, fmt.Sprintf("/api/v1/namespaces/%s/pods?%s", ns, q.Encode()), "", nil)
	if err != nil {
		return nil, err
	}
	return cardsFromPods(raw)
}

// cardsFromPods is the pure half of busyCards so the busy-card rules are
// testable without a cluster: terminating pods release, spanning pods claim
// every card in their pool, empty values claim nothing.
func cardsFromPods(raw []byte) (map[string]bool, error) {
	pl := &podList{}
	if err := json.Unmarshal(raw, pl); err != nil {
		return nil, err
	}
	busy := map[string]bool{}
	for _, p := range pl.Items {
		if p.Metadata.DeletionTimestamp != nil {
			continue
		}
		for _, c := range p.Spec.Containers {
			for _, e := range c.Env {
				if e.Name == gpuEnv {
					for _, card := range strings.Split(e.Value, ",") {
						if card != "" {
							busy[card] = true
						}
					}
				}
			}
		}
	}
	return busy, nil
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
	// cmdPid is llama-swap's ${PID}: the pid of the serve process it is
	// stopping. cmdStop is responsible for stopping the cmd process itself
	// (internal/process/process_command.go: sendStopSignal runs CmdStop and
	// returns without touching the tree), so stop without a pid can only
	// scale - useful by hand, not enough for the swapper.
	cmdPid                                       int
	poll, startupTimeout, stopDeadline, cardWait time.Duration
}

func main() {
	log.SetFlags(log.Ltime)
	if len(os.Args) < 2 {
		log.Fatalf("usage: swapk8s serve|start|stop|reap [flags]")
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
	fs.DurationVar(&o.startupTimeout, "startup-timeout", 10*time.Minute, "give up waiting for readiness after this")
	fs.DurationVar(&o.cardWait, "card-wait", 5*time.Minute, "give up waiting for a free GPU after this")
	fs.DurationVar(&o.stopDeadline, "stop-deadline", 5*time.Minute, "hard bound on stop; it must never block the router")
	fs.IntVar(&o.cmdPid, "pid", 0, "pid of the serve process to stop (llama-swap substitutes ${PID})")
	fs.StringVar(&o.apiServer, "api-server", "", "kube API base (default: in-cluster)")
	fs.StringVar(&o.tokenFile, "token-file", "", "bearer token file (default: in-cluster)")
	fs.StringVar(&o.caFile, "ca-file", "", "CA bundle (default: in-cluster)")
	if err := fs.Parse(os.Args[2:]); err != nil {
		log.Fatal(err)
	}
	if cmd != "reap" && o.model == "" {
		log.Fatal("--model is required")
	}

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
	case "reap":
		runErr = cmdReap(kc, o)
	default:
		log.Fatalf("unknown command %q", cmd)
	}
	if runErr != nil {
		log.Fatal(runErr)
	}
}

// wake brings the model up: apply the chart's spec if we have one, create the
// Deployment if it does not exist, scale to one, wait for a Ready pod.
func wake(ctx context.Context, kc *client, o *options) (*deployment, error) {
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
			return cur, waitReady(ctx, kc, o, cur.Selector)
		}
	}

	// FRESH PLACEMENT. The spec arrives with the card POOL; the shim narrows it
	// to a card no existing model pod holds, or waits for one, or fails with a
	// reason a client can act on. The chart's spec is applied only here, on the
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
		// resolved card, which stays claimed by this model until it sleeps.
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
	deadline := time.Now().Add(o.cardWait)
	var chosen string
	for {
		lock, err := cardLock(cardLockPath)
		if err != nil {
			return nil, fmt.Errorf("card lock: %w", err)
		}
		busy, err := kc.busyCards(ctx, o.namespace)
		if err != nil {
			cardUnlock(lock)
			return nil, fmt.Errorf("scan model pods: %w", err)
		}
		if mode == "all" {
			free := true
			for _, card := range cards {
				if busy[card] {
					free = false
				}
			}
			if free {
				chosen = pool // a spanning model uses the whole pool, verbatim
			}
		} else {
			for _, card := range cards {
				if !busy[card] {
					chosen = card
					break
				}
			}
		}
		if chosen != "" {
			if err := kc.applyDeployment(o.namespace, name, chosen, spec, cur); err != nil {
				cardUnlock(lock)
				return nil, fmt.Errorf("apply spec (gpu %s): %w", chosen, err)
			}
			if _, err := kc.scale(o.namespace, name, 1); err != nil {
				cardUnlock(lock)
				return nil, fmt.Errorf("scale up: %w", err)
			}
			log.Printf("placed %s on gpu %s (pool %q, mode %s)", name, chosen, pool, mode)
			// Hold the lock until the pod is visible: a scaled Deployment takes
			// seconds to produce a pod, and until it exists the next shim's
			// busy-card scan would see the card as free. The claim is the pod.
			for i := 0; i < 120; i++ {
				if d, derr := kc.getDeployment(o.namespace, name); derr == nil && d != nil {
					if has, perr := kc.podsForDeployment(o.namespace, d.Selector); perr == nil && has {
						break
					}
				}
				select {
				case <-ctx.Done():
					cardUnlock(lock)
					return nil, ctx.Err()
				case <-time.After(500 * time.Millisecond):
				}
			}
			cardUnlock(lock)
			break
		}
		cardUnlock(lock)
		if time.Now().After(deadline) {
			return nil, fmt.Errorf("no free card in pool %q (all held) after %s: every card in the pool is serving another model; retry when one sleeps", pool, o.cardWait)
		}
		log.Printf("all cards in pool %q busy; waiting for one to free (budget %s)", pool, o.cardWait)
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(o.poll):
		}
	}

	cur, err = kc.getDeployment(o.namespace, name)
	if err != nil || cur == nil {
		return nil, fmt.Errorf("deployment %s did not appear after placement: %v", name, err)
	}
	return cur, waitReady(ctx, kc, o, cur.Selector)
}

func waitReady(ctx context.Context, kc *client, o *options, sel map[string]string) error {
	deadline := time.Now().Add(o.startupTimeout)
	last := ""
	for {
		ip, reason, err := kc.readyPod(o.namespace, sel)
		if err != nil {
			return err
		}
		if ip != "" {
			return nil
		}
		if reason != last {
			log.Printf("not ready: %s", reason)
			last = reason
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("startup timeout after %s: %s", o.startupTimeout, reason)
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
			// head-end; reaping is cmdReap's job, on purpose.
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
//     still in the roster, on the theory that a config reload makes llama-swap
//     call cmdStop for models it is about to re-adopt. The reload path never
//     calls cmdStop at all — cmdStop means eviction, ttl expiry, or unload.
//     The conditional broke the first real swap: gemma held the GPU while
//     swift crashlooped against a full card. cmdStop means stop.
//  2. It must exit. cmdStop runs on the router's reconcile path, so a stop that
//     blocks stops the whole head-end — every model, not this one. The wait for
//     pods to disappear is therefore bounded and a timeout is a log line, not a
//     failure.
func cmdStop(kc *client, o *options) error {
	ctx, cancel := context.WithTimeout(context.Background(), o.stopDeadline)
	defer cancel()

	// No conditions. An earlier version refused to stop a model that was still
	// in the roster, on the theory that a config reload makes llama-swap call
	// cmdStop for models it is about to re-adopt. That theory was the README's,
	// and the README is wrong: the reload path never calls cmdStop
	// (internal/router/base.go reloads state without touching running
	// processes). cmdStop is called for exactly the reasons that mean it:
	// eviction out of an exclusive group, ttl expiry, unload. Making it
	// conditional broke the first real swap on this cluster - gemma held the
	// GPU while swift crashlooped against a full card. cmdStop means stop; the
	// shim is hands, and the router is the only brain in the room.
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
// deterministic - the fleet restarts asleep - without touching a config reload,
// which never runs this code (the container runs --watch-config).
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
