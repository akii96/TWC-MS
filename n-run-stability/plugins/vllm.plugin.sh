#!/bin/bash
###############################################################################
# vllm.plugin.sh - vLLM Framework Plugin
#
# This plugin provides vLLM-specific implementations for the universal
# stress test runner.
###############################################################################

PLUGIN_NAME="vllm"
PLUGIN_VERSION="1.0.0"

# Build the server launch command for vLLM
# Arguments:
#   $1 - model_path: Path or HuggingFace model ID
#   $2 - port: Server port number
#   $3 - extra_args: Additional CLI arguments (space-separated)
# Returns: The complete launch command string
build_server_cmd() {
    local model_path="$1"
    local port="$2"
    local extra_args="$3"
    
    echo "vllm serve ${model_path} --port ${port} ${extra_args}"
}

# Get the health check endpoint path
# Returns: URL path for health check
get_health_endpoint() {
    echo "/health"
}

# Get the chat completions endpoint path
# Returns: URL path for chat completions API
get_chat_endpoint() {
    echo "/v1/chat/completions"
}

# Get the completions endpoint path (non-chat)
# Returns: URL path for completions API
get_completions_endpoint() {
    echo "/v1/completions"
}

# Build the prompt payload for chat completions
# Arguments:
#   $1 - model: Model name/path
#   $2 - prompt_content: The user message content
#   $3 - default_params_json: JSON string of default parameters
#   $4 - extra_params_json: JSON string of extra parameters (optional)
# Returns: JSON payload string
build_chat_payload() {
    local model="$1"
    local prompt_content="$2"
    local default_params_json="$3"
    local extra_params_json="${4:-{}}"
    
    python3 -c "
import json
import sys

model = sys.argv[1]
content = sys.argv[2]
default_params = json.loads(sys.argv[3])
extra_params = json.loads(sys.argv[4])

# vLLM doesn't support all SGLang params, filter them
vllm_params = {}
supported_keys = ['stream', 'max_tokens', 'temperature', 'top_p', 'top_k', 
                  'presence_penalty', 'frequency_penalty', 'stop', 'n']
for key in supported_keys:
    if key in default_params:
        vllm_params[key] = default_params[key]

payload = {
    'model': model,
    'messages': [{'role': 'user', 'content': content}],
    **vllm_params
}

print(json.dumps(payload))
" "$model" "$prompt_content" "$default_params_json" "$extra_params_json"
}

# Parse the response from chat completions endpoint
# Arguments:
#   $1 - response: Raw JSON response from the API
# Returns: Extracted content string, or "PARSE_ERROR: <details>" on failure
parse_chat_response() {
    local response="$1"
    
    python3 -c "
import sys
import json

try:
    d = json.loads(sys.argv[1])
    content = d['choices'][0]['message']['content']
    print(content)
except Exception as e:
    print(f'PARSE_ERROR: {e}')
" "$response"
}

# Get default Docker entrypoint override (if needed)
# Returns: Entrypoint command or empty string for default
get_docker_entrypoint() {
    # vLLM images often have a vllm entrypoint that needs to be overridden
    echo "/bin/bash"
}

# Get any required volume mounts specific to this framework
# Returns: Space-separated list of -v mount flags
get_extra_mounts() {
    echo ""  # No extra mounts needed for vLLM by default
}

# Validate framework-specific configuration
# Arguments:
#   $1 - config_file: Path to the config.yaml
# Returns: 0 if valid, 1 if invalid (with error message to stderr)
validate_config() {
    local config_file="$1"
    # vLLM requires model_path at minimum
    return 0
}

# vLLM-specific: Build a launch script for complex commands
# This avoids nested quoting issues with docker run
# Arguments:
#   $1 - model_path: Model to serve
#   $2 - port: Server port
#   $3 - extra_args: Additional arguments
# Returns: Path to temporary launch script
build_launch_script() {
    local model_path="$1"
    local port="$2"
    local extra_args="$3"
    
    local script_path=$(mktemp /tmp/vllm_launch_XXXXXX.sh)
    cat > "$script_path" <<EOF
#!/bin/bash
exec vllm serve ${model_path} --port ${port} ${extra_args}
EOF
    chmod +x "$script_path"
    echo "$script_path"
}
