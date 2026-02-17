#!/bin/bash
###############################################################################
# stress_test.sh - Universal LLM Serving Stress Test
#
# A framework-agnostic stress testing tool for LLM serving infrastructure.
# Supports SGLang, vLLM, and other frameworks through a plugin system.
#
# Usage:
#   ./stress_test.sh [OPTIONS]
#
# Options:
#   --config FILE       Path to config file (default: config.yaml)
#   --loops N           Override number of test loops
#   --image IMAGE       Override Docker image
#   --port PORT         Override server port
#   --framework NAME    Override framework (sglang, vllm, etc.)
#   --dry-run           Show configuration without running tests
#   --help              Show this help message
#
# Environment variable overrides (prefix with STRESS_):
#   STRESS_LOOPS, STRESS_IMAGE, STRESS_PORT, STRESS_FRAMEWORK
#
# Examples:
#   ./stress_test.sh
#   ./stress_test.sh --config presets/vllm-llama.yaml
#   ./stress_test.sh --loops 50 --image my-custom:latest
#   STRESS_LOOPS=10 ./stress_test.sh
###############################################################################

set -uo pipefail

# ── Python interpreter ───────────────────────────────────────────────────────
# Use system Python with PyYAML (prefer /usr/bin/python3 if available)
if /usr/bin/python3 -c "import yaml" 2>/dev/null; then
    PYTHON="/usr/bin/python3"
elif python3 -c "import yaml" 2>/dev/null; then
    PYTHON="python3"
else
    echo "ERROR: PyYAML not found. Install with: pip3 install PyYAML" >&2
    exit 1
fi

# ── Script directory ─────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Default paths ────────────────────────────────────────────────────────────
DEFAULT_CONFIG="$SCRIPT_DIR/config.yaml"
DEFAULT_PROMPTS="$SCRIPT_DIR/prompts.json"
PLUGINS_DIR="$SCRIPT_DIR/plugins"

# ── CLI argument defaults ────────────────────────────────────────────────────
CONFIG_FILE=""
CLI_LOOPS=""
CLI_IMAGE=""
CLI_PORT=""
CLI_FRAMEWORK=""
DRY_RUN=false

# ── Colors for output ────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

###############################################################################
# HELPER FUNCTIONS
###############################################################################

show_help() {
    head -40 "$0" | grep -E '^#' | sed 's/^# \?//'
    exit 0
}

die() {
    echo -e "${RED}ERROR:${NC} $*" >&2
    exit 1
}

warn() {
    echo -e "${YELLOW}WARNING:${NC} $*" >&2
}

info() {
    echo -e "${BLUE}INFO:${NC} $*"
}

