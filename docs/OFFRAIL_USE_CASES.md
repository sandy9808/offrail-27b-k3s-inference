# Offrail 27B use cases

Offrail-27B-8G is a locally hosted GGUF model served by llama.cpp. It is suited
to privacy-sensitive, LAN-only, and offline-first workflows where the hardware
budget is an 8 GB NVIDIA GPU and lower throughput than a cloud API is
acceptable.

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

