FROM vllm/vllm-openai:qwen38-flash-next
# Overlay: dev tip 56e45ff7 + PR 4772 (6ca03b45) + hybrid fix (5065d6ab)
# branch thefnordling/LMCache:pr4772-gate-validation
# Wheel: GitHub release asset of this repo (public; no auth needed at build).
# Override LMCACHE_WHEEL_URL to pin a different release.
ARG LMCACHE_WHEEL_URL=https://github.com/thefnordling/llmcache-server/releases/download/v0.5.5rc2.dev16/lmcache-0.5.5rc2.dev16-cp312-cp312-linux_x86_64.whl
ADD ${LMCACHE_WHEEL_URL} /tmp/lmcache.whl
RUN echo "108bae056c57270f51ec0eb53968681206b67b39eee974d12985e8eec2ef457f  /tmp/lmcache.whl" | sha256sum -c - \
 && pip install --force-reinstall --no-deps /tmp/lmcache.whl \
 && rm -f /tmp/lmcache.whl \
 && python3 -c "import lmcache; print(lmcache.__version__)"
