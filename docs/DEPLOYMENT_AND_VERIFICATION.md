# Offrail on K3s: deployment and verification runbook

This runbook covers the Ansible-managed deployment on the Pop!_OS target
`192.168.1.148`, including the NVIDIA GPU Operator, amd64 image build/import,
the model endpoint on port `8899`, Odysseus checks, cleanup, and rollback.
Commands are grouped by where they run:

- **Controller:** the machine with this repository checkout and Ansible.
- **Target:** `pop-os` at `192.168.1.148`.

For exact hardware and software versions, see [verified system
specifications](SYSTEM_SPECS.md). The repo's existing [`README.md`](../README.md)
is the short project overview.

## 1. Target and deployment facts

- SSH target: `sandy007x@192.168.1.148`.
- K3s node: `pop-os`; K3s API access uses `sudo k3s kubectl` on the target.
- NVIDIA GPU: GeForce RTX 4060 Laptop GPU, 8,188 MiB, compute capability 8.9.
- GPU Operator: `v26.7.2`; the host driver remains managed by Pop!_OS
  (`driver.enabled=false` in Helm values).
- Model pod: `offrail/offrail-27b`, one replica, one GPU, 65,536-token context.
- Local API: `http://127.0.0.1:8899`; the model uses host networking to retain
  the URL already used by Odysseus.
- Model and runtime images:
  `docker.io/sandy007x/offrail-27b-8g:2026.10.17` and
  `docker.io/sandy007x/offrail-llama-server:2026.10.20`.
- Both images are built for `linux/amd64`. The custom CUDA 12.4 runtime bundle
  contains `sm_86`/`sm_89` kernels and the custom llama-server required by this
  PTQ1_0 GGUF.

Do not paste SSH, sudo, Docker Hub, or GitHub credentials into commands,
Markdown, shell history, or Git. Ansible commands below prompt for SSH and
become passwords with `--ask-pass --ask-become-pass`.

## 2. Preflight and cleanup preview

Run on the **controller**, from the repository root:

```bash
cd /Users/sandeep383.kumar/Desktop/Misc/offrail-27b-k3s-ansible
ansible-playbook playbooks/preflight.yml --syntax-check
ansible-playbook playbooks/install_k3s.yml --syntax-check
ansible-playbook playbooks/install_nvidia_gpu_operator.yml --syntax-check
ansible-playbook playbooks/deploy_offrail.yml --syntax-check
ansible-playbook playbooks/preflight.yml --ask-pass --ask-become-pass
ansible-playbook playbooks/cleanup_host_offrail.yml --ask-pass --ask-become-pass
```

The cleanup playbook defaults to preview mode. Review the listed legacy paths,
Deployment, PVC, and cached model image. A preview does not delete them.

Full cleanup is destructive: it deletes the legacy host model directories and
the K3s model Deployment/PVC (including the staged GGUF); the optional image
flag removes the model image from K3s containerd. It retains K3s and the GPU
Operator. Do this only when a clean reinstall is intended and the data is
disposable:

```bash
ansible-playbook playbooks/cleanup_host_offrail.yml \
  -e cleanup_confirm=true \
  -e cleanup_remove_host_model=true \
  -e cleanup_remove_k3s_model=true \
  -e cleanup_remove_model_image=true \
  --ask-pass --ask-become-pass
```

When removing only the legacy host files while keeping the working K3s model,
the playbook first requires the K3s health endpoint and a ready Deployment:

```bash
ansible-playbook playbooks/cleanup_host_offrail.yml \
  -e cleanup_confirm=true \
  -e cleanup_remove_host_model=true \
  -e cleanup_remove_k3s_model=false \
  --ask-pass --ask-become-pass
```

## 3. K3s readiness

First check whether K3s is installed and active. If it is installed but
stopped, start it. Only install K3s when it is absent.

```bash
# Controller: start an installed, stopped service
ansible-playbook playbooks/install_k3s.yml \
  -e start_k3s=true --ask-pass --ask-become-pass

# Controller: install K3s only on a host without K3s
ansible-playbook playbooks/install_k3s.yml \
  -e install_k3s=true --ask-pass --ask-become-pass
```

Check the service and Kubernetes API on the **target**:

