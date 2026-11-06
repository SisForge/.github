#!/usr/bin/env bash
# Shared by the workflow and its offline contract tests.
set -euo pipefail
artifact_error() { echo "ERROR: $*" >&2; return 1; }
plan_tags() {
  [[ "$IMAGE_NAME" =~ ^[a-z0-9]+([._-][a-z0-9]+)*$ ]] || artifact_error 'Invalid image name.' || return
  [[ "$COMMIT_SHA" =~ ^[a-f0-9]{40}$ ]] || artifact_error 'Expected a full commit SHA.' || return
  [[ "$PLATFORMS" =~ ^linux/(amd64|arm64|arm/v7)$ ]] || artifact_error 'Exactly one supported Linux platform is required; never scan only part of an index.' || return
  local tag
  printf '%s\n' "$COMMIT_SHA"
  # Legacy callers setting tag: staging must retain their former tag set.
  if [[ "$LEGACY_TAG" != latest && -n "$LEGACY_TAG" ]]; then printf '%s\n' "$LEGACY_TAG"; fi
  if [[ "$PUSH_LATEST" == true && "$LEGACY_TAG" == latest ]]; then echo latest; fi
  while IFS= read -r tag; do
    [[ -n "$tag" ]] || continue
    [[ "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || artifact_error 'Invalid additional tag.' || return
    [[ "$tag" != latest || "$PUSH_LATEST" == true ]] || artifact_error 'latest is forbidden.' || return
    printf '%s\n' "$tag"
  done < <(printf '%s\n%s\n' "$LEGACY_TAG" "$EXTRA_TAGS" | tr ', \t' '\n' | sed '/^$/d' | grep -v '^latest$' || true)
  # Check explicit extra latest independently; the default legacy tag is ignored when disabled.
  if [[ "$PUSH_LATEST" != true ]] && printf '%s' "$EXTRA_TAGS" | tr ', \t' '\n' | grep -qx latest; then
    artifact_error 'latest is forbidden.'; return 1
  fi
}
publication_allowed() {
  [[ "${PUSH_IMAGE:-false}" == true && "${EVENT_NAME:-}" != pull_request* ]]
}
verify_blob() {
  local layout="$1" digest="$2" file
  [[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]] || artifact_error 'Invalid descriptor digest.' || return
  file="$layout/blobs/sha256/${digest#sha256:}"
  [[ -f "$file" && ! -L "$file" ]] || artifact_error 'Missing image blob.' || return
  [[ "sha256:$(sha256sum "$file" | cut -d' ' -f1)" == "$digest" ]] || artifact_error 'Image blob mismatch.' || return
}
verify_layout() {
  local layout="$1" expected="$2" platform="$3" digest config blob
  [[ "$(jq -r '.imageLayoutVersion' "$layout/oci-layout")" == 1.0.0 ]] || return 1
  [[ "$(jq '.manifests | length' "$layout/index.json")" == 1 ]] || artifact_error 'Only one scanned manifest is permitted.' || return
  digest="$(jq -r '.manifests[0].digest' "$layout/index.json")"
  [[ "$expected" == "$digest" ]] || artifact_error 'Manifest identity mismatch.' || return
  verify_blob "$layout" "$digest" || return
  local manifest="$layout/blobs/sha256/${digest#sha256:}"
  [[ "$(jq -r '.mediaType' "$manifest")" == application/vnd.oci.image.manifest.v1+json ]] || artifact_error 'Expected an OCI image manifest.' || return
  jq -e '.schemaVersion == 2 and (.layers | type == "array") and (.config | type == "object")' "$manifest" >/dev/null || return
  config="$(jq -r '.config.digest' "$manifest")"
  while IFS= read -r blob; do verify_blob "$layout" "$blob" || return; done < <(jq -r '.config.digest, .layers[].digest' "$manifest")
  [[ "$(jq -r '.os + "/" + .architecture + (if .variant and .variant != "" then "/" + .variant else "" end)' "$layout/blobs/sha256/${config#sha256:}")" == "$platform" ]] || artifact_error 'Image platform mismatch.' || return
}
verify_remote() {
  local ref="$1" expected="$2" raw
  raw="$(mktemp)"
  if ! skopeo inspect --raw "$ref" > "$raw"; then rm -f "$raw"; return 1; fi
  local actual
  actual="sha256:$(sha256sum "$raw" | cut -d' ' -f1)"
  rm -f "$raw"
  [[ "$actual" == "$expected" ]] || artifact_error 'Registry manifest digest mismatch.'
}
publish_artifact() {
  publication_allowed || artifact_error 'Publication is disabled for this event.' || return
  local layout="$1" expected="$2" platform="$3" repository="$4" tags="$5" tag
  verify_layout "$layout" "$expected" "$platform" || return
  [[ "$(head -n1 "$tags")" == "$COMMIT_SHA" ]] || artifact_error 'SHA must be published first.' || return
  # No registry login or mutable tag update may bypass these identity checks.
  while IFS= read -r tag; do
    [[ "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || return 1
    [[ "$tag" != latest || "$PUSH_LATEST" == true ]] || return 1
    skopeo copy --preserve-digests "oci:$layout" "docker://$repository:$tag" || return
    verify_remote "docker://$repository:$tag" "$expected" || return
    verify_remote "docker://$repository@$expected" "$expected" || return
  done < "$tags"
}
