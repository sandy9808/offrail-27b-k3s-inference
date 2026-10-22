#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
docker_dir="${repo_root}/docker"
bundle_name="bonsai2-small-gpu-linux-x64-cuda12.4-sm86-sm89-285542d.tar.gz"
bundle_repo="sudoingx/Ternary-Bonsai-2-27B-PTQ1_0-MTP-GGUF"
bundle_folder="bonsai2-small-gpu-linux-x64-cuda12.4-sm86-sm89-285542d"
bundle_dir="${docker_dir}/runtime/${bundle_folder}"
image="${SERVER_IMAGE:-sandy007x/offrail-llama-server:2026.10.20}"
image_platform="linux/amd64"
build_context="$(mktemp -d)"
trap 'rm -rf "${build_context}"' EXIT

mkdir -p "${docker_dir}/runtime"
if [[ ! -x "${bundle_dir}/llama-server" ]]; then
  archive="${docker_dir}/${bundle_name}"
  if [[ ! -f "${archive}" ]]; then
    curl -fL --retry 3 \
      "https://huggingface.co/${bundle_repo}/resolve/main/${bundle_name}" \
      -o "${archive}"
  fi
  tar -xzf "${archive}" -C "${docker_dir}/runtime"
fi

if [[ ! -x "${bundle_dir}/llama-server" ]]; then
  printf 'Expected custom llama-server not found at %s\n' "${bundle_dir}/llama-server" >&2
  exit 2
fi
if [[ ! -f "${bundle_dir}/serve-8gb.sh" ]]; then
  printf 'Expected upstream serve-8gb.sh not found in %s\n' "${bundle_dir}" >&2
  exit 2
fi

mkdir -p "${build_context}/runtime"
cp -R "${bundle_dir}" "${build_context}/runtime/"
cp "${docker_dir}/Dockerfile.server" "${build_context}/Dockerfile.server"
docker build --platform "${image_platform}" --tag "${image}" --file "${build_context}/Dockerfile.server" "${build_context}"
docker push "${image}"
printf 'Pushed %s for %s using the upstream sm86/sm89 custom runtime bundle.\n' "${image}" "${image_platform}"