```bash
ssh sandy007x@192.168.1.148
systemctl is-active k3s
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get pods -A
```

The node must be `Ready` before installing the GPU Operator or deploying
Offrail. If the API refuses connections, inspect the K3s service log before
continuing:

```bash
sudo journalctl -u k3s -n 100 --no-pager
```

## 4. Install and validate NVIDIA GPU Operator

The host driver must already work. The install playbook requires `nvidia-smi`,
K3s API access, and Helm. It configures the K3s containerd template to preserve
K3s's `base` configuration and import NVIDIA's runtime fragment, sets the
Operator to use K3s's containerd socket/runtime class, and leaves the host
driver installed by the OS untouched. It also sets the Operator's CUDA
validator `WITH_WORKLOAD=false`; on this GeForce host, validate CUDA through
the actual Offrail workload instead of the Operator's standalone
forward-compatibility validator.

Run from the **controller**:

```bash
ansible-playbook playbooks/install_nvidia_gpu_operator.yml \
  --ask-pass --ask-become-pass
```

Run the full audit while the GPU is free. The default audit creates a temporary
CUDA vector-add Pod, requires `Test PASSED`, and deletes the Pod afterward:

```bash
ansible-playbook playbooks/audit_nvidia.yml \
  --ask-pass --ask-become-pass
```

If Offrail is already using the only GPU, skip the standalone vector-add Pod
and use the in-use-safe audit plus Offrail inference checks below:

```bash
ansible-playbook playbooks/audit_nvidia.yml \
  -e nvidia_gpu_smoke_test=false \
  --ask-pass --ask-become-pass
```

On the **target**, verify host GPU visibility, Operator state, node GPU
advertisement, runtime class, and relevant pods:

```bash
nvidia-smi
nvidia-container-cli info
sudo k3s kubectl get nodes -o json | python3 -c 'import json,sys; d=json.load(sys.stdin); [print(n["metadata"]["name"], "capacity=", n.get("status",{}).get("capacity",{}).get("nvidia.com/gpu","0"), "allocatable=", n.get("status",{}).get("allocatable",{}).get("nvidia.com/gpu","0")) for n in d.get("items",[])]'
sudo k3s kubectl get runtimeclass nvidia
sudo k3s kubectl get clusterpolicy cluster-policy -o wide
sudo k3s kubectl get pods -n gpu-operator -o wide
sudo helm list -n gpu-operator
sudo cat /var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl
```

Expected state: ClusterPolicy `ready`, node capacity/allocatable GPU `1/1`,
and Operator DaemonSet pods Running/Ready. `driver` is intentionally disabled
in the Operator chart because Pop!_OS owns the host driver.

## 5. Build both amd64 images on the target and import them into K3s

The target already has the verified GGUF at
`/home/sandy007x/models/bonsai2-27b/Offrail-27B-8G.gguf`. The helper builds
both images locally with `--platform linux/amd64`, checks the GGUF SHA-256,
then imports them into K3s containerd. It downloads the CUDA 12.4 runtime
bundle to the target if it is not present. This route avoids uploading the
large GGUF to Docker Hub and avoids copying it from the controller.

From the **controller**, create the destination and copy the helper inputs:

```bash
ssh sandy007x@192.168.1.148 'mkdir -p ~/offrail-image-build/docker'
scp docker/Dockerfile.model docker/Dockerfile.server \
  docker/build-and-push.sh docker/build-server-image.sh docker/build-for-k3s.sh \
  sandy007x@192.168.1.148:~/offrail-image-build/docker/
```

Then build on the **target**. The helper invokes `sudo -n` for K3s; the target
account must have non-interactive sudo access for these commands, as configured
for this deployment.

```bash
ssh sandy007x@192.168.1.148 \
  'chmod +x ~/offrail-image-build/docker/*.sh && ~/offrail-image-build/docker/build-for-k3s.sh'
```

Verify both image tags are in K3s containerd and the image architecture is
amd64:

```bash
sudo k3s ctr images ls | grep -E 'offrail-(27b-8g|llama-server)'
docker image inspect --format '{{.Os}}/{{.Architecture}} {{.RepoTags}}' \
  docker.io/sandy007x/offrail-27b-8g:2026.10.17 \
  docker.io/sandy007x/offrail-llama-server:2026.10.20
```

