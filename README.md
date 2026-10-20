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

### Ordered command sequence for the target host

Run these from the Ansible controller after setting `inventory.ini` to the target's current SSH user and IP. All SSH and sudo passwords are entered interactively; do not put them in shell history.

The companion Odysseus project is [odysseus-dev/odysseus](https://github.com/odysseus-dev/odysseus), deployed separately by the adjacent `offrail-27b-ansible` project under `/home/sandy007x/odysseus` on `192.168.1.148`. This repository owns the Offrail model endpoint; the Odysseus app owns application tools and must be configured to call `http://127.0.0.1:8899/v1`.

Before making changes, preview cleanup only (this does not delete anything):

```bash
ansible-playbook playbooks/cleanup_host_offrail.yml --ask-pass --ask-become-pass
```

Do not run confirmed full cleanup when the goal is to keep Offrail deployed. If you intentionally need a fresh model install and accept deleting its host rollback files and K3s PVC, first preserve anything needed, then run the confirmed cleanup and continue with the audit/install steps:

```bash
ansible-playbook playbooks/cleanup_host_offrail.yml \\
  -e cleanup_confirm=true \\
  -e cleanup_remove_host_model=true \\
  -e cleanup_remove_k3s_model=true \\
  -e cleanup_remove_model_image=true \\
  --ask-pass --ask-become-pass
```

1. Inspect host NVIDIA, K3s, Operator, and existing deployment state. This also runs and removes a real CUDA vector-add pod:

   ```bash
   ansible-playbook playbooks/audit_nvidia.yml --ask-pass --ask-become-pass
   ```

   Continue only if host `nvidia-smi` succeeds and K3s is active. If K3s is stopped, start it with `playbooks/install_k3s.yml` as shown below, then rerun the audit. If host `nvidia-smi` fails, repair the Pop!_OS NVIDIA driver first; installing the Kubernetes Operator cannot fix a broken host driver.

2. Install K3s only if it is not already installed; otherwise start it only if it is stopped:

   ```bash
   # Only for a host without K3s:
   ansible-playbook playbooks/install_k3s.yml -e install_k3s=true --ask-pass --ask-become-pass

   # For an installed but stopped K3s service:
   ansible-playbook playbooks/install_k3s.yml -e start_k3s=true --ask-pass --ask-become-pass
   ```

3. Install/reconcile the NVIDIA GPU Operator (requires host driver and Helm), then rerun the audit so the CUDA vector-add test proves container GPU access:

   ```bash
   ansible-playbook playbooks/install_nvidia_gpu_operator.yml --ask-pass --ask-become-pass
   ansible-playbook playbooks/audit_nvidia.yml --ask-pass --ask-become-pass
   ```

4. Build and push both images from this controller after placing the exact model file at `docker/Offrail-27B-8G.gguf` and logging in to Docker Hub interactively:

   ```bash
   docker login -u sandy007x
   ./docker/build-and-push.sh
   ./docker/build-server-image.sh
   ```

5. Cut over the backend only after both image pushes and the second GPU audit succeed:

   ```bash
   ansible-playbook playbooks/deploy_offrail.yml \\
     -e cutover_legacy_llama=true \\
     --ask-pass --ask-become-pass
   ```

6. Confirm both the workload and OpenAI-compatible API on Pop!_OS (SSH from the controller):

   ```bash
   ssh sandy007x@192.168.1.148
   sudo k3s kubectl -n offrail rollout status deployment/offrail-27b --timeout=15m
   sudo k3s kubectl -n offrail get pods,pvc -o wide
   sudo k3s kubectl -n offrail logs deployment/offrail-27b -c llama-server --tail=100
   curl -fsS http://127.0.0.1:8899/health
   curl -fsS http://127.0.0.1:8899/v1/models
   ```

   The host Odysseus service should use base URL `http://127.0.0.1:8899/v1` and the model ID returned by `/v1/models`. Restart it only after Offrail health succeeds; the Ansible deploy playbook does this.

7. Test a normal chat completion and an OpenAI-compatible tool call from Pop!_OS. Tool calls are returned for the **client application** to execute; the model server does not execute tools itself. Odysseus must expose/register the `odysseus` and `models` tools and execute the returned calls under its own permissions policy.

   ```bash
   MODEL_ID="$(curl -fsS http://127.0.0.1:8899/v1/models | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])')"
   curl -fsS http://127.0.0.1:8899/v1/chat/completions \\
     -H 'Content-Type: application/json' \\
     -d "$(MODEL_ID="$MODEL_ID" python3 -c 'import json,os; print(json.dumps({"model":os.environ["MODEL_ID"],"messages":[{"role":"user","content":"Reply with exactly: Offrail is online."}],"max_tokens":64,"stream":False}))')"

   curl -fsS http://127.0.0.1:8899/v1/chat/completions \\
     -H 'Content-Type: application/json' \\
     -d "$(MODEL_ID="$MODEL_ID" python3 -c 'import json,os; print(json.dumps({"model":os.environ["MODEL_ID"],"messages":[{"role":"user","content":"Use the odysseus tool to check service status, then use the models tool to list available models."}],"tools":[{"type":"function","function":{"name":"odysseus","description":"Query Odysseus service status","parameters":{"type":"object","properties":{"action":{"type":"string","enum":["status"]}},"required":["action"]}}},{"type":"function","function":{"name":"models","description":"List models available to Odysseus","parameters":{"type":"object","properties":{"action":{"type":"string","enum":["list"]}},"required":["action"]}}}],"tool_choice":"auto","stream":False,"max_tokens":256}))')"
   ```

   A tool-call test passes at the model API layer when the response contains `choices[0].message.tool_calls` with `odysseus`/`models` and JSON arguments. End-to-end tool execution must be validated inside Odysseus, because only that application has the tool implementations. The body does not grant the model shell access.

The names above are example OpenAI-compatible function names for the client integration. They do not prove that Odysseus currently registers tools under those exact identifiers; match the function names and JSON schemas to the tools actually registered by Odysseus. For app-side deployment and its own integration checks, use the companion repository's documented playbook from its checkout:

```bash
cd /Users/sandeep383.kumar/Desktop/Misc/offrail-27b-ansible
ansible-playbook playbooks/serve_odysseus.yml --ask-pass --ask-become-pass
```

### One-shot K3s manifests

The checked-in [one-shot deployment manifest](kubernetes/offrail-one-shot.yaml) contains the namespace, model PVC, and Offrail Deployment. It assumes K3s, the healthy NVIDIA GPU Operator, and both pushed images are already present. The deployment claims host loopback port 8899, so stop any existing host llama-server before applying it. To use the one-shot path instead of Ansible deploy:

```bash
ssh sandy007x@192.168.1.148
# Stop the existing host server using its own service/script, if running.
sudo k3s kubectl apply -f offrail-one-shot.yaml
sudo k3s kubectl -n offrail rollout status deployment/offrail-27b --timeout=15m
curl -fsS http://127.0.0.1:8899/health
```

Copy `kubernetes/offrail-one-shot.yaml` to the target first (for example with `scp`). The manifest uses the same image tags, model checksum, GPU request, 64K context, and 8899 loopback endpoint as the Ansible templates.

Run the standalone GPU smoke test after Operator installation with:

```bash
sudo k3s kubectl apply -f nvidia-vectoradd-one-shot.yaml
sudo k3s kubectl wait --for=jsonpath='{.status.phase}=Succeeded' pod/nvidia-vectoradd-smoke --timeout=180s
sudo k3s kubectl logs pod/nvidia-vectoradd-smoke
sudo k3s kubectl delete -f nvidia-vectoradd-one-shot.yaml
```

Copy the file from `kubernetes/nvidia-vectoradd-one-shot.yaml` to the target first. The expected log includes `Test PASSED`.

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