# Check for required dependencies
check_dependencies() {
    local missing=()
    
    # Check for Python (required for YAML/JSON parsing)
    if ! command -v python3 &>/dev/null; then
        missing+=("python3")
    fi
    
    # Check for jq (optional but recommended)
    if ! command -v jq &>/dev/null; then
        warn "jq not found. Using Python for JSON parsing (slower)."
    fi
    
    # Check for docker
    if ! command -v docker &>/dev/null; then
        missing+=("docker")
    fi
    
    # Check for curl
    if ! command -v curl &>/dev/null; then
        missing+=("curl")
    fi
    
    if [ ${#missing[@]} -gt 0 ]; then
        die "Missing required dependencies: ${missing[*]}"
    fi
}

# Parse YAML using Python with PyYAML
yaml_get() {
    local file="$1"
    local key="$2"
    local default="${3:-}"
    
    $PYTHON -c "
import yaml
import sys
import json

def get_nested(d, keys):
    for key in keys.split('.'):
        if isinstance(d, dict) and key in d:
            d = d[key]
        else:
            return None
    return d

try:
    with open('$file', 'r') as f:
        data = yaml.safe_load(f)
    result = get_nested(data, '$key')
    if result is None:
        print('$default')
    elif isinstance(result, list):
        print('\\n'.join(str(x) for x in result))
    elif isinstance(result, dict):
        print(json.dumps(result))
    else:
        print(result)
except Exception as e:
    print('$default', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null || echo "$default"
}

# Get YAML list as array
yaml_get_list() {
    local file="$1"
    local key="$2"
    
    $PYTHON -c "
import yaml
import sys

def get_nested(d, keys):
    for key in keys.split('.'):
        if isinstance(d, dict) and key in d:
            d = d[key]
        else:
            return []
    return d if isinstance(d, list) else []

try:
    with open('$file', 'r') as f:
        data = yaml.safe_load(f)
    result = get_nested(data, '$key')
    for item in result:
        print(item)
except:
    pass
"
}

# Convert server_args dict to CLI flags
yaml_args_to_flags() {
    local file="$1"
    local key="$2"
    
    $PYTHON -c "
import yaml
import json

def get_nested(d, keys):
    for key in keys.split('.'):
        if isinstance(d, dict) and key in d:
            d = d[key]
        else:
            return {}
    return d if isinstance(d, dict) else {}

try:
    with open('$file', 'r') as f:
        data = yaml.safe_load(f)
    args = get_nested(data, '$key')
    flags = []
    for k, v in args.items():
        if isinstance(v, bool):
            if v:
                flags.append(f'--{k}')
        elif isinstance(v, dict):
            flags.append(f'--{k}')
            flags.append(\"'\" + json.dumps(v) + \"'\")
        else:
            flags.append(f'--{k}')
            flags.append(str(v))
    print(' '.join(flags))
except:
    pass
"
}

# Read JSON prompts file
json_get() {
    local file="$1"
    local key="$2"
    local default="${3:-}"
    
    if command -v jq &>/dev/null; then
        jq -r "$key // \"$default\"" "$file" 2>/dev/null || echo "$default"
    else
        $PYTHON -c "
import json
import sys

try:
    with open('$file', 'r') as f:
        data = json.load(f)
    # Simple key access (doesn't support full jq syntax)
    keys = '$key'.strip('.').split('.')
    result = data
    for k in keys:
        if k and isinstance(result, dict):
            result = result.get(k)
    if result is None:
        print('$default')
    elif isinstance(result, (dict, list)):
        print(json.dumps(result))
    else:
        print(result)
except:
    print('$default')
"
    fi
}

# Build environment flags from YAML config env section
build_env_flags_from_yaml() {
    local config_file="$1"
    
    $PYTHON -c "
import yaml

try:
    with open('$config_file', 'r') as f:
        data = yaml.safe_load(f)
    env_vars = data.get('env', {})
    if env_vars:
        flags = []
        for k, v in env_vars.items():
            flags.append(f'-e {k}={v}')
        print(' '.join(flags))
except:
    pass
"
}

# Log to both stdout and summary file
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    [ -n "${SUMMARY_LOG:-}" ] && echo "$msg" >> "$SUMMARY_LOG"
}

# Kill container and watchdog
cleanup_container() {
    local name="$1"
    if docker ps -q -f name="$name" 2>/dev/null | grep -q .; then
        log "  Stopping container $name ..."
        docker rm -f "$name" >/dev/null 2>&1 || true
    fi
    if [ -n "${WATCHDOG_PID:-}" ] && kill -0 "$WATCHDOG_PID" 2>/dev/null; then
        kill "$WATCHDOG_PID" 2>/dev/null || true
        wait "$WATCHDOG_PID" 2>/dev/null || true
    fi
    if [ -n "${LOGS_PID:-}" ] && kill -0 "$LOGS_PID" 2>/dev/null; then
        kill "$LOGS_PID" 2>/dev/null || true
        wait "$LOGS_PID" 2>/dev/null || true
    fi
}

###############################################################################
# ARGUMENT PARSING
###############################################################################

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            --loops)
                CLI_LOOPS="$2"
                shift 2
                ;;
            --image)
                CLI_IMAGE="$2"
                shift 2
                ;;
            --port)
                CLI_PORT="$2"
                shift 2
                ;;
            --framework)
                CLI_FRAMEWORK="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --help|-h)
                show_help
                ;;
            *)
                die "Unknown option: $1. Use --help for usage."
                ;;
        esac
    done
}

###############################################################################
# CONFIGURATION LOADING
###############################################################################

