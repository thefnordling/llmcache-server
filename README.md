# llmcache-server

Thin Docker overlay that replaces stock LMCache in a vLLM image with a build that
correctly stores and retrieves KV for **hybrid (Mamba/GDN/circular-buffer) models**
on the LMCache multi-process (MP) server.

Built for the Qwen3.8-Flash-Next GDN-hybrid deployment; fixes two silent no-op
defects that made the MP connector useless on hybrid models (zero stores, zero
lookup hits).

## Contents

- `Dockerfile` — **multi-stage** overlay; no binary artifacts in this repo.
  1. `lmcache-src` (alpine): clones the fork, checks out the pinned commit
     (`git rev-parse` verified), exports it via `git archive`.
  2. `lmcache-wheel`: builds the wheel from that exact tree inside the same
     CUDA/torch environment as the final image (native extensions must match
     the runtime torch).
  3. final: `COPY`s the freshly built wheel into the vLLM base and
     force-installs it. The image carries an
     `io.llmcache.source-commit` label.

  Build args: `LMCACHE_REPO`, `LMCACHE_BRANCH`, `LMCACHE_COMMIT` (pin),
  `VLLM_BASE` (the vLLM image to overlay; must exist locally — the default is
  a custom home-built image).

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

Requires the `vllm/vllm-openai:qwen38-flash-next` base image locally (custom
build; point `VLLM_BASE` at your own vLLM image otherwise). The wheel is
compiled during the build (~5 min), so no prebuilt blob is trusted:

```bash
docker build -t vllm/vllm-openai:qwen38-flash-next-pr4772-gate .
docker inspect vllm/vllm-openai:qwen38-flash-next-pr4772-gate   --format '{{ index .Config.Labels "io.llmcache.source-commit" }}'
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
