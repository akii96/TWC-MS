# Together We Check - N-Run Stability

A universal, framework-agnostic stress testing tool for LLM serving infrastructure. Supports SGLang, vLLM, and other frameworks through a plugin system.

## Requirements

- Python 3.6+ with PyYAML
- Docker
- curl

Install PyYAML if not already installed:

```bash
pip3 install PyYAML
```

## Quick Start

```bash
export HF_TOKEN='hf_your_token_here'

# Use default config (config.yaml)
./stress_test.sh

# Use a preset
./stress_test.sh --config presets/sglang-glm4-rocm.yaml

# Override specific values
./stress_test.sh --loops 50 --image my-custom:latest

# Environment variable overrides
STRESS_LOOPS=10 STRESS_PORT=8080 ./stress_test.sh
```

## What It Does

For each iteration:

1. Launches a Docker container running the LLM server
2. Waits for the server health endpoint to become ready
3. Sends test prompts via the chat completions API
4. Checks responses against optional success patterns
5. Scans logs for error patterns (HSA errors, CUDA errors, etc.)
6. Tears down the container and records results

## Configuration

Each config file (or preset) is fully self-contained with all settings:

```yaml
framework: sglang  # or "vllm"

docker:
  image: lmsysorg/sglang:v0.5.8-rocm700-mi30x
  shm_size: 128G
  network: host
  devices:
    - /dev/kfd
    - /dev/dri

# Environment variables passed to the container
env:
  ROCM_QUICK_REDUCE_QUANTIZATION: INT4
  HSA_NO_SCRATCH_RECLAIM: 1
  SGLANG_USE_AITER: 1

server:
  port: 30000
  startup_timeout: 600
  model_path: zai-org/GLM-4.7-FP8

# Framework-specific server arguments
server_args:
  tp-size: 8
  mem-fraction-static: 0.8

timeouts:
  container: 900
  prompt: 120

test:
  num_loops: 20
  prompts_per_loop: 10
  success_pattern: "yes"

error_patterns:
  - HSA_STATUS_ERROR_EXCEPTION
  - CUDA error
```

### Test Prompts (`prompts.json`)

Configure test prompts and parameters:

```json
{
  "default_params": {
    "stream": false,
    "max_tokens": 3000,
    "temperature": 0.9
  },
  "prompts": [
    {
      "content": "only yes or no. is there winter in africa?",
      "expected_pattern": "yes"
    }
  ]
}
```

## CLI Options

| Option | Description |
|--------|-------------|
| `--config FILE` | Path to config file (default: config.yaml) |
| `--loops N` | Override number of test loops |
| `--image IMAGE` | Override Docker image |
| `--port PORT` | Override server port |
| `--framework NAME` | Override framework (sglang, vllm) |
| `--dry-run` | Show configuration without running tests |
| `--help` | Show help message |

## Environment Variable Overrides

Prefix any config option with `STRESS_` to override via environment:

```bash
STRESS_LOOPS=50 STRESS_IMAGE=my-image:latest ./stress_test.sh
```

## Presets

Ready-to-use configurations in `presets/`:

| Preset | Description |
|--------|-------------|
| `sglang-glm4-rocm.yaml` | GLM-4.7-FP8 on AMD MI300X with SGLang |
| `vllm-llama-rocm.yaml` | Llama-3.1-8B on AMD GPUs with vLLM |
| `vllm-qwen-cuda.yaml` | Qwen2.5-7B on NVIDIA GPUs with vLLM |
| `sglang-qwen-cuda.yaml` | Qwen2.5-7B on NVIDIA GPUs with SGLang |

## Adding New Frameworks

Create a plugin file in `plugins/` implementing these functions:

```bash
# plugins/myframework.plugin.sh

build_server_cmd()      # Build the server launch command
get_health_endpoint()   # Return health check URL path
get_chat_endpoint()     # Return chat completions URL path
build_chat_payload()    # Build the prompt JSON payload
parse_chat_response()   # Extract content from API response
get_docker_entrypoint() # Return entrypoint override (optional)
```

Then set `framework: myframework` in your config.

## Output

Each run creates a timestamped directory:

```
sglang_stress_<image_slug>_<timestamp>/
├── summary.log              # Overall run summary
├── iter_1_<ts>_SUCCESS.log  # Per-iteration container logs
├── iter_2_<ts>_FAIL.log
└── ...
```

## Success Criteria

An iteration is marked **SUCCESS** if:

- Server becomes ready within timeout
- All prompts return responses
- All responses match the success pattern (if specified)
- No error patterns found in logs

Otherwise, it's marked **FAIL**.

## Exit Code

- `0` — All iterations passed
- `1` — At least one iteration failed

## File Structure

```
n-run-stability/
├── stress_test.sh           # Main runner (framework-agnostic)
├── config.yaml              # Primary configuration
├── prompts.json             # Test prompts
├── plugins/
│   ├── sglang.plugin.sh     # SGLang framework plugin
│   └── vllm.plugin.sh       # vLLM framework plugin
├── presets/
│   ├── sglang-glm4-rocm.yaml
│   ├── vllm-llama-rocm.yaml
│   ├── vllm-qwen-cuda.yaml
│   └── sglang-qwen-cuda.yaml
└── README.md
```