load_config() {
    # Determine config file path
    if [ -n "$CONFIG_FILE" ]; then
        [ -f "$CONFIG_FILE" ] || die "Config file not found: $CONFIG_FILE"
    else
        CONFIG_FILE="$DEFAULT_CONFIG"
        [ -f "$CONFIG_FILE" ] || die "Default config not found: $CONFIG_FILE"
    fi
    
    info "Loading configuration from: $CONFIG_FILE"
    
    # Load base config from YAML
    FRAMEWORK=$(yaml_get "$CONFIG_FILE" "framework" "sglang")
    DOCKER_IMAGE=$(yaml_get "$CONFIG_FILE" "docker.image" "")
    SHM_SIZE=$(yaml_get "$CONFIG_FILE" "docker.shm_size" "128G")
    NETWORK_MODE=$(yaml_get "$CONFIG_FILE" "docker.network" "host")
    SERVER_PORT=$(yaml_get "$CONFIG_FILE" "server.port" "30000")
    SERVER_STARTUP_TIMEOUT=$(yaml_get "$CONFIG_FILE" "server.startup_timeout" "600")
    MODEL_PATH=$(yaml_get "$CONFIG_FILE" "server.model_path" "")
    CONTAINER_TIMEOUT=$(yaml_get "$CONFIG_FILE" "timeouts.container" "900")
    PROMPT_TIMEOUT=$(yaml_get "$CONFIG_FILE" "timeouts.prompt" "120")
    NUM_LOOPS=$(yaml_get "$CONFIG_FILE" "test.num_loops" "20")
    PROMPTS_PER_LOOP=$(yaml_get "$CONFIG_FILE" "test.prompts_per_loop" "10")
    SUCCESS_PATTERN=$(yaml_get "$CONFIG_FILE" "test.success_pattern" "")
    WORKSPACE_BASE=$(yaml_get "$CONFIG_FILE" "workspace.base_dir" "\$HOME")
    
    # Expand $HOME in workspace base
    WORKSPACE_BASE="${WORKSPACE_BASE/\$HOME/$HOME}"
    
    # Get server args as CLI flags
    SERVER_ARGS=$(yaml_args_to_flags "$CONFIG_FILE" "server_args")
    
    # Get device list
    mapfile -t DOCKER_DEVICES < <(yaml_get_list "$CONFIG_FILE" "docker.devices")
    
    # Get error patterns
    mapfile -t ERROR_PATTERNS < <(yaml_get_list "$CONFIG_FILE" "error_patterns")
    
    # Get workspace mounts
    mapfile -t WORKSPACE_MOUNTS < <(yaml_get_list "$CONFIG_FILE" "workspace.mounts")
    
    # Apply environment variable overrides (STRESS_*)
    [ -n "${STRESS_LOOPS:-}" ] && NUM_LOOPS="$STRESS_LOOPS"
    [ -n "${STRESS_IMAGE:-}" ] && DOCKER_IMAGE="$STRESS_IMAGE"
    [ -n "${STRESS_PORT:-}" ] && SERVER_PORT="$STRESS_PORT"
    [ -n "${STRESS_FRAMEWORK:-}" ] && FRAMEWORK="$STRESS_FRAMEWORK"
    
    # Apply CLI overrides (highest priority)
    [ -n "$CLI_LOOPS" ] && NUM_LOOPS="$CLI_LOOPS"
    [ -n "$CLI_IMAGE" ] && DOCKER_IMAGE="$CLI_IMAGE"
    [ -n "$CLI_PORT" ] && SERVER_PORT="$CLI_PORT"
    [ -n "$CLI_FRAMEWORK" ] && FRAMEWORK="$CLI_FRAMEWORK"
    
    # Validate required fields
    [ -z "$DOCKER_IMAGE" ] && die "Docker image not specified. Set docker.image in config or use --image"
    [ -z "$MODEL_PATH" ] && die "Model path not specified. Set server.model_path in config"
    
    # Load prompts configuration
    PROMPTS_FILE="$DEFAULT_PROMPTS"
    if [ -f "$PROMPTS_FILE" ]; then
        DEFAULT_PARAMS=$(json_get "$PROMPTS_FILE" ".default_params" "{}")
        EXTRA_PARAMS=$(json_get "$PROMPTS_FILE" ".extra_params" "{}")
        PROMPT_CONTENT=$(json_get "$PROMPTS_FILE" ".prompts[0].content" "Hello, how are you?")
    else
        warn "Prompts file not found: $PROMPTS_FILE. Using defaults."
        DEFAULT_PARAMS='{"stream": false, "max_tokens": 512}'
        EXTRA_PARAMS='{}'
        PROMPT_CONTENT="Hello, how are you?"
    fi
    
    # Load environment variables from config
    ENV_FLAGS=$(build_env_flags_from_yaml "$CONFIG_FILE")
}

###############################################################################
# PLUGIN LOADING
###############################################################################

