#!/usr/bin/env bash
# test-lab-14-01.sh — OpenKM Lab 01: Standalone
# Module 14 | Lab 01 | Tests: basic OpenKM DMS functionality in isolation
set -euo pipefail

COMPOSE_FILE="$(dirname "$0")/../docker/docker-compose.standalone.yml"
CLEANUP=true
for arg in "$@"; do [[ "$arg" == "--no-cleanup" ]] && CLEANUP=false; done

WEB_PORT=8304
DB_USER="openkm"
DB_PASS="OpenKMLab01!"
ADMIN_USER="okmAdmin"
ADMIN_PASS="admin"

PASS=0; FAIL=0
pass() { echo "[PASS] $1"; ((PASS++)) || true; }
fail() { echo "[FAIL] $1"; ((FAIL++)) || true; }
section() { echo ""; echo "=== $1 ==="; }

cleanup() {
  if [[ "$CLEANUP" == "true" ]]; then
    echo "Cleaning up..."
    docker compose -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
  fi
}
trap cleanup EXIT

section "Starting Lab 01 Standalone Stack"
docker compose -f "$COMPOSE_FILE" up -d
echo "Waiting for MySQL and OpenKM to initialize (may take 2-3 minutes)..."

section "MySQL Health Check"
for i in $(seq 1 30); do
  status=$(docker inspect openkm-s01-db --format '{{.State.Health.Status}}' 2>/dev/null || echo "waiting")
  [[ "$status" == "healthy" ]] && break; sleep 5
done
[[ "$(docker inspect openkm-s01-db --format '{{.State.Health.Status}}')" == "healthy" ]] && pass "MySQL healthy" || fail "MySQL not healthy"

section "OpenKM App Health Check"
for i in $(seq 1 60); do
  status=$(docker inspect openkm-s01-app --format '{{.State.Health.Status}}' 2>/dev/null || echo "waiting")
  [[ "$status" == "healthy" ]] && break
  echo "  Waiting for OpenKM ($i/60)..."
  sleep 10
done
[[ "$(docker inspect openkm-s01-app --format '{{.State.Health.Status}}')" == "healthy" ]] && pass "OpenKM app healthy" || fail "OpenKM app not healthy"

section "OpenKM Web UI"
http_code=$(curl -so /dev/null -w "%{http_code}" -L "http://localhost:${WEB_PORT}/openkm/" 2>/dev/null || echo "000")
[[ "$http_code" =~ ^(200|302|401)$ ]] && pass "OpenKM web accessible (HTTP $http_code)" || fail "OpenKM web returned HTTP $http_code"

curl -sf -L "http://localhost:${WEB_PORT}/openkm/" 2>/dev/null | grep -qi "openkm\|login\|username\|document" && pass "OpenKM login page content OK" || fail "OpenKM login page content unexpected"

section "OpenKM REST API"
# OpenKM REST API is at /openkm/services/rest/
api_resp=$(curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" \
  "http://localhost:${WEB_PORT}/openkm/services/rest/repository/info" \
  2>/dev/null || echo "")
if echo "$api_resp" | grep -qiE '"name"|"description"|openkm|xml'; then
  pass "OpenKM REST API accessible with admin credentials"
else
  # Try basic auth check - 200 or 401 both mean server is up
  api_code=$(curl -so /dev/null -w "%{http_code}" \
    "http://localhost:${WEB_PORT}/openkm/services/rest/repository/info" \
    2>/dev/null || echo "000")
  [[ "$api_code" =~ ^(200|401)$ ]] && pass "OpenKM REST endpoint accessible (HTTP $api_code)" || fail "OpenKM REST API not reachable (HTTP $api_code)"
fi

section "Database Connectivity"
db_tables=$(docker exec openkm-s01-db mysql -u "${DB_USER}" -p"${DB_PASS}" openkm -e "SHOW TABLES;" 2>/dev/null | wc -l || echo 0)
[[ "$db_tables" -gt 5 ]] && pass "OpenKM DB has tables (count: $db_tables)" || fail "OpenKM DB seems empty (count: $db_tables)"

section "Container Configuration"
restart_policy=$(docker inspect openkm-s01-app --format '{{.HostConfig.RestartPolicy.Name}}')
[[ "$restart_policy" == "unless-stopped" ]] && pass "Restart policy: unless-stopped" || fail "Unexpected restart policy: $restart_policy"

db_host=$(docker inspect openkm-s01-app --format '{{range .Config.Env}}{{println .}}{{end}}' | grep "^OPENKM_DB_HOST=" | cut -d= -f2)
[[ "$db_host" == "openkm-s01-db" ]] && pass "OPENKM_DB_HOST env set correctly" || fail "OPENKM_DB_HOST not set (got: $db_host)"

java_opts=$(docker inspect openkm-s01-app --format '{{range .Config.Env}}{{println .}}{{end}}' | grep "^JAVA_OPTS=" | cut -d= -f2-)
[[ -n "$java_opts" ]] && pass "JAVA_OPTS configured ($java_opts)" || fail "JAVA_OPTS not set"

section "Named Volumes"
docker volume ls | grep -q "openkm-s01-db-data" && pass "Volume openkm-s01-db-data exists" || fail "Volume openkm-s01-db-data missing"
docker volume ls | grep -q "openkm-s01-data" && pass "Volume openkm-s01-data exists" || fail "Volume openkm-s01-data missing"

echo ""
echo "================================================"
echo "Lab 01 Results: ${PASS} passed, ${FAIL} failed"
echo "================================================"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1