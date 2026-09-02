# Multi-stage overlay: rebuilds the LMCache wheel from public source, so the
# image's provenance is a git branch you can check out yourself — no binary
# blobs, no commit SHAs to type or trust.
#
#   docker build -t vllm/vllm-openai:qwen38-flash-next-pr4772-gate .
#
# The only source reference is a branch name. At build time the clone writes
# down which commit the branch pointed at — a receipt, not an input — to
# /usr/local/share/llmcache-server/BUILD_INFO inside the final image, for
# auditors who care. Nobody has to know or read a SHA to build or use this.
#
# The wheel stage runs inside the same CUDA/torch environment as the final
# image (the native extensions must match the runtime torch exactly), which is
# also why the base is an ARG: point VLLM_BASE at your own vLLM build.
ARG VLLM_BASE=vllm/vllm-openai:qwen38-flash-next

# ---- Stage 1: clone the branch tip and freeze it for the build ------------
FROM alpine:3.20 AS lmcache-src
ARG LMCACHE_REPO=https://github.com/thefnordling/LMCache.git
ARG LMCACHE_BRANCH=feat-qwen38-flash-next-support
RUN apk add --no-cache git \
 && git clone --branch "${LMCACHE_BRANCH}" --single-branch "${LMCACHE_REPO}" /LMCache \
 && cd /LMCache \
 && printf 'repo=%s\nbranch=%s\ncommit=%s\n' \
      "${LMCACHE_REPO}" "${LMCACHE_BRANCH}" "$(git rev-parse HEAD)" > /BUILD_INFO \
 && git archive --format=tar -o /src.tar HEAD

# ---- Stage 2: build the wheel in the matching CUDA/torch toolchain --------
FROM ${VLLM_BASE} AS lmcache-wheel
ARG LMCACHE_VERSION=0.5.5rc2.dev17
ENV TORCH_CUDA_ARCH_LIST=12.0 \
    SETUPTOOLS_SCM_PRETEND_VERSION=${LMCACHE_VERSION} \
    CPATH=/usr/local/lib/python3.12/dist-packages/nvidia/cu13/include \
    LIBRARY_PATH=/usr/local/lib/python3.12/dist-packages/nvidia/cu13/lib
COPY --from=lmcache-src /src.tar /src.tar
RUN mkdir -p /src && tar -xf /src.tar -C /src \
 && pip install -q wheel setuptools 'packaging>=24.2' ninja \
 && cd /src && pip wheel . --no-deps --no-build-isolation -w /wheels -q

# ---- Stage 3: final image = base + freshly built wheel --------------------
FROM ${VLLM_BASE}
ARG LMCACHE_REPO=https://github.com/thefnordling/LMCache.git
ARG LMCACHE_BRANCH=feat-qwen38-flash-next-support
COPY --from=lmcache-src /BUILD_INFO /usr/local/share/llmcache-server/BUILD_INFO
COPY --from=lmcache-wheel /wheels/lmcache-*.whl /tmp/
RUN pip install --force-reinstall --no-deps /tmp/lmcache-*.whl \
 && rm -f /tmp/lmcache-*.whl \
 && python3 -c "import lmcache; print(lmcache.__version__)"
# The branch is the reference; BUILD_INFO records the commit it resolved to.
LABEL io.llmcache.source-repo="${LMCACHE_REPO}" \
      io.llmcache.source-branch="${LMCACHE_BRANCH}"
