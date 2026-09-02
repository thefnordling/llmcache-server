# llmcache-server

Thin Docker overlay that replaces stock LMCache in a vLLM image with a build that
correctly stores and retrieves KV for **hybrid (Mamba/GDN/circular-buffer) models**
on the LMCache multi-process (MP) server.

Built for the Qwen3.8-Flash-Next GDN-hybrid deployment; fixes two silent no-op
defects that made the MP connector useless on hybrid models (zero stores, zero
lookup hits).

## Contents

- `Dockerfile` — overlay on `vllm/vllm-openai:qwen38-flash-next` (base must exist
  locally; it is a custom home-built image)
- `lmcache-0.5.5rc2.dev16-cp312-cp312-linux_x86_64.whl` — prebuilt wheel
  (CUDA 13 / torch 2.11 cu130 toolchain, `TORCH_CUDA_ARCH_LIST=12.0`, Python 3.12)
  - SHA256: `108bae056c57270f51ec0eb53968681206b67b39eee974d12985e8eec2ef457f`

## Provenance

Wheel source: [`thefnordling/LMCache`](https://github.com/thefnordling/LMCache)
branch `pr4772-gate-validation`, commit `5065d6ab`, on top of LMCache `dev`
(`56e45ff7`):

| Commit | Change |
|---|---|
| `6ca03b45` | Cherry-pick of LMCache PR [#4772](https://github.com/LMCache/LMCache/pull/4772) — padded NHD content-size KV layout support (needed for vLLM's layer-padded KV pools) |
| `5065d6ab` | Hybrid state-page fixes: store gate + lookup window (see below) |

**Store path fix:** `GetStoreMetadata` bounded the storable prefix with
`min(len(ids) * tokens_per_block)` across *all* engine groups. Constant-size
state pages (align-mode Mamba/GDN snapshots, mode-`none` Mamba, vLLM
`CircularBufferSpec` short-conv rings) never scale with prompt length, so a
single rolling page capped every request below one chunk — zero STORE metadata,
ever. State groups now gate presence only and are sliced as engine-provided
tables or null-padded last-block snapshots.

**Retrieve path fix:** `_resolve_per_layer_sw_sizes` classified only
snapshotting Mamba as windowed; rolling rings inherited `-1` (full attention),
so the lookup fold demanded objects at boundaries that legitimately never exist
and zeroed every prefix hit. All state-page specs now carry a one-block
cross-chunk window, matching vLLM's own semantics.

Validated end-to-end: stores land in L1/L2; replayed prompts hit their full
stored prefix (~50% token hit rate on alternating bursts, ~2x replay speedup);
cold-L1 replay serves from the fs L2 adapter and L1 hydrates.

## Build

```bash
docker build -t vllm/vllm-openai:qwen38-flash-next-pr4772-gate .
```

## Run (MP server)

Hybrid models require both flags:

```bash
lmcache server \
  --chunk-size 1600 \
  --l1-size-gb 128 \
  --eviction-policy IsolatedLRU \
  --l2-adapter '{"type":"fs","base_path":"/lmcache/l2"}' \
  --separate-object-groups \
  --l2-prefetch-policy retain \
  --http-host 0.0.0.0 --http-port 8080
```

- `--separate-object-groups` — mandatory for linear/hybrid models (LMCache
  #4437); recurrent/window object groups must be tracked separately
- `--l2-prefetch-policy retain` — prefetched L2 objects persist in L1
  (default policy drops them when the retrieve completes)
- Quota after start: `lmcache quota set _default --limit-gb <N> --url http://localhost:8080`

And on the vLLM side: `--mamba-cache-mode align` plus the MP connector config
(`kv_transfer_config.kv_connector=LMCacheMPConnector`, `lmcache.mp.host/port`).

## Rebuilding the wheel from source

```bash
git clone -b pr4772-gate-validation https://github.com/thefnordling/LMCache
docker run --rm -v $PWD/LMCache:/src \
  -e TORCH_CUDA_ARCH_LIST=12.0 \
  -e SETUPTOOLS_SCM_PRETEND_VERSION=0.5.5rc2.dev16 \
  -e CPATH=/usr/local/lib/python3.12/dist-packages/nvidia/cu13/include \
  -e LIBRARY_PATH=/usr/local/lib/python3.12/dist-packages/nvidia/cu13/lib \
  --entrypoint bash vllm/vllm-openai:qwen38-flash-next \
  -c "pip install -q wheel setuptools 'packaging>=24.2' ninja && cd /src && pip wheel . --no-deps --no-build-isolation -w /src/dist -q"
```
