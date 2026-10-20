# Offrail 27B on K3s — Ansible migration project

This is a separate deployment project for running the Offrail GGUF model in K3s. It preserves the existing Odysseus URL (`http://127.0.0.1:8899`) by using host networking. The old host process is stopped only when the operator explicitly enables `cutover_legacy_llama`.

## Architecture

- Model image: `docker.io/sandy007x/offrail-27b-8g:2026.10.17`, containing the GGUF and a small shell runtime used to stage the model.
- Inference image: `docker.io/sandy007x/offrail-llama-server:2026.10.20`, built from the upstream CUDA 12.4 sm86/sm89 Bonsai runtime bundle required by this PTQ1_0 model.
- K3s deployment: one replica, one NVIDIA GPU, model on a PVC, `hostNetwork: true`.
- Host endpoint: `http://127.0.0.1:8899` (host-local; the model binds to loopback).

The deployment uses `hostNetwork` because Odysseus runs on the target host and requires loopback access. The default server bind address is `127.0.0.1`, keeping port 8899 local to the target host. The upstream `serve/8gb.sh` uses port `8899`, `-c 65536`, full GPU offload, flash attention, and q4_0 K/V cache; this project mirrors those model arguments. Its upstream comment says the 8 GB row is pending measurement, so verify free VRAM on this host before relying on 64K context, especially if the GPU also drives a display.

## Prerequisites

- Ansible on the controller and SSH access to `sandy007x@192.168.1.148`.
- NVIDIA driver and a K3s-compatible NVIDIA container runtime on the target. The `nvidia` RuntimeClass must exist if `offrail_runtime_class` is non-empty.
- K3s already installed, or install it using the explicit option below.
- Docker on the controller and Docker Hub credentials for `sandy007x` to build and publish the model image.
- Approximately 8 GiB for the model PVC plus image-layer storage; sufficient free GPU VRAM for the 27B quantization, context, and runtime overhead.

The preflight checks SSH, NVIDIA visibility, and Docker on the controller. Run the full GPU audit before cutover:

```bash
cd /Users/sandeep383.kumar/Desktop/Misc/offrail-27b-k3s-ansible
ansible-playbook playbooks/audit_nvidia.yml --ask-pass --ask-become-pass
```

This project does not store SSH credentials. Enter them at the runtime prompts:

```bash
ansible-playbook playbooks/preflight.yml --ask-pass --ask-become-pass
```

## Build and publish the model image

Place the exact GGUF file at `docker/Offrail-27B-8G.gguf`. The default expected SHA-256 is recorded in `group_vars/all.yml`; the script refuses to publish a different file. Authenticate first, then build and push:

```bash
cd /Users/sandeep383.kumar/Desktop/Misc/offrail-27b-k3s-ansible
docker login -u sandy007x
./docker/build-and-push.sh
```

Build and push the matching custom runtime. The generic upstream `llama.cpp` image does not provide the Bonsai/PrismML PTQ1_0 support required by this model.

```bash
docker login -u sandy007x
./docker/build-server-image.sh
```

To publish a deliberately updated model, set `EXPECTED_MODEL_SHA256`, `MODEL_FILE`, and `MODEL_IMAGE`, then update `offrail_model_sha256`, `offrail_model_file`, and `offrail_model_image` in `group_vars/all.yml` to the same values. Never put a Docker Hub token in this repository.

## Deploy

First ensure the image is published and K3s GPU scheduling works. If K3s is installed but stopped, start it explicitly:

```bash
ansible-playbook playbooks/install_k3s.yml -e start_k3s=true --ask-pass --ask-become-pass
```

If K3s is absent, install it explicitly:

```bash
ansible-playbook playbooks/install_k3s.yml -e install_k3s=true
```

The GPU Operator must be installed and healthy before deploying the model. This project installs the Operator (configured not to replace the working host driver), which installs/configures the toolkit and device plugin for K3s. The old hand-written device-plugin DaemonSet is not a GPU Operator and has been removed.

