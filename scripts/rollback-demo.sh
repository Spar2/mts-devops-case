#!/usr/bin/env bash
# Deploy a tag that is not in the registry so helm --atomic rolls back.
#
# deploy.sh sets image.api.tag and image.web.tag to that tag (default
# does-not-exist), waits, and Helm restores the previous revision when
# the rollout does not become ready. Then print helm history.
#
# Usage: rollback-demo.sh
#   BROKEN_TAG  image tag to deploy (default does-not-exist)

set -euo pipefail

if [[ $# -ne 0 ]]; then
  printf 'usage: %s\n' "${0##*/}" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tag="${BROKEN_TAG:-does-not-exist}"
if [[ ! "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
  printf 'BROKEN_TAG is not a valid image tag: %s\n' "$tag" >&2
  exit 2
fi

printf 'deploying broken tag %s via deploy.sh (image.api.tag=%s)\n' "$tag" "$tag"
printf 'helm --atomic --wait should roll release sensor back\n'

set +e
"${ROOT}/scripts/deploy.sh" "$tag"
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
  printf 'FAIL rollback-demo: deploy.sh succeeded for missing tag %s\n' "$tag" >&2
  exit 1
fi

printf 'deploy.sh exited %s\n' "$status"
helm history sensor -n sensor
