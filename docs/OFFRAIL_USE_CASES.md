# Offrail 27B use cases

Offrail-27B-8G is a locally hosted GGUF model served by llama.cpp. It is suited
to privacy-sensitive, LAN-only, and offline-first workflows where the hardware
budget is an 8 GB NVIDIA GPU and lower throughput than a cloud API is
acceptable.

The verified target is Pop!_OS 22.04 with an NVIDIA GeForce RTX 4060 Laptop
GPU (8,188 MiB, compute capability 8.9). K3s serves the model on
`http://127.0.0.1:8899`; Odysseus connects using
`http://127.0.0.1:8899/v1`. The 65,536-token context and q4_0 K/V cache are
deployment settings, not a guarantee that every prompt fits alongside desktop
GPU use. See [system specifications](SYSTEM_SPECS.md) and the [deployment
verification runbook](DEPLOYMENT_AND_VERIFICATION.md) for recorded results
and repeatable checks.

## Primary use cases

| Use case | Why it fits | Integration |
|---|---|---|
| Private assistant | Conversations and prompts remain on the local host or LAN. | Odysseus chat through the local OpenAI-compatible endpoint. |
| Code assistance | Produces code explanations, snippets, refactors, and test ideas. | IDE or internal tool using /v1/chat/completions. |
| RAG over internal documents | Retrieves local text through ChromaDB, then asks the model to summarize or answer. | Odysseus with its ChromaDB companion. |
| Structured extraction | Pulls fields, lists, and JSON-like records from documents or messages. | Use constrained prompts and validate output in the calling application. |
| Research drafting | Summarizes supplied sources and drafts outlines, briefs, and reports. | Odysseus research and document workflows. |
| Air-gapped prototyping | Continues operating without a cloud-model dependency after images and weights are staged. | K3s PVC plus the local llama.cpp service. |

## Recommended operating pattern

1. Keep the inference endpoint private: Odysseus should use
   http://127.0.0.1:8899/v1 for internal calls.
2. Use the HTTPS reverse proxy only for interactive LAN access or explicitly
   trusted clients.
3. Validate and sanitize structured output before an automated downstream
   action. Do not treat generated text as authorization to run commands.
4. Keep model weights and the model image version pinned by SHA-256 and Docker
   tag.

## Not a good fit

- High-concurrency public API serving from a single 8 GB GPU.
- Security decisions, legal/medical conclusions, or unsupervised destructive
  actions.
- Internet-facing use without authentication, network controls, and a
  certificate trusted by the intended clients.
- Tool execution without a permission boundary in the application that consumes
  model output.

## Validation boundary

The model API can generate OpenAI-compatible function-call objects, but it does
not execute them. Odysseus must register the tools, validate arguments, enforce
its own access rules, and perform the work. An API tool-call smoke test is not
an end-to-end tool integration test. The runbook documents both the API check
and the separate Odysseus endpoint validator.

