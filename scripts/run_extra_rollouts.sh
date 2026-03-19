#!/bin/bash
# Extra rollouts: Qwen base run 2 + FT v2 run 3
# Launch AFTER all-runs session completes (runs 2-4)
# tmux new -s extra-runs 'bash scripts/run_extra_rollouts.sh'
set -e

cd /home/ubuntu/Repos/Toolathlon

IMAGE="lockon0927/toolathlon-task-image:1016beta"
INSTANCE="toolathlon_default"

log() { echo ""; echo "========================================"; echo "  $1"; echo "  $(date '+%Y-%m-%d %H:%M:%S')"; echo "========================================"; }

# Source the infra management functions from main script
kill_stale_task_containers() {
    log "Cleaning stale task containers..."
    STALE=$(docker ps -a --format "{{.Names}}" | grep "toolathlon-finalpool" || true)
    if [ -n "$STALE" ]; then
        echo "$STALE" | while read c; do docker rm -f "$c" 2>/dev/null || true; done
        sleep 5
    else
        echo "  No stale containers."
    fi
}

check_services() {
    log "Checking service health..."
    CANVAS_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:10001/api/v1/users/self" -H "Authorization: Bearer mcpcanvasadmintoken1" 2>/dev/null || echo "000")
    WOO_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:10003" 2>/dev/null || echo "000")
    EMAIL_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:10005" 2>/dev/null || echo "000")
    echo "  Canvas: $CANVAS_STATUS | Email: $EMAIL_STATUS | WooCommerce: $WOO_STATUS"
    [ "$CANVAS_STATUS" = "000" ] || [ "$WOO_STATUS" = "000" ] && return 1
    [ "$CANVAS_STATUS" != "200" ] && return 1
    return 0
}

ensure_healthy_infra() {
    if check_services; then
        kill_stale_task_containers
        return 0
    fi
    log "Services unhealthy — trying Canvas fix..."
    bash scripts/fix_canvas_postgres.sh 2>&1 | tail -5
    sleep 10
    if check_services; then kill_stale_task_containers; return 0; fi
    log "Still unhealthy — full redeploy..."
    bash global_preparation/deploy_containers.sh true 2>&1 | tail -20
    bash scripts/fix_canvas_postgres.sh 2>&1 | tail -5
    sleep 30
    if check_services; then return 0; fi
    echo "FATAL: Services still unhealthy after redeploy."; exit 1
}

# ================================================================
# RUN 5: Qwen3-30B base — full end-to-end
# ================================================================
log "RUN 5: Qwen3-30B base — full end-to-end (78 tasks)"
ensure_healthy_infra

export TOOLATHLON_OPENAI_BASE_URL="https://api.pinference.ai/api/v1"
export TOOLATHLON_OPENAI_API_KEY="$PRIME_API_KEY"
export TOOLATHLON_OPENAI_EXTRA_HEADERS="{\"X-Prime-Team-ID\": \"$PRIME_HEADER_ID\"}"
export TASK_LIST=scripts/google_free_tasks.txt
export CONFIG_FILE_ARG=scripts/qwen3_run.json

bash scripts/run_parallel.sh \
    "Qwen/Qwen3-30B-A3B-Instruct-2507" \
    ./dumps/qwen3-30b-run2 unified 6 \
    "$IMAGE" scripts/qwen3_run.json decoupled normal "$INSTANCE"

# ================================================================
# RUN 6: FT v2 — third rollout
# ================================================================
log "RUN 6: FT v2 — third rollout (78 tasks)"
ensure_healthy_infra

export TOOLATHLON_OPENAI_BASE_URL="https://api.pinference.ai/api/v1"
export TOOLATHLON_OPENAI_API_KEY="$PRIME_API_KEY"
export TOOLATHLON_OPENAI_EXTRA_HEADERS="{\"X-Prime-Team-ID\": \"$PRIME_HEADER_ID\"}"
export TASK_LIST=scripts/google_free_tasks.txt
export CONFIG_FILE_ARG=scripts/qwen3_ft_run_v2.json

bash scripts/run_parallel.sh \
    "Qwen/Qwen3-30B-A3B-Instruct-2507:m6fw9e8c8o22wggpogmfqu7y" \
    ./dumps/qwen3-30b-ft-v2-run3 unified 6 \
    "$IMAGE" scripts/qwen3_ft_run_v2.json decoupled normal "$INSTANCE"

# ================================================================
# RUN 7: Qwen3-30B base — third rollout
# ================================================================
log "RUN 7: Qwen3-30B base — third rollout (78 tasks)"
ensure_healthy_infra

export TOOLATHLON_OPENAI_BASE_URL="https://api.pinference.ai/api/v1"
export TOOLATHLON_OPENAI_API_KEY="$PRIME_API_KEY"
export TOOLATHLON_OPENAI_EXTRA_HEADERS="{\"X-Prime-Team-ID\": \"$PRIME_HEADER_ID\"}"
export TASK_LIST=scripts/google_free_tasks.txt
export CONFIG_FILE_ARG=scripts/qwen3_run.json

bash scripts/run_parallel.sh \
    "Qwen/Qwen3-30B-A3B-Instruct-2507" \
    ./dumps/qwen3-30b-run3 unified 6 \
    "$IMAGE" scripts/qwen3_run.json decoupled normal "$INSTANCE"

log "ALL EXTRA RUNS COMPLETE"
