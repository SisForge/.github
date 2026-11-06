#!/usr/bin/env bash
set -euo pipefail
# Ubuntu Noble amd64 security package, fixed rather than an unbounded apt candidate.
version=1.13.3+ds1-2ubuntu0.24.04.3
if ! command -v skopeo >/dev/null || [[ "$(dpkg-query -W -f='${Version}' skopeo 2>/dev/null || true)" != "$version" ]]; then
  sudo apt-get update
  sudo apt-get install --yes --no-install-recommends "skopeo=$version"
fi
[[ "$(dpkg-query -W -f='${Version}' skopeo)" == "$version" ]]
skopeo --version