Expected image architecture: `linux/amd64`. The model build script rejects a
GGUF whose SHA-256 differs from
`be2b5ce27bd4bf6125f571e994489a325b711b092315c4b874837e4649fc04ed`.

## 6. Deploy Offrail while preserving port 8899

The Ansible Deployment uses `hostNetwork` and binds to `127.0.0.1:8899` to
preserve the existing Odysseus backend URL. Set the cutover flag only after
the images are imported and the node advertises `nvidia.com/gpu`. The playbook
stops the legacy host llama-server, applies the K3s manifests, waits for a
ready rollout and healthy `/health`, then restarts `odysseus-ui`.

Run on the **controller**:

```bash
ansible-playbook playbooks/deploy_offrail.yml \
  -e cutover_legacy_llama=true \
  --ask-pass --ask-become-pass
```

## 7. Verify deployment, GPU use, and HTTP API

Run on the **target**:

```bash
sudo k3s kubectl -n offrail rollout status deployment/offrail-27b --timeout=15m
sudo k3s kubectl -n offrail get deployment,pods,pvc -o wide
sudo k3s kubectl -n offrail describe pod -l app.kubernetes.io/name=offrail-27b
sudo k3s kubectl -n offrail logs deployment/offrail-27b -c llama-server --tail=100
sudo k3s kubectl get nodes -o json | python3 -c 'import json,sys; d=json.load(sys.stdin); [print(n["metadata"]["name"], "allocatable GPU=", n.get("status",{}).get("allocatable",{}).get("nvidia.com/gpu","0")) for n in d.get("items",[])]'
curl -fsS http://127.0.0.1:8899/health
curl -fsS http://127.0.0.1:8899/v1/models
nvidia-smi
```

Expected: one ready pod, PVC Bound, model API health HTTP 200, model ID
`/models/Offrail-27B-8G.gguf`, and the llama-server process visible in host
`nvidia-smi` with GPU memory allocated. The health and model endpoints prove
service/API availability; `nvidia-smi` plus a generated completion proves
actual model inference on the GPU.

Send a simple completion and check for the known smoke response:

```bash
MODEL_ID="$(curl -fsS http://127.0.0.1:8899/v1/models | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])')"
curl -fsS http://127.0.0.1:8899/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"${MODEL_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: Offrail is online.\"}],\"max_tokens\":64,\"stream\":false}"
```

During the recorded test, the response was `Offrail is online.` and the short
completion measured approximately 33 tokens/s. Treat this as a smoke check,
not a performance guarantee.

## 8. Verify function-call formatting and Odysseus tools

The OpenAI-compatible endpoint can return function/tool calls when the caller
supplies tool schemas. A direct model API test verifies only that formatting;
the model server does not run tools. Odysseus must have the named tools
registered and it must decide whether and how to execute them.

This request asks the API to return calls for the `odysseus` and `models`
functions. Their schemas here are smoke-test examples; match them to the
application's actual tool schemas if those have changed.

```bash
MODEL_ID="$(curl -fsS http://127.0.0.1:8899/v1/models | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])')"
MODEL_ID="$MODEL_ID" python3 - <<'PY' | curl -fsS http://127.0.0.1:8899/v1/chat/completions -H 'Content-Type: application/json' -d @-
import json, os
print(json.dumps({
    "model": os.environ["MODEL_ID"],
    "messages": [{"role": "user", "content": "Use the odysseus tool to check service status, then use the models tool to list available models."}],
    "tools": [
        {"type": "function", "function": {"name": "odysseus", "description": "Query Odysseus service status", "parameters": {"type": "object", "properties": {"action": {"type": "string", "enum": ["status"]}}, "required": ["action"]}}},
        {"type": "function", "function": {"name": "models", "description": "List models available to Odysseus", "parameters": {"type": "object", "properties": {"action": {"type": "string", "enum": ["list"]}}, "required": ["action"]}}}
    ],
    "tool_choice": "auto",
    "stream": False,
    "max_tokens": 256
}))
PY
```

The API-level check passes when `choices[0].message.tool_calls` contains the
expected function names and JSON arguments. To verify the actual app and its
tool adapters on the **target**, run the Odysseus project validator:

