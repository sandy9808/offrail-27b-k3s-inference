#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
model_file="${MODEL_FILE:-Offrail-27B-8G.gguf}"
image="${MODEL_IMAGE:-sandy007x/offrail-27b-8g:2026.10.17}"
image_platform="linux/amd64"
model_path="${MODEL_PATH:-${repo_root}/docker/${model_file}}"
model_file="$(basename "${model_path}")"
push_image="${PUSH_IMAGE:-true}"
build_context="$(mktemp -d)"
trap 'rm -rf "${build_context}"' EXIT

if [[ ! -f "${model_path}" ]]; then
  printf 'Model file not found: %s\n' "${model_path}" >&2
  exit 2
fi

model_sha256="$(sha256sum "${model_path}" | awk '{print $1}')"
expected_sha256="${EXPECTED_MODEL_SHA256:-be2b5ce27bd4bf6125f571e994489a325b711b092315c4b874837e4649fc04ed}"
if [[ "${model_sha256}" != "${expected_sha256}" ]]; then
  printf 'SHA-256 mismatch for %s\nExpected: %s\nActual:   %s\n' \
    "${model_file}" "${expected_sha256}" "${model_sha256}" >&2
  exit 3
fi

if ! ln "${model_path}" "${build_context}/${model_file}" 2>/dev/null; then
  cp "${model_path}" "${build_context}/${model_file}"
fi
cp "${repo_root}/docker/Dockerfile.model" "${build_context}/Dockerfile.model"
docker build \
  --platform "${image_platform}" \
  --build-arg "MODEL_FILE=${model_file}" \
  --build-arg "MODEL_SHA256=${model_sha256}" \
  --tag "${image}" \
  --file "${build_context}/Dockerfile.model" \
  "${build_context}"
if [[ "${push_image}" == "true" ]]; then
  docker push "${image}"
  printf 'Pushed %s for %s (model SHA-256 %s)\n' "${image}" "${image_platform}" "${model_sha256}"
else
  printf 'Built %s for %s locally (push skipped; model SHA-256 %s)\n' \
    "${image}" "${image_platform}" "${model_sha256}"
fi
