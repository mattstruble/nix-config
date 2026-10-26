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

resolve() {
  local orig_repo="$1" repo="$1" tag="$2" host realm svc tok headers
  case "$repo" in
    docker.io/*) repo="${repo#docker.io/}" ; host="registry-1.docker.io" ;;
    */*)         host="${repo%%/*}" ;;
    *)           host="registry-1.docker.io"; repo="library/$repo" ;;
  esac

  # Registries advertise their token endpoint per-repository; parse it rather
  # than hard-coding one, so ghcr/quay/ghcr-mirrors all work.
  local www
  www=$(curl -sSI "https://$host/v2/" | tr -d '\r' | grep -i '^www-authenticate:' || true)
  realm=$(printf '%s' "$www" | sed -n 's/.*realm="\([^"]*\)".*/\1/p')
  svc=$(printf '%s' "$www" | sed -n 's/.*service="\([^"]*\)".*/\1/p')
  realm="${realm:-https://$host/token}"
  svc="${svc:-$host}"

  tok=$(curl -sS "$realm?service=$svc&scope=repository:$repo:pull" | jq -r '.token // .access_token // empty')
  [ -n "$tok" ] || { echo "no token for $repo" >&2; return 1; }

  headers=$(curl -sS -D - -o /dev/null -H "Authorization: Bearer $tok" -H "Accept: $accept" \
    "https://$host/v2/$repo/manifests/$tag")
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
    *:*) resolve "${ref%%:*}" "${ref#*:}" ;;
    *)   echo "$ref has no tag; a digest-only reference is what this script exists to fix" >&2; exit 1 ;;
  esac
done
