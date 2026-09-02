FROM vllm/vllm-openai:qwen38-flash-next
# Overlay: dev tip 56e45ff7 + PR 4772 (6ca03b45) + hybrid fix (5065d6ab)
# branch thefnordling/LMCache:pr4772-gate-validation
COPY lmcache-0.5.5rc2.dev16-cp312-cp312-linux_x86_64.whl /tmp/
RUN pip install --force-reinstall --no-deps /tmp/lmcache-0.5.5rc2.dev16-cp312-cp312-linux_x86_64.whl  && rm -rf /tmp/lmcache-*.whl  && python3 -c "import lmcache; print(lmcache.__version__)"