load_plugin() {
    local plugin_file="$PLUGINS_DIR/${FRAMEWORK}.plugin.sh"
    
    if [ ! -f "$plugin_file" ]; then
        die "Plugin not found for framework '$FRAMEWORK': $plugin_file"
    fi
    
    info "Loading plugin: $plugin_file"
    # shellcheck source=/dev/null
    source "$plugin_file"
    
    # Verify required functions exist
    for func in build_server_cmd get_health_endpoint get_chat_endpoint parse_chat_response build_chat_payload; do
        if ! declare -f "$func" &>/dev/null; then
            die "Plugin '$FRAMEWORK' missing required function: $func"
        fi
    done
}

###############################################################################
# DRY RUN OUTPUT
###############################################################################

show_dry_run() {
    echo ""
    echo "============================================================"
    echo "  DRY RUN - Configuration Summary"
    echo "============================================================"
    echo ""
    echo "Framework:        $FRAMEWORK"
    echo "Docker Image:     $DOCKER_IMAGE"
    echo "Model Path:       $MODEL_PATH"
    echo "Server Port:      $SERVER_PORT"
    echo "Server Args:      $SERVER_ARGS"
    echo ""
    echo "Test Loops:       $NUM_LOOPS"
    echo "Prompts/Loop:     $PROMPTS_PER_LOOP"
    echo "Success Pattern:  ${SUCCESS_PATTERN:-<none>}"
    echo ""
    echo "Timeouts:"
    echo "  Container:      ${CONTAINER_TIMEOUT}s"
    echo "  Server Startup: ${SERVER_STARTUP_TIMEOUT}s"
    echo "  Prompt:         ${PROMPT_TIMEOUT}s"
    echo ""
    echo "Docker Settings:"
    echo "  SHM Size:       $SHM_SIZE"
    echo "  Network:        $NETWORK_MODE"
    echo "  Devices:        ${DOCKER_DEVICES[*]:-<none>}"
    echo ""
    echo "Environment Vars: ${ENV_FLAGS:-<none>}"
    echo ""
    echo "Error Patterns:   ${ERROR_PATTERNS[*]:-<none>}"
    echo ""
    echo "Server Command:"
    echo "  $(build_server_cmd "$MODEL_PATH" "$SERVER_PORT" "$SERVER_ARGS")"
    echo ""
    echo "============================================================"
    exit 0
}

###############################################################################
# MAIN TEST LOOP
###############################################################################

