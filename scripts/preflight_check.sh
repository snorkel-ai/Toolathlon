#!/bin/bash
# Toolathlon Pre-Flight Check
# Run this BEFORE every model evaluation run.
# Usage: bash scripts/preflight_check.sh <dump_path> <config_file>

MODEL_DUMP=${1:-"dumps/my-model"}
CONFIG=${2:-"scripts/formal_run_v0.json"}

FAIL=0

echo "=========================================="
echo "  Toolathlon Pre-Flight Check"
echo "  Dump: $MODEL_DUMP"
echo "  Config: $CONFIG"
echo "=========================================="

# --- Infrastructure ---
echo ""
echo "=== 1. App Containers ==="
for c in canvas-docker-inst-alpha poste-inst-alpha woo-wp-inst-alpha woo-db-inst-alpha \
         cluster-inst-alpha1-control-plane cluster-cleanup-control-plane \
         cluster-mysql-control-plane cluster-redis-helm-control-plane \
         cluster-pr-preview-control-plane; do
  status=$(docker inspect --format '{{.State.Status}}' $c 2>/dev/null || echo "MISSING")
  if [ "$status" = "running" ]; then
    echo "  ✓ $c"
  else
    echo "  ✗ $c ($status)"
    FAIL=1
  fi
done

echo ""
echo "=== 2. Service Health ==="
# Canvas
CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:10001/api/v1/users/self -H "Authorization: Bearer mcpcanvasadmintoken1" 2>/dev/null || echo "000")
if [ "$CODE" = "200" ]; then echo "  ✓ Canvas API ($CODE)"; else echo "  ✗ Canvas API ($CODE)"; FAIL=1; fi

# Canvas user count
CANVAS_USERS=$(curl -s "http://localhost:10001/api/v1/accounts/1/users?per_page=1" \
  -H "Authorization: Bearer mcpcanvasadmintoken1" -i 2>/dev/null | tr -d '\r' | grep -oP 'page=\d+&per_page=1>; rel="last"' | grep -oP 'page=\K\d+' | head -1)
CANVAS_USERS=${CANVAS_USERS:-0}
if [ "$CANVAS_USERS" -ge 500 ]; then echo "  ✓ Canvas users: $CANVAS_USERS"; else echo "  ✗ Canvas users: $CANVAS_USERS (expected 500+, run: bash scripts/fix_canvas_postgres.sh)"; FAIL=1; fi

# Email
CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:10005 2>/dev/null || echo "000")
if [ "$CODE" != "000" ]; then echo "  ✓ Email ($CODE)"; else echo "  ✗ Email ($CODE)"; FAIL=1; fi

# WooCommerce
CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:10003 2>/dev/null || echo "000")
if [ "$CODE" != "000" ]; then echo "  ✓ WooCommerce ($CODE)"; else echo "  ✗ WooCommerce ($CODE)"; FAIL=1; fi

echo ""
echo "=== 3. Stale Task Containers ==="
STALE=$(docker ps -a --format "{{.Names}}" | grep "toolathlon-finalpool" | wc -l)
if [ "$STALE" = "0" ]; then echo "  ✓ None"; else echo "  ✗ $STALE stale containers — run: docker ps -a --format '{{.Names}}' | grep toolathlon-finalpool | xargs docker rm -f"; FAIL=1; fi

echo ""
echo "=== 4. Dump Directory ==="
EVAL_COUNT=$(find ${MODEL_DUMP}/finalpool -name eval_res.json 2>/dev/null | wc -l)
ROOT_COUNT=$(sudo find ${MODEL_DUMP}/finalpool -user root 2>/dev/null | wc -l)
echo "  Stale eval files: $EVAL_COUNT"
echo "  Root-owned files: $ROOT_COUNT"
if [ "$EVAL_COUNT" != "0" ] || [ "$ROOT_COUNT" != "0" ]; then
  echo "  ✗ Clean up first:"
  echo "    find ${MODEL_DUMP}/finalpool -name eval_res.json | xargs rm -f"
  echo "    sudo chown -R \$(id -u):\$(id -g) ${MODEL_DUMP}/finalpool"
  FAIL=1
else
  echo "  ✓ Clean"
fi

# --- Config ---
echo ""
echo "=== 5. Eval Config ==="
if [ -f "$CONFIG" ]; then
  python3 -c "
import json
d = json.load(open('$CONFIG'))
print(f'  model:      {d[\"agent\"][\"model\"][\"short_name\"]}')
print(f'  provider:   {d[\"agent\"][\"model\"][\"provider\"]}')
print(f'  max_tokens: {d[\"agent\"][\"generation\"][\"max_tokens\"]}')
eb = d['agent']['generation'].get('extra_body', {})
if eb: print(f'  extra_body: {eb}')
"
else
  echo "  ✗ Config file not found: $CONFIG"
  FAIL=1
fi

echo ""
echo "=== 6. Environment Variables ==="
[ -n "$TOOLATHLON_OPENAI_BASE_URL" ] && echo "  ✓ TOOLATHLON_OPENAI_BASE_URL" || echo "  ✗ TOOLATHLON_OPENAI_BASE_URL not set"
[ -n "$TOOLATHLON_OPENAI_API_KEY" ] && echo "  ✓ TOOLATHLON_OPENAI_API_KEY" || echo "  ✗ TOOLATHLON_OPENAI_API_KEY not set"
if [ -n "$TOOLATHLON_OPENAI_EXTRA_HEADERS" ]; then
  echo "  ✓ TOOLATHLON_OPENAI_EXTRA_HEADERS"
else
  echo "  ⚠ TOOLATHLON_OPENAI_EXTRA_HEADERS not set (ok for Portkey — uses Bearer token; required for PrimeIntellect)"
fi
if echo "$TOOLATHLON_OPENAI_BASE_URL" | grep -q "portkey"; then
  if [ "$TOOLATHLON_OPENAI_API_KEY" = "dummy" ] || [ "$TOOLATHLON_OPENAI_API_KEY" = "fake-key" ]; then
    echo "  ✗ Portkey detected but API_KEY is '$TOOLATHLON_OPENAI_API_KEY' — must be set to \$PORTKEY_API_KEY"
    FAIL=1
  else
    echo "  ✓ Portkey auth: API key set as Bearer token"
  fi
  echo "  ⚠ Portkey reminder: model name must use @anthropic/ prefix (e.g. @anthropic/claude-opus-4-6)"
fi

echo ""
echo "=== 7. Code Fixes ==="
grep -q 'new_asst\["content"\] = ""' utils/api_model/model_provider.py && echo "  ✓ 422 fix present" || echo "  ✗ 422 fix MISSING"
grep -q 'sudo chown' scripts/run_single_decoupled.sh && echo "  ✓ Permission fix present" || echo "  ✗ Permission fix MISSING"
grep -q 'tool_use_behavior' utils/roles/task_agent.py && echo "  ✓ claim_done loop fix present" || echo "  ✗ claim_done loop fix MISSING"
grep -q "and message\['content'\]" utils/api_model/model_provider.py && echo "  ✓ cache_control empty text fix present" || echo "  ✗ cache_control empty text fix MISSING (Issue 13)"

echo ""
echo "=== 8. Task List ==="
echo "  Tasks: $(grep -c . scripts/google_free_tasks.txt) in google_free_tasks.txt"

echo ""
echo "=========================================="
if [ "$FAIL" = "0" ]; then
  echo "  ✅ ALL CHECKS PASSED — safe to run"
else
  echo "  ❌ SOME CHECKS FAILED — fix before running"
fi
echo "=========================================="
exit $FAIL
