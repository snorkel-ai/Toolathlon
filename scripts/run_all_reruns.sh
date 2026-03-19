#!/bin/bash
# Sequential run script for post-Issue-11-fix evaluation
# Run in tmux: tmux new -s all-runs 'bash scripts/run_all_reruns.sh'
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"

IMAGE="lockon0927/toolathlon-task-image:1016beta"
INSTANCE="toolathlon_default"

log() { echo ""; echo "========================================"; echo "  $1"; echo "  $(date '+%Y-%m-%d %H:%M:%S')"; echo "========================================"; }

# ================================================================
# Infrastructure Management
# ================================================================

kill_stale_task_containers() {
    log "Cleaning stale task containers..."
    STALE=$(docker ps -a --format "{{.Names}}" | grep "toolathlon-finalpool" || true)
    if [ -n "$STALE" ]; then
        echo "  Killing stale containers:"
        echo "$STALE" | while read c; do
            echo "    Removing: $c"
            docker rm -f "$c" 2>/dev/null || true
        done
        sleep 5
    else
        echo "  No stale containers."
    fi
}

redeploy_infra() {
    log "Full infrastructure redeploy..."

    # Kill stale task containers first
    kill_stale_task_containers

    # Redeploy all app containers (Canvas, Email, WooCommerce, K8s)
    echo "  Running deploy_containers.sh (this takes ~5 minutes)..."
    bash global_preparation/deploy_containers.sh true 2>&1 | tail -20
    echo ""

    # Fix Canvas Postgres (must run after every deploy)
    echo "  Running fix_canvas_postgres.sh..."
    bash scripts/fix_canvas_postgres.sh 2>&1 | tail -10
    echo ""

    # Wait for everything to stabilize
    echo "  Waiting 30s for services to stabilize..."
    sleep 30
}

check_services() {
    log "Checking service health..."

    # Canvas
    CANVAS_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:10001/api/v1/users/self" -H "Authorization: Bearer mcpcanvasadmintoken1" 2>/dev/null || echo "000")
    CANVAS_USERS=$(curl -s "http://localhost:10001/api/v1/accounts/1/users?per_page=1" \
      -H "Authorization: Bearer mcpcanvasadmintoken1" -i 2>/dev/null | tr -d '\r' | grep -oP 'page=\d+&per_page=1>; rel="last"' | grep -oP 'page=\K\d+' | head -1)
    CANVAS_USERS=${CANVAS_USERS:-0}
    echo "  Canvas: $CANVAS_STATUS (users: $CANVAS_USERS)"

    # Email
    EMAIL_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:10005" 2>/dev/null || echo "000")
    echo "  Email: $EMAIL_STATUS"

    # WooCommerce
    WOO_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:10003" 2>/dev/null || echo "000")
    echo "  WooCommerce: $WOO_STATUS"

    # K8s clusters
    K8S_COUNT=$(docker ps --format "{{.Names}}" | grep -c "cluster-.*-control-plane" || true)
    echo "  K8s clusters: $K8S_COUNT"

    # Check for critical failures
    HEALTHY=true
    if [ "$CANVAS_STATUS" != "200" ]; then
        echo "  ⚠ Canvas unhealthy ($CANVAS_STATUS)"
        HEALTHY=false
    fi
    if [ "$CANVAS_USERS" -lt 100 ]; then
        echo "  ⚠ Canvas user count too low ($CANVAS_USERS, expected 500+)"
        HEALTHY=false
    fi
    if [ "$WOO_STATUS" = "000" ]; then
        echo "  ⚠ WooCommerce unreachable"
        HEALTHY=false
    fi
    if [ "$EMAIL_STATUS" = "000" ]; then
        echo "  ⚠ Email unreachable"
        HEALTHY=false
    fi

    if [ "$HEALTHY" = "false" ]; then
        return 1
    fi
    echo "  ✓ All services healthy"
    return 0
}

ensure_healthy_infra() {
    # Try existing infra first
    if check_services; then
        kill_stale_task_containers
        return 0
    fi

    # Services unhealthy — try fix_canvas_postgres first (lighter fix)
    log "Services unhealthy — trying Canvas fix..."
    bash scripts/fix_canvas_postgres.sh 2>&1 | tail -5
    sleep 10

    if check_services; then
        kill_stale_task_containers
        return 0
    fi

    # Still unhealthy — full redeploy
    log "Still unhealthy — full redeploy..."
    redeploy_infra

    if check_services; then
        return 0
    fi

    echo "  FATAL: Services still unhealthy after redeploy. Manual intervention needed."
    exit 1
}

