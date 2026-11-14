{{- /*
Egress rules for a wiki workload that has to reach the OIDC issuer. Two pods
carry them: bookstack, and the probe in templates/oidc-egress-probe.yaml. They
must hold identical rights — a probe granted more than the pod it is testing
reports green for a path BookStack cannot take.

k3s' kube-router policy controller has no FQDN or L7 rules, so the issuer can
only be expressed as the /32 it resolves to; templates/networkpolicy.yaml
refuses a list that is empty or wider than a /32, because a NetworkPolicy egress
rule with no peer matches every destination.
*/ -}}
{{- define "wiki.egress" -}}
- to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
      podSelector:
        matchLabels:
          k8s-app: kube-dns
  ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
- to:
    - podSelector:
        matchLabels:
          app.kubernetes.io/component: database
  ports:
    - protocol: TCP
      port: {{ .Values.database.port }}
- to:
    {{- range .Values.oidc.egressCidrs }}
    - ipBlock:
        cidr: {{ . }}
    {{- end }}
  ports:
    - protocol: TCP
      port: 443
{{- end -}}

{{- /*
One Secret key, guarded against the only way it can be wrong.

`secret.keys` is the list nix builds the `bookstack` Secret from
(`services.k3s.wikiSecretKeys` in nix/services/k3s.nix), so a key referenced
here and not created there fails the render. Without the lookup the two lists
are free to disagree, and the disagreement surfaces as a pod wedged in
CreateContainerConfigError on the cluster.
*/ -}}
{{- define "wiki.secretKey" -}}
  {{- $keys := .ctx.Values.secret.keys | default (list) -}}
  {{- if not (has .key $keys) -}}
    {{- fail (printf "secretKeyRef key %q is not in secret.keys — the list nix creates the `%s` Secret from (services.k3s.wikiSecretKeys in nix/services/k3s.nix). Add it there, or stop referencing it here." .key .ctx.Values.secretName) -}}
  {{- end -}}
  {{- .key -}}
{{- end -}}
