#!/usr/bin/env bash
# Resolve the digest that belongs with an image tag, for the
# `repository:tag@digest` convention (see k8s/README.md).
#
# The digest must be the one the *runtime* resolves when it pulls the tag - the
# image INDEX digest - not a per-architecture manifest digest. Sending an
# Accept list that includes the index types is what makes Docker-Content-Digest
# come back as the index; asking for a single manifest type silently returns a
# digest that only exists on one architecture.
#
#   ./scripts/resolve-digest.sh python:3.12-alpine ghcr.io/berriai/litellm:v1.102.1
#
# Output is one `repository:tag@sha256:...` per input, so it can be pasted
# straight into a values file.
set -euo pipefail

accept='application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json'

# Without these an unreachable or firewalled registry hangs the script forever -
# a wrong answer you notice is better than a command that never returns.
curl_timeout=(--connect-timeout 5 --max-time 30)

resolve() {
  local orig_repo="$1" repo="$1" tag="$2" host realm svc tok headers first
  # Which part is a registry host, and which is the repository? Docker's own
  # rule: a leading path segment is a registry only if it contains a dot or a
  # colon, or is "localhost". Without it, `library/python` goes looking for a
  # host named "library", and a host left inside the path silently double-counts
  # on registries lenient enough to answer it.
  case "$repo" in
    docker.io/*) repo="${repo#docker.io/}" ;;
  esac
  first="${repo%%/*}"
  case "$first" in
    *.*|*:*|localhost) host="$first"; repo="${repo#*/}" ;;
    *)                 host="registry-1.docker.io" ;;
  esac
  # Docker Hub's official images live in an implicit `library/` namespace.
  if [ "$host" = "registry-1.docker.io" ] && [ "${repo#*/}" = "$repo" ]; then
    repo="library/$repo"
  fi

  # Registries advertise their token endpoint per-repository; parse it rather
  # than hard-coding one, so ghcr/quay/ghcr-mirrors all work.
  local www
  www=$(curl -sS "${curl_timeout[@]}" -I "https://$host/v2/" | tr -d '\r' | grep -i '^www-authenticate:' || true)
  realm=$(printf '%s' "$www" | sed -n 's/.*realm="\([^"]*\)".*/\1/p')
  svc=$(printf '%s' "$www" | sed -n 's/.*service="\([^"]*\)".*/\1/p')
  realm="${realm:-https://$host/token}"
  svc="${svc:-$host}"

  tok=$(curl -sS "${curl_timeout[@]}" "$realm?service=$svc&scope=repository:$repo:pull" | jq -r '.token // .access_token // empty')
  [ -n "$tok" ] || { echo "no token for $repo" >&2; return 1; }

  # The token goes to curl on a config channel, not in argv: command lines are
  # world-readable through the process list, and a pull token for a private
  # registry is worth keeping off it.
  headers=$(printf 'header = "Authorization: Bearer %s"\n' "$tok" | curl -sS "${curl_timeout[@]}" --config - \
    -D - -o /dev/null -H "Accept: $accept" "https://$host/v2/$repo/manifests/$tag")
  local digest
  digest=$(printf '%s' "$headers" | tr -d '\r' | sed -n 's/^Docker-Content-Digest: //Ip')
  # A 404 returns no digest; say which leg failed instead of emitting `@`.
  [ -n "$digest" ] || { echo "cannot resolve $orig_repo:$tag (tag missing or not readable)" >&2; return 1; }
  # Echo the reference as the caller wrote it: this tool adds a digest, it does
  # not decide whether you spell Docker Hub images `postgres` or `library/postgres`.
  printf '%s:%s@%s\n' "$orig_repo" "$tag" "$digest"
}

[ $# -ge 1 ] || { echo "usage: $0 <image:tag>..." >&2; exit 2; }
for ref in "$@"; do
  case "$ref" in
    *@*) echo "$ref already digest-pinned" >&2; continue ;;
  esac
  # The tag is what follows the last colon of the FINAL path segment: a registry
  # may carry a port, so splitting on the first colon reads localhost:5000/img:tag
  # as a host of "localhost".
  case "${ref##*/}" in
    *:*) resolve "${ref%:*}" "${ref##*:}" ;;
    *)   echo "$ref has no tag; a digest-only reference is what this script exists to fix" >&2
         exit 1 ;;
  esac
done
