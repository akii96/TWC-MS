#!/bin/bash
###############################################################################
# run_sanity_check.sh
#
# Multi-model vLLM sanity check: for every model in models.txt, launch a
# Docker container twice (once for v1/chat/completions, once for
# v1/completions), send 4 prompts each time, and record results to CSV.
#
# A per-model temporary HF cache is created and destroyed so the host cache
# is never polluted.
#
# Usage:
#   ./run_sanity_check.sh [docker_image]
#
# Examples:
#   ./run_sanity_check.sh                                        # uses default image
#   ./run_sanity_check.sh vllm/vllm-openai-rocm:v0.15.0         # explicit image
#   ./run_sanity_check.sh my-registry/vllm-custom:latest         # custom image
###############################################################################

set -uo pipefail
# Note: -e is intentionally omitted so we can handle errors gracefully.

# ── Args ────────────────────────────────────────────────────────────────────
DOCKER_IMAGE="${1:-vllm/vllm-openai-rocm:v0.15.0}"

# ── Paths ───────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENVS_FILE="$SCRIPT_DIR/envs.txt"
MODELS_FILE="$SCRIPT_DIR/models.txt"

# ── Config ──────────────────────────────────────────────────────────────────
SERVER_PORT=8000
SERVER_STARTUP_TIMEOUT=600      # 10 min max to wait for vllm readiness
PROMPT_TIMEOUT=180              # 3 min max per prompt request
CONTAINER_TIMEOUT=1200          # 20 min hard safety net per container

# HF token: must be set in the calling environment
if [[ -z "${HF_TOKEN:-}" ]]; then
    echo ""
    echo "ERROR: HF_TOKEN environment variable is not set."
    echo ""
    echo "  Set it before running this script:"
    echo ""
    echo "    export HF_TOKEN='hf_your_token_here'"
    echo "    ./run_sanity_check.sh"
    echo ""
    echo "  Or inline:"
    echo ""
    echo "    HF_TOKEN='hf_your_token_here' ./run_sanity_check.sh"
    echo ""
    echo "  You can generate a token at: https://huggingface.co/settings/tokens"
    echo ""
    exit 1
fi

# ── Output CSV ──────────────────────────────────────────────────────────────
RUN_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CSV_FILE="$SCRIPT_DIR/sanity_check_results_${RUN_TIMESTAMP}.csv"
LOG_DIR="$SCRIPT_DIR/logs_${RUN_TIMESTAMP}"
mkdir -p "$LOG_DIR"
SUMMARY_LOG="$LOG_DIR/summary.log"

# ── Prompts ─────────────────────────────────────────────────────────────────
PROMPTS=(
    "What is the fastest coastal animal"
    "What is the fastest coastal animal"
    "Explain electrons and the role they play in power grids in the style of a Shakespearean drama, ensuring each sentence contains at least one metaphor related to the natural world"
    "Explain electrons and the role they play in power grids in the style of a Shakespearean drama, ensuring each sentence contains at least one metaphor related to the natural world"
)

# ── Build Docker -e flags from envs.txt ─────────────────────────────────────
ENV_FLAGS=()
ENV_VARS_STR=""
while IFS= read -r line || [[ -n "$line" ]]; do
    line=$(echo "$line" | xargs)                 # trim whitespace
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    ENV_FLAGS+=( -e "$line" )
    [[ -n "$ENV_VARS_STR" ]] && ENV_VARS_STR+="; "
    ENV_VARS_STR+="$line"
done < "$ENVS_FILE"

# ── Read models ─────────────────────────────────────────────────────────────
MODELS=()
while IFS= read -r line || [[ -n "$line" ]]; do
    line=$(echo "$line" | xargs)
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    MODELS+=( "$line" )
done < "$MODELS_FILE"

# ── Helpers ─────────────────────────────────────────────────────────────────
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    echo "$msg" >> "$SUMMARY_LOG"
}