```bash
bash /home/sandy007x/odysseus/scripts/validate_odysseus_endpoint.sh
```

The recorded run reported 5 passed, 0 failed: Odysseus health HTTP 200,
unauthenticated `/ready` correctly returned 401, UI root HTTP 200, Offrail
health HTTP 200, and ChromaDB heartbeat succeeded. The model API tool-call
format was checked for both `odysseus` with `{"action":"status"}` and
`models` with `{"action":"list"}`. That direct API check did not execute
those tools; the Odysseus application validator checks its own connected
services.

## 9. One-shot Kubernetes manifests

Use the checked-in one-shot manifest only as an alternative to Ansible deploy.
It still requires K3s, a healthy GPU Operator, both images available in
containerd/registry, and port 8899 released by the previous host server.

From the **controller**, copy the manifest. On the **target**, apply and verify:

```bash
scp kubernetes/offrail-one-shot.yaml sandy007x@192.168.1.148:~/offrail-one-shot.yaml
ssh sandy007x@192.168.1.148
sudo k3s kubectl apply -f ~/offrail-one-shot.yaml
sudo k3s kubectl -n offrail rollout status deployment/offrail-27b --timeout=15m
sudo k3s kubectl -n offrail get pods,pvc -o wide
curl -fsS http://127.0.0.1:8899/health
curl -fsS http://127.0.0.1:8899/v1/models
```

For a standalone vector-add smoke test, copy and run the companion manifest
while the GPU is available. Do not run it concurrently with the 27B pod on
this single-GPU host. Delete the temporary pod whether it passes or fails.

```bash
# Controller
scp kubernetes/nvidia-vectoradd-one-shot.yaml \
  sandy007x@192.168.1.148:~/nvidia-vectoradd-one-shot.yaml

# Target
sudo k3s kubectl apply -f ~/nvidia-vectoradd-one-shot.yaml
sudo k3s kubectl wait --for=jsonpath='{.status.phase}=Succeeded' \
  pod/nvidia-vectoradd-smoke --timeout=180s
sudo k3s kubectl logs pod/nvidia-vectoradd-smoke
sudo k3s kubectl delete -f ~/nvidia-vectoradd-one-shot.yaml --ignore-not-found
```

Expected successful vector-add output includes `Test PASSED`. During the
recorded run, a separate vector-add pod remained Pending because Offrail
already held the single allocatable GPU; it was removed. This is why the
inference workload itself is the GPU validation while Offrail is serving.

## 10. Operations, logs, and Odysseus configuration

Odysseus should use base URL `http://127.0.0.1:8899/v1` and the model ID
returned by `/v1/models`. The Ansible deploy playbook restarts `odysseus-ui`
after the model endpoint is healthy.

```bash
sudo systemctl status odysseus-ui --no-pager
sudo k3s kubectl -n offrail get pods,pvc -o wide
sudo k3s kubectl -n offrail logs deployment/offrail-27b -c llama-server -f
curl -fsS http://127.0.0.1:8899/health
curl -fsS http://127.0.0.1:8899/v1/models
nvidia-smi
```

To audit host and cluster state without asking Kubernetes to schedule a second
GPU workload:

```bash
# Controller
ansible-playbook playbooks/audit_nvidia.yml \
  -e nvidia_gpu_smoke_test=false \
  --ask-pass --ask-become-pass
```

## 11. Rollback and complete cleanup

For rollback to the old host-managed model server, scale down K3s first to
release port 8899, then start the saved host server:

```bash
ssh sandy007x@192.168.1.148 \
  'sudo k3s kubectl -n offrail scale deployment/offrail-27b --replicas=0 && /home/sandy007x/models/bonsai2-27b/serve_offrail_8gb.sh --daemon'
```

To remove the model while keeping the K3s installation and NVIDIA Operator,
start with preview mode in §2, review the exact paths/resources, then run the
confirmed cleanup only if removal is intended. The active PVC contains the
staged GGUF; deleting it is irreversible without another model copy. Docker
Hub images are not deleted by this playbook. It removes only the model image
from local K3s containerd when `cleanup_remove_model_image=true`.

## 12. 2026-10-29 recovery

