#!/bin/bash
# Fix Canvas Postgres after deploy_containers.sh.
# Run this after every Canvas container creation.
#
# Root cause: deploy_containers.sh -> setup.sh runs `supervisorctl restart all`
# only 5 seconds after container start. Postgres needs ~30 seconds to finish
# initializing (schema migrations). Restarting during initialization crashes it.
#
# This script waits for Postgres to be ready, restarts services cleanly,
# then creates the required accounts.

CONTAINER=${1:-canvas-docker-inst-alpha}

echo "=== Fixing Canvas for $CONTAINER ==="

# 1. If Postgres is FATAL (crashed from premature restart), start it
PG_STATUS=$(docker exec "$CONTAINER" supervisorctl status postgres 2>/dev/null | awk '{print $2}')
if [ "$PG_STATUS" = "FATAL" ] || [ "$PG_STATUS" = "STOPPED" ]; then
  echo "  Postgres is $PG_STATUS — restarting it..."
  docker exec "$CONTAINER" supervisorctl start postgres 2>/dev/null
  sleep 2
fi

# 2. Wait for Postgres to accept connections (may take 30+ seconds on first boot)
echo "  Waiting for Postgres to accept connections..."
for i in $(seq 1 60); do
  STATUS=$(docker exec "$CONTAINER" bash -c "su - postgres -c 'pg_isready'" 2>/dev/null)
  if echo "$STATUS" | grep -q "accepting"; then
    echo "  ✓ Postgres ready (${i}s)"
    break
  fi
  if [ "$i" = "60" ]; then
    echo "  ✗ Postgres not ready after 60s"
    echo "    Last status: $STATUS"
    exit 1
  fi
  sleep 1
done

# 2. Restart all services cleanly (now that Postgres is ready)
echo "  Restarting services..."
docker exec "$CONTAINER" supervisorctl restart all 2>/dev/null || true
sleep 10

# 3. Verify Postgres survived the restart
PG_STATUS=$(docker exec "$CONTAINER" supervisorctl status postgres 2>/dev/null | awk '{print $2}')
if [ "$PG_STATUS" = "RUNNING" ]; then
  echo "  ✓ Postgres running after restart"
else
  echo "  ✗ Postgres failed after restart: $PG_STATUS"
  exit 1
fi

# 4. Wait for Postgres to accept connections again after restart
for i in $(seq 1 60); do
  STATUS=$(docker exec "$CONTAINER" bash -c "su - postgres -c 'pg_isready'" 2>/dev/null)
  if echo "$STATUS" | grep -q "accepting"; then
    break
  fi
  sleep 1
done

# 5. Create accounts
echo "  Creating admin accounts..."
uv run -m deployment.canvas.scripts.create_admin_accounts --container-name "$CONTAINER" 2>&1 | tail -1
echo "  Creating users (503)..."
uv run -m deployment.canvas.scripts.create_canvas_user --count 503 --skip-test --batch-size 100 --container-name "$CONTAINER" 2>&1 | tail -1

# 6. Verify
CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:10001/api/v1/users/self -H "Authorization: Bearer mcpcanvasadmintoken1")
if [ "$CODE" = "200" ]; then
  echo "  ✓ Canvas API healthy ($CODE)"
else
  echo "  ✗ Canvas API returned $CODE"
  exit 1
fi

echo "=== Canvas fix complete ==="
