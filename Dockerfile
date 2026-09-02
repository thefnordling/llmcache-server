# Multi-stage overlay: rebuilds the LMCache wheel from public source, so the
# image's provenance is a git commit you can check out yourself — no binary
# blobs, no release-asset trust required.
#
#   docker build -t vllm/vllm-openai:qwen38-flash-next-pr4772-gate .
#
# The wheel stage runs inside the same CUDA/torch environment as the final
# image (the native extensions must match the runtime torch exactly), which is
# also why the base is an ARG: point VLLM_BASE at your own vLLM build.
ARG VLLM_BASE=vllm/vllm-openai:qwen38-flash-next

# ---- Stage 1: clone + pin the exact commit to build -----------------------
FROM alpine:3.20 AS lmcache-src
ARG LMCACHE_REPO=https://github.com/thefnordling/LMCache.git
ARG LMCACHE_BRANCH=pr4772-gate-validation
ARG LMCACHE_COMMIT=5065d6ab9836f9282c754eb21b24f3a962e9bdba
RUN apk add --no-cache git \
 && git clone --branch "${LMCACHE_BRANCH}" "${LMCACHE_REPO}" /LMCache \
 && cd /LMCache \
 && git checkout --detach "${LMCACHE_COMMIT}" \
 && test "$(git rev-parse HEAD)" = "${LMCACHE_COMMIT}" \
 && git archive --format=tar -o /src.tar HEAD

# ---- Stage 2: build the wheel in the matching CUDA/torch toolchain --------
FROM ${VLLM_BASE} AS lmcache-wheel
ENV TORCH_CUDA_ARCH_LIST=12.0 \
    SETUPTOOLS_SCM_PRETEND_VERSION=0.5.5rc2.dev16 \
    CPATH=/usr/local/lib/python3.12/dist-packages/nvidia/cu13/include \
    LIBRARY_PATH=/usr/local/lib/python3.12/dist-packages/nvidia/cu13/lib
COPY --from=lmcache-src /src.tar /src.tar
RUN mkdir -p /src && tar -xf /src.tar -C /src \
 && pip install -q wheel setuptools 'packaging>=24.2' ninja \
 && cd /src && pip wheel . --no-deps --no-build-isolation -w /wheels -q

# ---- Stage 3: final image = base + freshly built wheel --------------------
FROM ${VLLM_BASE}
ARG LMCACHE_COMMIT=5065d6ab9836f9282c754eb21b24f3a962e9bdba
LABEL io.llmcache.source-commit="${LMCACHE_COMMIT}" \
      io.llmcache.source-repo="https://github.com/thefnordling/LMCache"
COPY --from=lmcache-wheel /wheels/lmcache-*.whl /tmp/
RUN pip install --force-reinstall --no-deps /tmp/lmcache-*.whl \
 && rm -f /tmp/lmcache-*.whl \
 && python3 -c "import lmcache; print(lmcache.__version__)"