Audit the host and cluster first. The audit checks host `nvidia-smi`, NVIDIA Container Toolkit, K3s runtime config, operator resources, model health, and by default runs an NVIDIA CUDA vector-add Pod and deletes it afterward:

```bash
ansible-playbook playbooks/audit_nvidia.yml --ask-pass --ask-become-pass
```

Install or reconcile the Operator after confirming host `nvidia-smi` succeeds and K3s is healthy:

```bash
ansible-playbook playbooks/install_nvidia_gpu_operator.yml \
  --ask-pass --ask-become-pass
```

The install requires Helm on the target. It leaves the host-installed NVIDIA driver in place (`driver.enabled=false`), configures the K3s containerd paths, waits for the GPU Operator ClusterPolicy, and requires K3s to advertise `nvidia.com/gpu` before succeeding.

The cutover stops the existing host llama-server before starting the pod on port 8899. Run it only after publishing both the model image and custom server image, and confirming the GPU audit passes:

```bash
ansible-playbook playbooks/deploy_offrail.yml \
  -e cutover_legacy_llama=true \
  --ask-pass --ask-become-pass
```

The deploy playbook refuses cutover unless the node advertises an allocatable NVIDIA GPU and the configured `RuntimeClass` exists. It waits for rollout, checks `/health`, then restarts Odysseus. It preserves the legacy model files as a rollback copy.

## Operations

```bash
ssh sandy007x@192.168.1.148
sudo k3s kubectl -n offrail get pods,pvc
sudo k3s kubectl -n offrail logs deployment/offrail-27b -c llama-server -f
curl -fsS http://127.0.0.1:8899/health
curl -fsS http://127.0.0.1:8899/v1/models
```

## TLS and documentation

The live target has a self-signed Nginx TLS reverse proxy for
https://odysseus.offrail.test and https://offrail-api.offrail.test. Run
playbooks/configure_https.yml to reconcile it. Client devices need matching
hosts-file mappings and must trust the self-signed certificate.

- [TLS operations](docs/TLS_OPERATIONS.md)
- [Offrail model use cases](docs/OFFRAIL_USE_CASES.md)

K3s restarts the deployment after a host reboot. The persistent volume retains the staged model. The init container recopies and SHA-256 verifies the model on pod start.

## Rollback

To return to the previous host-managed model server, first scale down the K3s deployment so port 8899 is released, then start the existing server script:

```bash
ssh sandy007x@192.168.1.148 \
  'sudo k3s kubectl -n offrail scale deployment/offrail-27b --replicas=0 && /home/sandy007x/models/bonsai2-27b/serve_offrail_8gb.sh --daemon'
```

## Complete Offrail cleanup

Cleanup is separate from deployment. First run a preview; no files are removed unless `cleanup_confirm=true` is explicitly provided. Host model cleanup also requires the K3s model to be healthy and ready, protecting the rollback copy until cutover works.

```bash
# Preview host paths and K3s resources. Defaults perform no deletion.
ansible-playbook playbooks/cleanup_host_offrail.yml

# Remove old bare-metal model files, preserving the active K3s deployment and PVC:
ansible-playbook playbooks/cleanup_host_offrail.yml \
  -e cleanup_confirm=true \
  -e cleanup_remove_host_model=true \
  -e cleanup_remove_k3s_model=false

# Full model cleanup: stop/remove legacy host files, delete K3s workload and PVC,
# and optionally remove the model image from K3s containerd cache:
ansible-playbook playbooks/cleanup_host_offrail.yml \
  -e cleanup_confirm=true \
  -e cleanup_remove_host_model=true \
  -e cleanup_remove_k3s_model=true \
  -e cleanup_remove_model_image=true
```

Full cleanup permanently deletes the PVC containing the staged GGUF and the legacy model directories. It keeps the K3s installation and NVIDIA device plugin. Docker Hub image deletion is not performed; delete the published image separately from Docker Hub only if desired. To run the model inside K3s, do **not** run the cleanup playbook; use the Deploy steps above and verify the pod and health endpoint.