On 2026-10-29 the node advertised `nvidia.com/gpu=0`, the Offrail pod was
Pending, and `http://127.0.0.1:8899/health` was refused. The host driver was
healthy (`nvidia-smi` showed the RTX 4060). The break was in the container
runtime integration:

- `/etc/containerd/config.toml` used `disabled_plugins = ["cri"]`. Containerd
  rejected that short name (`invalid disabled plugin URI "cri"`), so
  `containerd config dump` failed and the toolkit installer could not start.
  The working value is `disabled_plugins = ["io.containerd.grpc.v1.cri"]`.
- GPU sandboxes failed with `unknown version specified` because the NVIDIA
  runtime preferred `/usr/bin/crun` 0.17, which does not understand the OCI
  spec emitted by K3s containerd. The runtime list in
  `/usr/local/nvidia/toolkit/.config/nvidia-container-runtime/config.toml`
  was pointed at `/var/lib/rancher/k3s/data/current/bin/runc` first.
- The toolkit installer v1.20.1 then panic'd in `ensureImports` while saving a
  containerd 2 drop-in. The runtime files were already installed, so the
  operator was upgraded with `toolkit.enabled=false`. ClusterPolicy returned
  to `ready`. `nvidia_toolkit_enabled` in `group_vars/all.yml` records that
  choice. Set it back to true only for a first install that still needs the
  installer.

With the GPU free, the vector-add smoke test was applied from
`kubernetes/nvidia-vectoradd-one-shot.yaml`. Its log contained `Test PASSED`,
and the pod was deleted. Offrail was scaled to 1. Both images were already in
Docker and were imported into K3s containerd. The pod became `1/1` Ready.

Verified on the target:

- `curl http://127.0.0.1:8899/health` returned `{"status":"ok"}`.
- `/v1/models` returned `/models/Offrail-27B-8G.gguf`.
- The chat smoke test returned `Offrail is online.`
- The tool-call smoke test returned `odysseus` with `{"action":"status"}` and
  `models` with `{"action":"list"}`.
- `nvidia-smi` showed `/opt/offrail/bin/llama-server` using about 7,258 MiB.
- Device plugin, GPU feature discovery, DCGM exporter, and the operator
  validator were Running. ClusterPolicy was `ready`.

Public access for the Odysseus web UI, not the inference port, is recorded in
[Tailscale exposure](TAILSCALE_EXPOSURE.md).

## 13. Recorded work and verification results

The following work was recorded on the target during the deployment repair.
A read-only live check on 2026-10-22 confirmed:

- K3s service active and node `pop-os` Ready on K3s `v1.34.3+k3s1`.
- GPU Operator ClusterPolicy `ready`; all nine GPU Operator/NFD pods were
  `Running` and `1/1` Ready.
- Offrail Deployment `1/1` Ready and its 8 GiB model PVC Bound.
- Odysseus systemd service active.
- `/health` returned `{"status":"ok"}`; `/v1/models` returned the expected
  model with 65,536 context, 27.3B parameters, and PTQ1_0 quantization.
- `nvidia-smi` showed `/opt/offrail/bin/llama-server` using 7,262 MiB, with
  total usage 7,491/8,188 MiB while idle between prompts.

The deployment repair also recorded these actions and checks:

1. `ansible-playbook playbooks/install_nvidia_gpu_operator.yml` completed
   successfully after repairing the K3s containerd template integration.
2. The template now extends K3s's `base` template and imports NVIDIA's runtime
   fragment. K3s restarted, the node became Ready, and CNI/networking worked.
3. NVIDIA GPU Operator `v26.7.2` reconciled to ClusterPolicy Ready; the node
   advertised one allocatable NVIDIA GPU and the Operator pods were healthy.
4. The NVIDIA standalone CUDA validator workload was disabled through
   `WITH_WORKLOAD=false`; the existing host GeForce driver was retained.
5. Offrail was Ready 1/1, served on `127.0.0.1:8899`, returned HTTP 200 for
   health and `/v1/models`, and generated the smoke response above.
6. Host `nvidia-smi` showed the llama-server process using about 7.2 GiB.
7. The Odysseus endpoint validator passed all five health/UI/backend/vector
   store checks described in §8.
