# TWC - Together We Check

A collection of tools for testing and validating LLM serving infrastructure.

## Tools

| Directory | Description | vLLM | SGLang |
|-----------|-------------|:----:|:------:|
| [`model-sanity/`](model-sanity/) | Multi-model sanity checker — validates model serving across `v1/chat/completions` and `v1/completions` endpoints | :white_check_mark: | :x: |
| [`n-run-stability/`](n-run-stability/) | Universal stress tester — repeatedly launches and tests a model to catch intermittent failures | :white_check_mark: | :white_check_mark: |


## Quick Start

```bash
# Model sanity check (vLLM)
cd model-sanity
export HF_TOKEN='hf_your_token_here'
./run_sanity_check.sh

# Stability stress test (Universal - supports SGLang and vLLM)
cd n-run-stability
export HF_TOKEN='hf_your_token_here'

# Default config (SGLang)
./stress_test.sh

# Use a preset
./stress_test.sh --config presets/vllm-llama-rocm.yaml

# Override options
./stress_test.sh --loops 50 --framework vllm --image vllm/vllm-openai:latest
```

See individual tool READMEs for detailed usage.
