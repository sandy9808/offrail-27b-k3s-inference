#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
model_path="${MODEL_PATH:-/home/sandy007x/models/bonsai2-27b/Offrail-27B-8G.gguf}"
model_image="${MODEL_IMAGE:-docker.io/sandy007x/offrail-27b-8g:2026.10.17}"
server_image="${SERVER_IMAGE:-docker.io/sandy007x/offrail-llama-server:2026.10.20}"
k3s="/usr/local/bin/k3s"

if [[ ! -f "${model_path}" ]]; then
  printf 'Model file not found: %s\n' "${model_path}" >&2
  exit 2
fi
if ! command -v docker >/dev/null 2>&1; then
  printf 'Docker CLI is required on the target host.\n' >&2
  exit 2
fi
sudo -n "${k3s}" kubectl get nodes >/dev/null

MODEL_PATH="${model_path}" MODEL_FILE="$(basename "${model_path}")" \
  MODEL_IMAGE="${model_image}" PUSH_IMAGE=false \
  "${repo_root}/docker/build-and-push.sh"
SERVER_IMAGE="${server_image}" PUSH_IMAGE=false \
  "${repo_root}/docker/build-server-image.sh"

docker image inspect "${model_image}" "${server_image}" >/dev/null
docker save "${model_image}" | sudo -n "${k3s}" ctr images import -
docker save "${server_image}" | sudo -n "${k3s}" ctr images import -

sudo -n "${k3s}" ctr images ls | grep -F "${model_image}"
sudo -n "${k3s}" ctr images ls | grep -F "${server_image}"