8. The model API returned the `odysseus` and `models` function calls with JSON
   arguments. These were returned to the client; no tools ran in the model
   server.
9. The standalone vector-add pod could not schedule while the model reserved
   the only GPU; it was removed after the attempt.

For a complete live inventory, run the commands in
[system specifications](SYSTEM_SPECS.md#recheck-and-complete-the-system-inventory).

## 13. Code fixes captured in this repository

These are the code-level corrections behind the operational steps above:

1. **K3s YAML argument types:** the Deployment's container `args` must all be
   strings. The reported API error, `cannot unmarshal number into ... args of
   type string`, was fixed by quoting the port and context values in
   `kubernetes/20-llama-deployment.yaml.j2` (for example, `"8899"` and
   `"65536"`). Numeric-looking flags are strings in Kubernetes YAML.
2. **Custom llama-server location:** the runtime archive places the executable
   at `bin/llama-server`. `docker/build-server-image.sh` now checks that path;
   `docker/Dockerfile.server` starts `/opt/offrail/bin/llama-server` and sets
   `LD_LIBRARY_PATH=/opt/offrail/lib`. This fixes the earlier build failure
   that looked for a nonexistent `.../llama-server` at the bundle root.
3. **amd64 builds and local K3s import:** both image build scripts use
   `--platform linux/amd64`. `docker/build-for-k3s.sh` builds from the GGUF
   already on the Pop!_OS target, skips registry pushes, and imports both
   images into K3s containerd. The model build checks the pinned SHA-256.
4. **K3s containerd/CNI preservation:** the NVIDIA runtime template includes
   the runtime-fragment import and retains K3s's base settings:

   ```toml
   imports = ["/etc/containerd/conf.d/*.toml"]
   {{ template "base" . }}
   ```

   The Operator install playbook backs up and installs this template, restarts
   K3s when it changes, waits for the node to return Ready, then waits for
   ClusterPolicy Ready and an allocatable `nvidia.com/gpu` resource. This
   preserves K3s networking/cgroups while allowing the NVIDIA runtime.
5. **GPU Operator configuration:** Helm leaves the Pop!_OS host driver in
   place (`driver.enabled=false`), points the toolkit at K3s's containerd
   config/socket and `nvidia` RuntimeClass, and sets the CUDA validator's
   `WITH_WORKLOAD=false`. The old standalone device-plugin DaemonSet is
   removed; the Operator supplies the toolkit and device plugin.
6. **K3s permissions and startup:** Ansible tasks that invoke K3s kubectl run
   with privilege so they can read `/etc/rancher/k3s/k3s.yaml`. If K3s is
   installed but inactive, start it explicitly with
   `playbooks/install_k3s.yml -e start_k3s=true`; deployment waits for the
   Kubernetes node/API before applying resources.
7. **Port 8899 and service routing:** the model uses `hostNetwork` and binds
   to `127.0.0.1:8899` for Odysseus. The obsolete ClusterIP Service is removed
   during deployment because the local-only host-network endpoint is the
   intended route.

The commands for reproducing these fixes and checking them are in §§3–10.
The recorded successful manual commands include
`ansible-playbook playbooks/install_nvidia_gpu_operator.yml` (the playbook
syntax-check was also run), the live `nvidia-smi`/K3s/API commands listed in
§§4, 7, and [system specifications](SYSTEM_SPECS.md), and
`bash /home/sandy007x/odysseus/scripts/validate_odysseus_endpoint.sh` (5
passed, 0 failed). The runbook presents copyable equivalents with interactive
Ansible password prompts. It is an operational record, not a verbatim capture
of every repository-inspection or shell housekeeping command. The standalone
CUDA vector-add Pod was attempted while the model held the only GPU; it stayed
Pending and was removed, so the running Offrail inference plus `nvidia-smi` is
the GPU-use verification for that state.

## 14. GitHub credentials and publishing

A GitHub personal access token was pasted into chat earlier and must be treated
as exposed. Revoke it in GitHub, then authenticate with a fresh credential
through the GitHub app connection or `gh auth login`. Never add a token to this
repository or put it in a command line. The deployment documentation can be
committed locally without the token; pushing requires a valid GitHub
authentication session.