# Append a row to the CSV via Python (safe quoting for any response content)
append_csv() {
    python3 -c "
import csv, sys
with open(sys.argv[1], 'a', newline='') as f:
    csv.writer(f).writerow(sys.argv[2:])
" "$CSV_FILE" "$@"
}

# Kill container + watchdog
cleanup_container() {
    local name="$1"
    if docker ps -q -f name="^${name}$" 2>/dev/null | grep -q .; then
        log "  Stopping container $name ..."
        docker rm -f "$name" >/dev/null 2>&1 || true
    fi
    if [[ -n "${WATCHDOG_PID:-}" ]] && kill -0 "$WATCHDOG_PID" 2>/dev/null; then
        kill "$WATCHDOG_PID" 2>/dev/null || true
        wait "$WATCHDOG_PID" 2>/dev/null || true
    fi
    if [[ -n "${LOGS_PID:-}" ]] && kill -0 "$LOGS_PID" 2>/dev/null; then
        kill "$LOGS_PID" 2>/dev/null || true
        wait "$LOGS_PID" 2>/dev/null || true
    fi
}

# Wait for the vLLM health endpoint to return 200
wait_for_server() {
    local container_name="$1"
    local elapsed=0
    while (( elapsed < SERVER_STARTUP_TIMEOUT )); do
        # Bail if the container has died
        if ! docker ps -q -f name="^${container_name}$" 2>/dev/null | grep -q .; then
            log "  Container died before server became ready."
            return 1
        fi
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
            --max-time 5 \
            "http://localhost:${SERVER_PORT}/health" 2>/dev/null) || true
        if [[ "$HTTP_CODE" == "200" ]]; then
            log "  Server is ready! (took ~${elapsed}s)"
            return 0
        fi
        sleep 5
        elapsed=$(( elapsed + 5 ))
    done
    log "  FAIL: Server did not become ready within ${SERVER_STARTUP_TIMEOUT}s."
    return 1
}

# Sanitise a string for use as a docker container name
sanitise_name() {
    echo "$1" | sed 's/[^a-zA-Z0-9_.-]/_/g'
}

###############################################################################
# INITIALISE CSV
###############################################################################
python3 -c "
import csv
with open('$CSV_FILE', 'w', newline='') as f:
    csv.writer(f).writerow([
        'timestamp', 'docker_image', 'env_vars', 'serving_args',
        'model', 'endpoint', 'serve_launch_status',
        'prompt', 'response', 'status'
    ])
"

###############################################################################
# MAIN
###############################################################################
log "============================================================"
log "vLLM Multi-Model Sanity Check"
log "  Docker image : $DOCKER_IMAGE"
log "  Models       : ${#MODELS[@]}"
log "  Server port  : $SERVER_PORT"
log "  CSV output   : $CSV_FILE"
log "  Logs dir     : $LOG_DIR"
log "============================================================"

