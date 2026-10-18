# Offrail 27B on K3s — Ansible migration project

This is a separate deployment project for running the Offrail GGUF model in K3s. It preserves the existing Odysseus URL (`http://127.0.0.1:8899`) by using host networking. The old host process is stopped only when the operator explicitly enables `cutover_legacy_llama`.

## Architecture

- Model image: `docker.io/sandy007x/offrail-27b-8g:2026.10.17`, containing the GGUF and a small shell runtime used to stage the model.
- Inference image: `ghcr.io/ggml-org/llama.cpp:server-cuda`.
- K3s deployment: one replica, one NVIDIA GPU, model on a PVC, `hostNetwork: true`.
- Host endpoint: `http://127.0.0.1:8899`; cluster service: `http://offrail-27b.offrail.svc.cluster.local:8899`.

The deployment uses `hostNetwork` because Odysseus runs on the target host and requires loopback access. The default server bind address is `127.0.0.1`, which keeps the endpoint local to the target host. Set `offrail_host` to `0.0.0.0` only when other hosts must connect, with firewall and authentication controls in place.

## Prerequisites

- Ansible on the controller and SSH access to `sandy007x@192.168.1.148`.
- NVIDIA driver and a K3s-compatible NVIDIA container runtime on the target. The `nvidia` RuntimeClass must exist if `offrail_runtime_class` is non-empty.
- K3s already installed, or install it using the explicit option below.
- Docker on the controller and Docker Hub credentials for `sandy007x` to build and publish the model image.
- Approximately 8 GiB for the model PVC plus image-layer storage; sufficient free GPU VRAM for the 27B quantization, context, and runtime overhead.

The preflight checks SSH, NVIDIA visibility, and Docker on the controller. It does not install or configure NVIDIA Container Toolkit. Check K3s GPU integration before cutover:

```bash
cd /Users/sandeep383.kumar/Desktop/Misc/offrail-27b-k3s-ansible
ansible-playbook playbooks/preflight.yml
ssh sandy007x@192.168.1.148 'sudo k3s kubectl get nodes -o wide; sudo k3s kubectl get runtimeclass'
```

This project does not store SSH credentials. Supply them at runtime (or use
Ansible Vault), for example:

```bash
ansible-playbook playbooks/preflight.yml \
  -e ansible_password='YOUR_SSH_PASSWORD' \
  -e ansible_become_password='YOUR_SUDO_PASSWORD'
```

## Build and publish the model image

Place the exact GGUF file at `docker/Offrail-27B-8G.gguf`. The default expected SHA-256 is recorded in `group_vars/all.yml`; the script refuses to publish a different file. Authenticate first, then build and push:

```bash
cd /Users/sandeep383.kumar/Desktop/Misc/offrail-27b-k3s-ansible
docker login -u sandy007x
./docker/build-and-push.sh
```

To publish a deliberately updated model, set `EXPECTED_MODEL_SHA256`, `MODEL_FILE`, and `MODEL_IMAGE`, then update `offrail_model_sha256`, `offrail_model_file`, and `offrail_model_image` in `group_vars/all.yml` to the same values. Never put a Docker Hub token in this repository.

## Deploy

First ensure the image is published and K3s GPU scheduling works. If K3s is absent, install it explicitly:

```bash
ansible-playbook playbooks/install_k3s.yml -e install_k3s=true
```

If no NVIDIA device plugin is already installed and GPU resources are not advertised by the node, request installation of the included plugin. This plugin alone does not configure the NVIDIA runtime; the target must already have a working K3s NVIDIA runtime and `RuntimeClass`.

The cutover stops the existing host llama-server before starting the pod on port 8899. Run it only after confirming the published image and GPU runtime:

```bash
ansible-playbook playbooks/deploy_offrail.yml \
  -e cutover_legacy_llama=true \
  -e deploy_nvidia_device_plugin=true
```

If a device plugin is already managed, omit `deploy_nvidia_device_plugin=true`. The playbook waits for rollout, checks `/health`, then restarts Odysseus. It preserves the legacy model directory by default. Set `purge_legacy_model_files=true` only after testing end-to-end chat through Odysseus.

## Operations

```bash
ssh sandy007x@192.168.1.148
sudo k3s kubectl -n offrail get pods,svc,pvc
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
  'sudo k3s kubectl -n offrail scale deployment/offrail-27b --replicas=0 && /home/sandy007x/models/bonsai2-27b/serve_offrail_8gb.sh'
```

Confirm the legacy script's start syntax from the existing project if it differs; do not remove the PVC or legacy model directory during rollback.
