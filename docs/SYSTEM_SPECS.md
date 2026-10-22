# Verified target system specifications

These values were collected from the deployment target `192.168.1.148` during
a read-only live check on 2026-10-22. GPU and system memory use varies with the
desktop session and workload. Re-run the commands at the end for current
values.

## Host, GPU, and runtime

| Component | Verified value |
|---|---|
| Host name | `pop-os` |
| Operating system | Pop!_OS 22.04 LTS |
| Kernel | `6.12.10-76061203-generic` |
| Architecture | `x86_64` / `amd64` |
| CPU | 13th Gen Intel Core i7-13620H, 16 logical CPUs |
| System RAM | 15 GiB; 1.7 GiB available in the recorded snapshot |
| Swap | 19 GiB configured |
| Primary storage | 476.9 GiB NVMe (`nvme0n1`), 467.9 GiB ext4 root partition; 77 GiB free (83% used) |
| Additional mounted storage | 114.6 GiB device mounted at `/media/sandy007x/vol` |
| Kubernetes distribution | K3s `v1.34.3+k3s1` |
| Container runtime | containerd `2.1.5-k3s1` |
| GPU | NVIDIA GeForce RTX 4060 Laptop GPU |
| GPU compute capability | 8.9 (`sm_89`) |
| Installed driver | `570.133.07` |
| CUDA version reported by `nvidia-smi` | `12.8` |
| GPU memory | 8,188 MiB total |
| GPU memory while model loaded | 7,491 MiB in use; llama-server process used 7,262 MiB |
| GPU compute utilization at the idle snapshot | 0% |
| NVIDIA Container Toolkit | `1.20.1` |
| NVIDIA GPU Operator | `v26.7.2`, ClusterPolicy `cluster-policy` Ready |
| Kubernetes GPU resource | `nvidia.com/gpu`: capacity 1, allocatable 1 |

## Offrail workload

| Setting | Verified value |
|---|---|
| Model image | `docker.io/sandy007x/offrail-27b-8g:2026.10.17` |
| Model file | `Offrail-27B-8G.gguf` |
| Model size reported by llama-server | 6,286,536,704 bytes |
| Model SHA-256 | `be2b5ce27bd4bf6125f571e994489a325b711b092315c4b874837e4649fc04ed` |
| Inference image | `docker.io/sandy007x/offrail-llama-server:2026.10.20` |
| Inference image architecture | `linux/amd64` |
| Custom runtime bundle | CUDA 12.4, x86-64, `sm_86` and `sm_89`, source bundle commit `285542d` |
| Deployment | `offrail/offrail-27b`, one ready replica |
| Model context | 65,536 tokens |
| GPU offload | `-ngl 99`, one GPU requested |
| KV cache | `q4_0` for K and V; flash attention enabled |
| Endpoint | `http://127.0.0.1:8899` |
| API model id | `/models/Offrail-27B-8G.gguf` |

During the live check, Offrail was Ready 1/1, its 8 GiB PVC was Bound, and the
API health endpoint returned `{"status":"ok"}`. `/v1/models` reported the
27,320,697,856-parameter, 6,286,536,704-byte GGUF, context 65,536, and
quantization `PTQ1_0 - 1.75 bpw ternary (group 128)`. Host `nvidia-smi` showed
the llama-server process using 7,262 MiB and total GPU use of 7,491 MiB of
8,188 MiB; GPU utilization was 0% while idle between prompts. The model
therefore occupies most of the GPU memory even while waiting. Display and
other GPU use can change the headroom. A short smoke prompt returned
`Offrail is online.` and measured about 33 tokens/s in the earlier run; this
is not a sustained benchmark.

The custom runtime bundle targets `sm_86` and `sm_89`; it matches the RTX 4060
Laptop GPU (`sm_89`). Both image scripts set `--platform linux/amd64`. This
documents the target build architecture and does not claim compatibility with
other GPU architectures.

## Recheck and complete the system inventory

Run these on the target after SSHing in. They print the live values, including
CPU, RAM, disk, GPU, driver, K3s, and containerd versions.

```bash
ssh sandy007x@192.168.1.148
hostnamectl
uname -a
uname -m
lscpu
free -h
df -h /
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
nvidia-smi
nvidia-smi --query-gpu=name,driver_version,memory.total,memory.used,memory.free --format=csv
nvidia-container-cli info
sudo k3s --version
sudo k3s ctr version
sudo k3s kubectl get nodes -o wide
```

`nvidia-smi` does not report the GPU compute capability on every driver
version. When that field is unavailable, use the GPU model's NVIDIA
specification or query it through a CUDA device utility.

## Related runbook

See [deployment and verification](DEPLOYMENT_AND_VERIFICATION.md) for the
Ansible sequence, GPU Operator checks, model/API smoke tests, Odysseus
integration checks, cleanup, and rollback.