TOTAL_MODELS=${#MODELS[@]}
MODEL_IDX=0

for MODEL in "${MODELS[@]}"; do
    MODEL_IDX=$(( MODEL_IDX + 1 ))
    SAFE_MODEL=$(sanitise_name "$MODEL")

    log ""
    log "============================================================"
    log "  Model ${MODEL_IDX}/${TOTAL_MODELS}: $MODEL"
    log "============================================================"

    # Create a Docker named volume for this model's HF cache.
    # Docker manages volume storage as root, so cleanup via
    # `docker volume rm` always succeeds — no permission issues.
    HF_VOLUME="hf_cache_${SAFE_MODEL}_$$"
    docker volume create "$HF_VOLUME" >/dev/null 2>&1
    log "  HF cache volume: $HF_VOLUME"

    # Two passes: chat/completions then completions
    for ENDPOINT_TYPE in "chat" "completions"; do

        if [[ "$ENDPOINT_TYPE" == "chat" ]]; then
            API_PATH="v1/chat/completions"
        else
            API_PATH="v1/completions"
        fi

        CONTAINER_NAME="vllm_sanity_${SAFE_MODEL}_${ENDPOINT_TYPE}_$$"
        # Docker names max 128 chars
        CONTAINER_NAME="${CONTAINER_NAME:0:128}"
        ITER_LOG="$LOG_DIR/${SAFE_MODEL}_${ENDPOINT_TYPE}.log"

        log ""
        log "  ── Pass: $API_PATH ──────────────────────────────────"

        # Remove any leftover container with the same name
        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

        # ── Write a temp launch script to avoid nested-quoting issues ────────
        LAUNCH_SCRIPT=$(mktemp /tmp/vllm_launch_XXXXXX.sh)
        cat > "$LAUNCH_SCRIPT" <<LAUNCH_EOF
#!/bin/bash
exec vllm serve ${MODEL} \\
    --port ${SERVER_PORT} \\
    --tensor-parallel-size 1 \\
    --gpu-memory-utilization 0.7 \\
    --no-enable-prefix-caching \\
    --quantization fp8 \\
    --attention_config.backend ROCM_ATTN \\
    --trust_remote_code \\
    --chat-template /tmp/fallback_chat_template.jinja \\
    --compilation-config '{"cudagraph_mode": "FULL", "custom_ops": ["+quant_fp8"], "splitting_ops": [], "pass_config": {"eliminate_noops": true, "fuse_norm_quant": true, "fuse_act_quant": true, "fuse_attn_quant": true}}'
LAUNCH_EOF
        chmod +x "$LAUNCH_SCRIPT"

        # Derive CSV-friendly serve command directly from the launch script
        # (single source of truth — no separate template to drift out of sync)
        FULL_SERVING_ARGS=$(
            sed -n '2,$p' "$LAUNCH_SCRIPT" \
            | sed 's/^exec //' \
            | sed 's/[[:space:]]*\\$//' \
            | tr '\n' ' ' \
            | sed 's/  */ /g; s/^ //; s/ $//'
        )

        # ── Launch Docker container ──────────────────────────────────────────
        # FIX (H1): Override image ENTRYPOINT with /bin/bash so the launch
        #           script runs as intended instead of being appended to the
        #           image's built-in `vllm` entrypoint.
        log "  Starting Docker container ($CONTAINER_NAME) ..."
        docker run \
            -d \
            --rm \
            --entrypoint /bin/bash \
            --cap-add=SYS_PTRACE \
            --cap-add=CAP_SYS_ADMIN \
            --security-opt seccomp=unconfined \
            --user root \
            --device=/dev/kfd \
            --device=/dev/dri \
            --group-add video \
            --ulimit memlock=999332768:999332768 \
            --ipc=host \
            --name "$CONTAINER_NAME" \
            --shm-size=128G \
            --network host \
            -v "${HF_VOLUME}:/root/.cache/huggingface" \
            -v "${LAUNCH_SCRIPT}:/tmp/vllm_launch.sh:ro" \
            -v "${SCRIPT_DIR}/fallback_chat_template.jinja:/tmp/fallback_chat_template.jinja:ro" \
            -e "HF_TOKEN=${HF_TOKEN}" \
            -e "HUGGING_FACE_HUB_TOKEN=${HF_TOKEN}" \
            -e "HF_HOME=/root/.cache/huggingface" \
            "${ENV_FLAGS[@]}" \
            "$DOCKER_IMAGE" \
            /tmp/vllm_launch.sh \
            >> "$ITER_LOG" 2>&1

        # Do NOT delete launch script here — the container needs the
        #           bind-mounted file. Defer deletion to after container cleanup.

        # ── Watchdog: auto-kill after CONTAINER_TIMEOUT ──────────────────────
        (
            sleep "$CONTAINER_TIMEOUT"
            if docker ps -q -f name="^${CONTAINER_NAME}$" 2>/dev/null | grep -q .; then
                echo "[WATCHDOG] Timeout reached (${CONTAINER_TIMEOUT}s). Killing $CONTAINER_NAME" >> "$ITER_LOG"
                docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
            fi
        ) &
        WATCHDOG_PID=$!

        # Stream container logs
        docker logs -f "$CONTAINER_NAME" >> "$ITER_LOG" 2>&1 &
        LOGS_PID=$!

        # ── Wait for server ──────────────────────────────────────────────────
        log "  Waiting for server readiness (up to ${SERVER_STARTUP_TIMEOUT}s) ..."
        if ! wait_for_server "$CONTAINER_NAME"; then
            SERVE_STATUS=0
            TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
            for PROMPT in "${PROMPTS[@]}"; do
                append_csv "$TIMESTAMP" "$DOCKER_IMAGE" "$ENV_VARS_STR" \
                    "$FULL_SERVING_ARGS" "$MODEL" "$API_PATH" "$SERVE_STATUS" \
                    "$PROMPT" "SERVER_START_TIMEOUT" "ERROR"
            done
            cleanup_container "$CONTAINER_NAME"
            rm -f "$LAUNCH_SCRIPT"
            sleep 5
            continue
        fi

        # Server launched successfully
        SERVE_STATUS=1

        # ── Send prompts ─────────────────────────────────────────────────────
        PROMPT_IDX=0
        for PROMPT in "${PROMPTS[@]}"; do
            PROMPT_IDX=$(( PROMPT_IDX + 1 ))
            TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
            log "    Prompt ${PROMPT_IDX}/${#PROMPTS[@]}: ${PROMPT}"

            if [[ "$ENDPOINT_TYPE" == "chat" ]]; then
                # ── v1/chat/completions ──────────────────────────────────────
                PAYLOAD=$(python3 -c "
import json, sys
print(json.dumps({
    'model': sys.argv[1],
    'messages': [
        {'role': 'system', 'content': 'You are a helpful assistant. Respond only in English. Do not use any other languages.'},
        {'role': 'user', 'content': sys.argv[2]}
    ],
    'max_tokens': 512,
    'temperature': 0
}))
" "$MODEL" "$PROMPT")

                RAW_RESPONSE=$(curl -s --max-time "$PROMPT_TIMEOUT" \
                    -X POST "http://localhost:${SERVER_PORT}/v1/chat/completions" \
                    -H "Content-Type: application/json" \
                    -d "$PAYLOAD" 2>&1) || RAW_RESPONSE=""

                CONTENT=$(python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
    print(d['choices'][0]['message']['content'])
except Exception as e:
    print('')
" "$RAW_RESPONSE" 2>/dev/null) || CONTENT=""

            else
                # ── v1/completions ───────────────────────────────────────────
                PAYLOAD=$(python3 -c "
import json, sys
print(json.dumps({
    'model': sys.argv[1],
    'prompt': sys.argv[2],
    'max_tokens': 512,
    'temperature': 0.7
}))
" "$MODEL" "$PROMPT")

                RAW_RESPONSE=$(curl -s --max-time "$PROMPT_TIMEOUT" \
                    -X POST "http://localhost:${SERVER_PORT}/v1/completions" \
                    -H "Content-Type: application/json" \
                    -d "$PAYLOAD" 2>&1) || RAW_RESPONSE=""

                CONTENT=$(python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
    print(d['choices'][0]['text'])
except Exception as e:
    print('')
" "$RAW_RESPONSE" 2>/dev/null) || CONTENT=""
            fi

            # Determine status
            if [[ -z "$RAW_RESPONSE" ]]; then
                STATUS="ERROR"
                CONTENT="NO_RESPONSE (timeout or connection error)"
            elif [[ -z "$CONTENT" ]]; then
                # Check for known API-level errors before falling back to generic PARSE_ERROR
                API_ERROR=$(python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
    print(d.get('error',{}).get('message',''))
except: print('')
" "$RAW_RESPONSE" 2>/dev/null) || API_ERROR=""

                if [[ "$API_ERROR" == *"chat template"* ]]; then
                    STATUS="NO_CHAT_TEMPLATE"
                    CONTENT="Model does not define a chat template (base model)"
                else
                    STATUS="ERROR"
                    CONTENT="PARSE_ERROR: $RAW_RESPONSE"
                fi
            else
                STATUS="SUCCESS"
            fi

            log "      Status: $STATUS"
            log "      Response (truncated): ${CONTENT:0:120}..."

            # Save raw response to iter log
            {
                echo "--- Prompt $PROMPT_IDX ($API_PATH) ---"
                echo "$RAW_RESPONSE"
                echo ""
            } >> "$ITER_LOG"

            # Sanitise newlines so each CSV row stays on a single line
            CONTENT_CLEAN="${CONTENT//$'\n'/\\n}"
            CONTENT_CLEAN="${CONTENT_CLEAN//$'\r'/}"

            # Append to CSV
            append_csv "$TIMESTAMP" "$DOCKER_IMAGE" "$ENV_VARS_STR" \
                "$FULL_SERVING_ARGS" "$MODEL" "$API_PATH" "$SERVE_STATUS" \
                "$PROMPT" "$CONTENT_CLEAN" "$STATUS"

            # If no chat template, skip remaining prompts for this endpoint
            if [[ "$STATUS" == "NO_CHAT_TEMPLATE" ]]; then
                log "    Skipping remaining prompts — model has no chat template."
                for SKIP_PROMPT in "${PROMPTS[@]:$PROMPT_IDX}"; do
                    append_csv "$TIMESTAMP" "$DOCKER_IMAGE" "$ENV_VARS_STR" \
                        "$FULL_SERVING_ARGS" "$MODEL" "$API_PATH" "$SERVE_STATUS" \
                        "$SKIP_PROMPT" "$CONTENT_CLEAN" "NO_CHAT_TEMPLATE"
                done
                break
            fi
        done

        # ── Tear down container ──────────────────────────────────────────────
        log "  Stopping container ..."
        cleanup_container "$CONTAINER_NAME"
        rm -f "$LAUNCH_SCRIPT"
        sleep 5
    done

    # ── Clean up Docker volume for this model ─────────────────────────────────
    log "  Removing HF cache volume: $HF_VOLUME"
    docker volume rm "$HF_VOLUME" >/dev/null 2>&1 || {
        log "  WARN: Could not remove volume $HF_VOLUME. Remove manually: docker volume rm $HF_VOLUME"
    }
    log "  Done with model: $MODEL"
done

###############################################################################
# SUMMARY
###############################################################################
# Count rows properly (now that each row is single-line, wc -l works)
TOTAL_ROWS=$(( $(wc -l < "$CSV_FILE") - 1 ))   # minus header
SUCCESS_ROWS=$(grep -c ',SUCCESS$' "$CSV_FILE" 2>/dev/null || true)
ERROR_ROWS=$(grep -c ',ERROR$' "$CSV_FILE" 2>/dev/null || true)
SERVE_OK=$(grep -oP ',1,[^,]+,[^,]+,SUCCESS$' "$CSV_FILE" 2>/dev/null | wc -l || true)
SERVE_FAIL=$(grep -oP ',0,' "$CSV_FILE" 2>/dev/null | wc -l || true)

log ""
log "============================================================"
log "  SANITY CHECK COMPLETE"
log "============================================================"
log "  Docker image         : $DOCKER_IMAGE"
log "  Models tested        : ${#MODELS[@]}"
log "  Total prompt rows    : $TOTAL_ROWS"
log "  Prompt successes     : $SUCCESS_ROWS"
log "  Prompt errors        : $ERROR_ROWS"
log "  Serve launches OK    : $SERVE_OK"
log "  Serve launches FAIL  : $SERVE_FAIL"
log "  CSV output           : $CSV_FILE"
log "  Logs dir             : $LOG_DIR"
log "============================================================"
