#!/usr/bin/env bash
# test-lab-14-03.sh — Lab 14-03: Advanced Features
# Module 14: OpenKM Document Management
# Tests: Elasticsearch full-text search + resource limits + REST API advanced endpoints
set -euo pipefail

LAB_ID="14-03"
LAB_NAME="Advanced Features"
MODULE="openkm"
COMPOSE_FILE="docker/docker-compose.advanced.yml"
PASS=0
FAIL=0

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

pass()    { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS++)); }
fail()    { echo -e "${RED}[FAIL]${NC} $1"; ((FAIL++)); }
section() { echo -e "\n${CYAN}── $1 ──${NC}"; }
info()    { echo -e "${CYAN}[INFO]${NC} $1"; }

CLEANUP=true
[[ "${1:-}" == "--no-cleanup" ]] && CLEANUP=false

cleanup() {
  if [[ "${CLEANUP}" == "true" ]]; then
    info "Cleaning up..."
    docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN} Lab ${LAB_ID}: ${LAB_NAME}${NC}"
echo -e "${CYAN} Module: ${MODULE}${NC}"
echo -e "${CYAN}========================================${NC}"

# ── PHASE 1: Setup ────────────────────────────────────────────────────────────
section "Phase 1: Setup"
docker compose -f "${COMPOSE_FILE}" up -d

# ── PHASE 2: Health Checks ────────────────────────────────────────────────────
section "Phase 2: Health Checks"

info "Waiting for MySQL (up to 90s)..."
for i in $(seq 1 18); do
  if docker exec openkm-a03-db mysqladmin ping -uroot -pRootLab03! --silent 2>/dev/null; then
    pass "MySQL healthy"; break
  fi
  [[ $i -eq 18 ]] && fail "MySQL timed out"
  sleep 5
done

info "Waiting for Elasticsearch (up to 90s)..."
for i in $(seq 1 18); do
  if curl -sf http://localhost:9201/_cluster/health 2>/dev/null | grep -q '"status":"green"\|"status":"yellow"'; then
    pass "Elasticsearch cluster healthy on :9201"; break
  fi
  [[ $i -eq 18 ]] && fail "Elasticsearch not healthy on :9201"
  sleep 5
done

info "Waiting for Mailhog (up to 60s)..."
for i in $(seq 1 12); do
  if curl -sf http://localhost:8632/api/v2/messages > /dev/null 2>&1; then
    pass "Mailhog reachable on :8632"; break
  fi
  [[ $i -eq 12 ]] && fail "Mailhog not reachable on :8632"
  sleep 5
done

info "Waiting for OpenKM (up to 3 min)..."
for i in $(seq 1 36); do
  if curl -sf http://localhost:8332/openkm/ > /dev/null 2>&1; then
    pass "OpenKM reachable on :8332/openkm/"; break
  fi
  [[ $i -eq 36 ]] && fail "OpenKM not reachable on :8332/openkm/"
  sleep 5
done

# ── PHASE 3: Functional Tests ─────────────────────────────────────────────────
section "Phase 3: Functional Tests"

# Container states
for cname in openkm-a03-db openkm-a03-es openkm-a03-mail openkm-a03-app; do
  if docker inspect "${cname}" --format '{{.State.Status}}' 2>/dev/null | grep -q running; then
    pass "${cname} running"
  else
    fail "${cname} not running"
  fi
done

# Elasticsearch cluster info
ES_STATUS=$(curl -sf http://localhost:9201/_cluster/health 2>/dev/null | grep -o '"status":"[^"]*"' | head -1 || echo "unknown")
if echo "${ES_STATUS}" | grep -q 'green\|yellow'; then
  pass "Elasticsearch status: ${ES_STATUS}"
else
  fail "Elasticsearch status not green/yellow: ${ES_STATUS}"
fi

# Elasticsearch version
ES_VER=$(curl -sf http://localhost:9201/ 2>/dev/null | grep -o '"number":"[^"]*"' | head -1 || echo "")
if [[ -n "${ES_VER}" ]]; then
  pass "Elasticsearch version: ${ES_VER}"
else
  fail "Elasticsearch version not readable"
fi

# Elasticsearch index list
ES_INDICES=$(curl -sf http://localhost:9201/_cat/indices?h=index 2>/dev/null || echo "")
if [[ -n "${ES_INDICES}" ]]; then
  pass "Elasticsearch indices endpoint responds"
else
  fail "Elasticsearch indices not accessible"
fi

# OpenKM REST API - repository info
HTTP_CODE=$(curl -o /dev/null -s -w "%{http_code}" \
  -u okmAdmin:admin \
  http://localhost:8332/openkm/services/rest/repository/info 2>/dev/null || echo 000)
if [[ "${HTTP_CODE}" =~ ^(200|201)$ ]]; then
  pass "OpenKM REST /repository/info HTTP ${HTTP_CODE}"
else
  fail "OpenKM REST HTTP ${HTTP_CODE} (expected 200)"
fi

# OpenKM REST - folder list
HTTP_FOLDER=$(curl -o /dev/null -s -w "%{http_code}" \
  -u okmAdmin:admin \
  "http://localhost:8332/openkm/services/rest/folder/getChildren?fldPath=/okm:root" 2>/dev/null || echo 000)
if [[ "${HTTP_FOLDER}" =~ ^(200|201)$ ]]; then
  pass "OpenKM REST /folder/getChildren HTTP ${HTTP_FOLDER}"
else
  fail "OpenKM REST folder list HTTP ${HTTP_FOLDER}"
fi

# MySQL DB tables
TABLE_COUNT=$(docker exec openkm-a03-db mysql -uroot -pRootLab03! openkm \
  -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='openkm';" \
  --skip-column-names 2>/dev/null || echo 0)
if [[ "${TABLE_COUNT:-0}" -gt 20 ]]; then
  pass "DB has ${TABLE_COUNT} OpenKM tables"
else
  fail "DB has only ${TABLE_COUNT:-0} tables (expected >20)"
fi

# Resource limits
MEM_LIMIT=$(docker inspect openkm-a03-app --format '{{.HostConfig.Memory}}' 2>/dev/null || echo 0)
if [[ "${MEM_LIMIT:-0}" -gt 0 ]]; then
  pass "Memory limit set on openkm-a03-app (${MEM_LIMIT} bytes)"
else
  fail "No memory limit on openkm-a03-app"
fi

# Elasticsearch env vars in app
if docker exec openkm-a03-app printenv OPENKM_ES_HOST 2>/dev/null | grep -q 'openkm-a03-es'; then
  pass "OPENKM_ES_HOST → openkm-a03-es"
else
  fail "OPENKM_ES_HOST not configured"
fi

# Mailhog API
if curl -sf http://localhost:8632/api/v2/messages | grep -q 'total\|items'; then
  pass "Mailhog API valid"
else
  fail "Mailhog API invalid"
fi

# Volumes
for vol in openkm-a03-db-data openkm-a03-es-data openkm-a03-data openkm-a03-logs; do
  if docker volume ls --format '{{.Name}}' | grep -q "${vol}"; then
    pass "Volume ${vol} exists"
  else
    fail "Volume ${vol} missing"
  fi
done

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}========================================${NC}"
echo " Lab ${LAB_ID} Results"
echo -e " ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}========================================${NC}"
[[ "${FAIL}" -gt 0 ]] && exit 1
exit 0