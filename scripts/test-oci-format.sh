#!/usr/bin/env bash
# Exercise Trivy's OCI parser without a daemon or a vulnerability DB download.
set -euo pipefail
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
layout="$work/layout"; mkdir -p "$layout/blobs/sha256"
printf '{"imageLayoutVersion":"1.0.0"}' > "$layout/oci-layout"
printf '{"os":"linux","architecture":"amd64","rootfs":{"type":"layers","diff_ids":[]},"config":{"User":"65532:65532"}}' > "$work/config"
config="$(sha256sum "$work/config" | cut -d' ' -f1)"
size="$(wc -c < "$work/config" | tr -d ' ')"
cp "$work/config" "$layout/blobs/sha256/$config"
jq -nc --arg d "sha256:$config" --argjson size "$size" '{schemaVersion:2,mediaType:"application/vnd.oci.image.manifest.v1+json",config:{mediaType:"application/vnd.oci.image.config.v1+json",digest:$d,size:$size},layers:[]}' > "$work/manifest"
digest="$(sha256sum "$work/manifest" | cut -d' ' -f1)"
size="$(wc -c < "$work/manifest" | tr -d ' ')"
cp "$work/manifest" "$layout/blobs/sha256/$digest"
jq -nc --arg d "sha256:$digest" --argjson size "$size" '{schemaVersion:2,manifests:[{mediaType:"application/vnd.oci.image.manifest.v1+json",digest:$d,size:$size}]}' > "$layout/index.json"
trivy --version
trivy --cache-dir "$work/cache" image --input "$layout" --scanners secret --offline-scan --format json --output "$work/result.json"
jq -e '.ArtifactType == "container_image" and .Metadata.ImageConfig.architecture == "amd64"' "$work/result.json" >/dev/null
echo 'OK: Trivy parsed a synthetic OCI layout. Secret scan only; not a vulnerability or BuildKit test.'
