#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")/.."
# shellcheck source=scripts/docker-artifact.sh
source scripts/docker-artifact.sh
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export IMAGE_NAME=siswrench-api COMMIT_SHA=0123456789abcdef0123456789abcdef01234567 PLATFORMS=linux/amd64
export LEGACY_TAG=latest PUSH_LATEST=true EXTRA_TAGS='' PUSH_IMAGE=true EVENT_NAME=push
plan_tags | awk '!seen[$0]++' > "$work/tags"
[[ "$(cat "$work/tags")" == "$COMMIT_SHA"$'\nlatest' ]]
PUSH_LATEST=false EXTRA_TAGS=staging plan_tags | awk '!seen[$0]++' > "$work/staging"
[[ "$(cat "$work/staging")" == "$COMMIT_SHA"$'\nstaging' ]]
[[ "$(LEGACY_TAG=staging plan_tags | awk '!seen[$0]++')" == "$COMMIT_SHA"$'\nstaging' ]]
[[ "$(LEGACY_TAG=staging EXTRA_TAGS=latest plan_tags | awk '!seen[$0]++')" == "$COMMIT_SHA"$'\nstaging\nlatest' ]]
if PUSH_LATEST=false EXTRA_TAGS=latest plan_tags > /dev/null 2>&1; then exit 1; fi
for event in pull_request pull_request_target; do
  if EVENT_NAME="$event" publication_allowed; then exit 1; fi
done
if PUSH_IMAGE=false publication_allowed; then exit 1; fi
# Construct an OCI fixture without Docker, a registry, or any external image.
layout="$work/layout"; mkdir -p "$layout/blobs/sha256"
printf '{"imageLayoutVersion":"1.0.0"}' > "$layout/oci-layout"
printf '{"os":"linux","architecture":"amd64"}' > "$work/config"
config="$(sha256sum "$work/config" | cut -d' ' -f1)"
cp "$work/config" "$layout/blobs/sha256/$config"
jq -nc --arg d "sha256:$config" '{schemaVersion:2,mediaType:"application/vnd.oci.image.manifest.v1+json",config:{mediaType:"application/vnd.oci.image.config.v1+json",digest:$d,size:37},layers:[]}' > "$work/manifest"
digest="sha256:$(sha256sum "$work/manifest" | cut -d' ' -f1)"
cp "$work/manifest" "$layout/blobs/sha256/${digest#sha256:}"
jq -nc --arg d "$digest" '{schemaVersion:2,manifests:[{mediaType:"application/vnd.oci.image.manifest.v1+json",digest:$d}]}' > "$layout/index.json"
verify_layout "$layout" "$digest" linux/amd64
if verify_layout "$layout" "sha256:$config" linux/amd64 >/dev/null 2>&1; then exit 1; fi
printf corrupt >> "$layout/blobs/sha256/$config"
if verify_layout "$layout" "$digest" linux/amd64 >/dev/null 2>&1; then exit 1; fi
cp "$work/config" "$layout/blobs/sha256/$config"
# Mock the registry boundary: wrong manifests must prevent every mutable update.
export CALLS="$work/calls"
skopeo() {
  if [[ "$1" == copy ]]; then printf '%s\n' "$*" >> "$CALLS"; else printf wrong-manifest; fi
}
if publish_artifact "$layout" "$digest" linux/amd64 ghcr.io/sisforge/test "$work/tags" >/dev/null 2>&1; then exit 1; fi
[[ "$(wc -l < "$CALLS" | tr -d ' ')" == 1 ]]
if grep -q latest "$CALLS"; then exit 1; fi
: > "$CALLS"
if EVENT_NAME=pull_request publish_artifact "$layout" "$digest" linux/amd64 ghcr.io/sisforge/test "$work/tags" >/dev/null 2>&1; then exit 1; fi
[[ ! -s "$CALLS" ]]
echo 'OK: default/legacy/staging tags, PR guard, tampered blobs/manifests and registry mismatch rejection (mock, no publication).'