# ================================================================
# RUN 2: FT v1 — 16 affected tasks rerun
# ================================================================
run_ftv1_affected() {
    log "RUN 2: FT v1 — 16 affected tasks"
    ensure_healthy_infra

    export TOOLATHLON_OPENAI_BASE_URL="https://api.pinference.ai/api/v1"
    export TOOLATHLON_OPENAI_API_KEY="$PRIME_API_KEY"
    export TOOLATHLON_OPENAI_EXTRA_HEADERS="{\"X-Prime-Team-ID\": \"$PRIME_HEADER_ID\"}"
    export TASK_LIST=scripts/ftv1_affected_tasks.txt
    export CONFIG_FILE_ARG=scripts/qwen3_ft_run.json

    bash scripts/run_parallel.sh \
        "Qwen/Qwen3-30B-A3B-Instruct-2507:n66oroaewm5aekfqvi6846i9" \
        ./dumps/qwen3-30b-ft unified 6 \
        "$IMAGE" scripts/qwen3_ft_run.json decoupled normal "$INSTANCE"
}

# ================================================================
# RUN 3: FT v2 — full end-to-end (78 tasks, fresh dump)
# ================================================================
run_ftv2_full() {
    log "RUN 3: FT v2 — full end-to-end (78 tasks)"
    ensure_healthy_infra

    export TOOLATHLON_OPENAI_BASE_URL="https://api.pinference.ai/api/v1"
    export TOOLATHLON_OPENAI_API_KEY="$PRIME_API_KEY"
    export TOOLATHLON_OPENAI_EXTRA_HEADERS="{\"X-Prime-Team-ID\": \"$PRIME_HEADER_ID\"}"
    export TASK_LIST=scripts/google_free_tasks.txt
    export CONFIG_FILE_ARG=scripts/qwen3_ft_run_v2.json

    bash scripts/run_parallel.sh \
        "Qwen/Qwen3-30B-A3B-Instruct-2507:m6fw9e8c8o22wggpogmfqu7y" \
        ./dumps/qwen3-30b-ft-v2-run2 unified 6 \
        "$IMAGE" scripts/qwen3_ft_run_v2.json decoupled normal "$INSTANCE"
}

# ================================================================
# RUN 4: Opus — full end-to-end (78 tasks, fresh dump)
# ================================================================
run_opus_full() {
    log "RUN 4: Opus — full end-to-end (78 tasks)"
    ensure_healthy_infra

    export TOOLATHLON_OPENAI_BASE_URL="https://api.portkey.ai/v1"
    export TOOLATHLON_OPENAI_API_KEY="$PORTKEY_API_KEY"
    unset TOOLATHLON_OPENAI_EXTRA_HEADERS
    export TASK_LIST=scripts/google_free_tasks.txt
    export CONFIG_FILE_ARG=scripts/formal_run_v0.json

    bash scripts/run_parallel.sh \
        "@anthropic/claude-opus-4-6" \
        ./dumps/claude-opus-run3 unified 6 \
        "$IMAGE" scripts/formal_run_v0.json decoupled normal "$INSTANCE"
}

# ================================================================
# RUN 5: Qwen3-30B base — full end-to-end (78 tasks, fresh dump)
# ================================================================
run_qwen_base_full() {
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
}

# ================================================================
# RUN 6: FT v2 — third rollout (78 tasks, fresh dump)
# ================================================================
run_ftv2_run3() {
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
}

# ================================================================
# Execute all runs sequentially
# ================================================================
log "Starting all evaluation runs"
echo "  Run 1 (FT v2 affected): Already completed"
echo "  Run 2: FT v1 affected tasks (16 tasks)"
echo "  Run 3: FT v2 full end-to-end (78 tasks)"
echo "  Run 4: Opus full end-to-end (78 tasks)"
echo "  Run 5: Qwen3-30B base full end-to-end (78 tasks)"
echo "  Run 6: FT v2 third rollout (78 tasks)"
echo ""
echo "  Between each run: health check → Canvas fix → full redeploy if needed"

run_ftv1_affected
run_ftv2_full
run_opus_full
run_qwen_base_full
run_ftv2_run3

log "ALL RUNS COMPLETE"
echo "  Check results with: python3 scripts/monitor_runs.py --once"