run_stress_test() {
    # Check HF token
    if [[ -z "${HF_TOKEN:-}" ]]; then
        echo ""
        echo -e "${RED}ERROR:${NC} HF_TOKEN environment variable is not set."
        echo ""
        echo "  Set it before running this script:"
        echo ""
        echo "    export HF_TOKEN='hf_your_token_here'"
        echo "    $0 [OPTIONS]"
        echo ""
        echo "  You can generate a token at: https://huggingface.co/settings/tokens"
        echo ""
        exit 1
    fi
    
    # Create output directory
    IMAGE_SLUG=$(echo "$DOCKER_IMAGE" | sed 's/[\/:]/_/g')
    RUN_DIR="$WORKSPACE_BASE/${FRAMEWORK}_stress_${IMAGE_SLUG}_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$RUN_DIR"
    
    SUMMARY_LOG="$RUN_DIR/summary.log"
    
    # Counters
    SUCCESS_COUNT=0
    FAIL_COUNT=0
    
    # Build server command using plugin
    SERVER_CMD=$(build_server_cmd "$MODEL_PATH" "$SERVER_PORT" "$SERVER_ARGS")
    HEALTH_ENDPOINT=$(get_health_endpoint)
    CHAT_ENDPOINT=$(get_chat_endpoint)
    
    # Get docker entrypoint override from plugin
    DOCKER_ENTRYPOINT=$(get_docker_entrypoint 2>/dev/null || echo "")
    
    log "============================================================"
    log "Universal Stress Test - $FRAMEWORK"
    log "  Docker image : $DOCKER_IMAGE"
    log "  Model        : $MODEL_PATH"
    log "  Loops        : $NUM_LOOPS"
    log "  Timeout      : ${CONTAINER_TIMEOUT}s ($(( CONTAINER_TIMEOUT / 60 )) min)"
    log "  Results dir  : $RUN_DIR"
    log "============================================================"
    
    for (( i=1; i<=NUM_LOOPS; i++ )); do
        ITER_START=$(date +%s)
        ITER_TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
        CONTAINER_NAME="${FRAMEWORK}_stress_iter${i}_$$"
        ITER_LOG="$RUN_DIR/iter_${i}_${ITER_TIMESTAMP}.log"
        ITER_STATUS="FAIL"
        
        log ""
        log "────────────────────────────────────────────────────────────"
        log "  Iteration $i / $NUM_LOOPS   (container: $CONTAINER_NAME)"
        log "────────────────────────────────────────────────────────────"
        
        # Clean up any leftover container
        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
        
        # Build docker run command
        DOCKER_CMD=(
            docker run
            -d
            --cap-add=SYS_PTRACE
            --cap-add=CAP_SYS_ADMIN
            --security-opt seccomp=unconfined
            --user root
            --ulimit memlock=999332768:999332768
            --ipc=host
            --name "$CONTAINER_NAME"
            --shm-size="$SHM_SIZE"
            --hostname "STRESS-$(echo "${HOSTNAME:-$(hostname)}" | cut -f 1 -d .)"
            --network "$NETWORK_MODE"
        )
        
        # Add devices
        for device in "${DOCKER_DEVICES[@]}"; do
            DOCKER_CMD+=(--device="$device")
        done
        
        # Add group for video (AMD GPUs)
        if [[ " ${DOCKER_DEVICES[*]} " =~ "/dev/kfd" ]]; then
            DOCKER_CMD+=(--group-add video)
        fi
        
        # Add workspace mounts
        DOCKER_CMD+=(-v "$WORKSPACE_BASE:/workspace/")
        for mount in "${WORKSPACE_MOUNTS[@]}"; do
            DOCKER_CMD+=(-v "$WORKSPACE_BASE/$mount:/workspace/$mount")
        done
        
        # Add HF token and home
        DOCKER_CMD+=(
            -e "HF_HOME=/workspace/.cache/huggingface"
            -e "HF_TOKEN=$HF_TOKEN"
        )
        
        # Add environment flags from envs.txt
        if [ -n "$ENV_FLAGS" ]; then
            # shellcheck disable=SC2206
            DOCKER_CMD+=($ENV_FLAGS)
        fi
        
        DOCKER_CMD+=(--workdir /workspace/)
        
        # Add entrypoint override if plugin specifies one
        if [ -n "$DOCKER_ENTRYPOINT" ]; then
            DOCKER_CMD+=(--entrypoint "$DOCKER_ENTRYPOINT")
        fi
        
        DOCKER_CMD+=("$DOCKER_IMAGE")
        DOCKER_CMD+=(bash -c "$SERVER_CMD")
        
        # Launch container
        log "  Starting Docker container ..."
        "${DOCKER_CMD[@]}" 2>&1 | tee -a "$ITER_LOG"
        
        # Watchdog: auto-kill after timeout
        (
            sleep "$CONTAINER_TIMEOUT"
            if docker ps -q -f name="$CONTAINER_NAME" 2>/dev/null | grep -q .; then
                echo "[WATCHDOG] Timeout reached (${CONTAINER_TIMEOUT}s). Killing $CONTAINER_NAME" >> "$ITER_LOG"
                docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
            fi
        ) &
        WATCHDOG_PID=$!
        
        # Stream container logs
        docker logs -f "$CONTAINER_NAME" > "$ITER_LOG" 2>&1 &
        LOGS_PID=$!
        
        # Wait for server readiness
        log "  Waiting for server to become ready (up to ${SERVER_STARTUP_TIMEOUT}s) ..."
        SERVER_READY=false
        ELAPSED=0
        while [ $ELAPSED -lt "$SERVER_STARTUP_TIMEOUT" ]; do
            if ! docker ps -q -f name="$CONTAINER_NAME" 2>/dev/null | grep -q .; then
                log "  Container died before server became ready."
                break
            fi
            
            HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
                --max-time 5 \
                "http://localhost:${SERVER_PORT}${HEALTH_ENDPOINT}" 2>/dev/null) || true
            
            if [ "$HTTP_CODE" = "200" ]; then
                SERVER_READY=true
                log "  Server is ready! (took ~${ELAPSED}s)"
                break
            fi
            
            sleep 5
            ELAPSED=$(( ELAPSED + 5 ))
        done
        
        if [ "$SERVER_READY" = false ]; then
            log "  FAIL: Server did not become ready within ${SERVER_STARTUP_TIMEOUT}s or container died."
            cleanup_container "$CONTAINER_NAME"
            FAIL_COUNT=$(( FAIL_COUNT + 1 ))
            ITER_END=$(date +%s)
            log "  Iteration $i finished in $(( ITER_END - ITER_START ))s — FAIL (server not ready)"
            continue
        fi
        
        # Send prompts
        PROMPTS_OK=true
        ALL_MATCH=true
        for p in $(seq 1 "$PROMPTS_PER_LOOP"); do
            log "  Sending prompt $p/$PROMPTS_PER_LOOP ..."
            
            # Build payload using plugin
            PAYLOAD=$(build_chat_payload "$MODEL_PATH" "$PROMPT_CONTENT" "$DEFAULT_PARAMS" "$EXTRA_PARAMS")
            
            RESPONSE=$(curl -s --max-time "$PROMPT_TIMEOUT" \
                -X POST "http://localhost:${SERVER_PORT}${CHAT_ENDPOINT}" \
                -H "accept: */*" \
                -H "Content-Type: application/json" \
                -d "$PAYLOAD" 2>/dev/null) || RESPONSE=""
            
            if [ -z "$RESPONSE" ]; then
                log "  FAIL: Prompt $p/$PROMPTS_PER_LOOP — no response (timeout or connection error)."
                PROMPTS_OK=false
                break
            fi
            
            # Parse response using plugin
            CONTENT=$(parse_chat_response "$RESPONSE")
            
            log "  Prompt $p response: $CONTENT"
            
            # Save raw response to log
            {
                echo "--- Prompt $p response ---"
                echo "$RESPONSE"
                echo ""
            } >> "$ITER_LOG"
            
            # Check success pattern if specified
            if [ -n "$SUCCESS_PATTERN" ]; then
                if ! echo "$CONTENT" | grep -qi "$SUCCESS_PATTERN"; then
                    ALL_MATCH=false
                    log "  WARNING: Prompt $p/$PROMPTS_PER_LOOP answer does not match pattern '$SUCCESS_PATTERN'."
                fi
            fi
        done
        
        # Check for error patterns in logs
        ERROR_FOUND=false
        sleep 2  # Give logs time to flush
        for pattern in "${ERROR_PATTERNS[@]}"; do
            if grep -q "$pattern" "$ITER_LOG" 2>/dev/null; then
                ERROR_FOUND=true
                log "  FAIL: Found error pattern '$pattern' in logs."
                break
            fi
        done
        
        # Determine success/failure
        if [ "$PROMPTS_OK" = true ] && [ "$ALL_MATCH" = true ] && [ "$ERROR_FOUND" = false ]; then
            ITER_STATUS="SUCCESS"
            SUCCESS_COUNT=$(( SUCCESS_COUNT + 1 ))
        else
            ITER_STATUS="FAIL"
            FAIL_COUNT=$(( FAIL_COUNT + 1 ))
        fi
        
        # Tear down
        cleanup_container "$CONTAINER_NAME"
        
        # Rename log file to include status
        FINAL_LOG="$RUN_DIR/iter_${i}_${ITER_TIMESTAMP}_${ITER_STATUS}.log"
        mv "$ITER_LOG" "$FINAL_LOG"
        
        ITER_END=$(date +%s)
        log "  Iteration $i finished in $(( ITER_END - ITER_START ))s — $ITER_STATUS"
    done
    
    # Summary
    log ""
    log "============================================================"
    log "  STRESS TEST COMPLETE"
    log "============================================================"
    log "  Framework    : $FRAMEWORK"
    log "  Docker image : $DOCKER_IMAGE"
    log "  Model        : $MODEL_PATH"
    log "  Total runs   : $NUM_LOOPS"
    log "  Successes    : $SUCCESS_COUNT"
    log "  Failures     : $FAIL_COUNT"
    log "  Pass rate    : $(( SUCCESS_COUNT * 100 / NUM_LOOPS ))%"
    log "  Results dir  : $RUN_DIR"
    log "============================================================"
    
    # Exit with non-zero if any failures
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
    exit 0
}

###############################################################################
# MAIN
###############################################################################

main() {
    parse_args "$@"
    check_dependencies
    load_config
    load_plugin
    
    if [ "$DRY_RUN" = true ]; then
        show_dry_run
    else
        run_stress_test
    fi
}

main "$@"
