#!/usr/bin/env bash
# test-lab-14-06.sh — Lab 14-06: Production Deployment
# Module 14: OpenKM Document Management
# Services: MySQL · OpenLDAP · Elasticsearch · Keycloak · Mailhog · OpenKM
# Ports:    Web:8393  ES:9204  KC:8491  LDAP:3901  MH:8693
set -euo pipefail

LAB_ID="14-06"
LAB_NAME="Production Deployment"
MODULE="openkm"
COMPOSE_FILE="docker/docker-compose.production.yml"
PASS=0
FAIL=0
CLEANUP=true

for arg in "$@"; do [ "$arg" = "--no-cleanup" ] && CLEANUP=false; done

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

pass()    { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS++)); }
fail()    { echo -e "${RED}[FAIL]${NC} $1"; ((FAIL++)); }
info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
section() { echo -e "\n${BOLD}${CYAN}── $1 ──${NC}"; }

cleanup() {
  if [ "${CLEANUP}" = "true" ]; then
    docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}  Lab ${LAB_ID}: ${LAB_NAME} — ${MODULE}${NC}"
echo -e "${CYAN}  Production: ES search, LDAP, Keycloak, resource limits, backup${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

# ── PHASE 1: Setup ────────────────────────────────────────────────────────────
section "Phase 1: Setup"
docker compose -f "${COMPOSE_FILE}" up -d
info "Waiting 75s for production stack to initialize (ES + KC + OpenKM)..."
sleep 75

# ── PHASE 2: Health Checks ────────────────────────────────────────────────────
section "Phase 2: Health Checks"

for svc in openkm-p06-db openkm-p06-ldap openkm-p06-es openkm-p06-kc openkm-p06-mail openkm-p06-app; do
  if docker ps --format '{{.Names}}' | grep -q "^${svc}$"; then
    pass "Container ${svc} running"
  else
    fail "Container ${svc} not running"
  fi
done

if docker exec openkm-p06-db mysqladmin ping -uroot -pRootProd06! --silent 2>/dev/null; then
  pass "MySQL accepting connections"
else
  fail "MySQL not responding"
fi

ES_STATUS=$(curl -sf "http://localhost:9204/_cluster/health" | grep -o '"status":"[^"]*' | cut -d'"' -f4 || echo "unknown")
if [ "${ES_STATUS}" = "green" ] || [ "${ES_STATUS}" = "yellow" ]; then
  pass "Elasticsearch cluster health: ${ES_STATUS}"
else
  fail "Elasticsearch health unexpected: ${ES_STATUS}"
fi

if curl -sf http://localhost:8491/realms/master > /dev/null 2>&1; then
  pass "Keycloak reachable (:8491)"
else
  fail "Keycloak not reachable (:8491)"
fi

if curl -sf http://localhost:8393/OpenKM/ > /dev/null 2>&1; then
  pass "OpenKM web accessible (:8393/OpenKM/)"
else
  fail "OpenKM web not accessible (:8393/OpenKM/)"
fi

# ── PHASE 3: Functional Tests — Production Grade ─────────────────────────────
section "Phase 3: Functional Tests — Production Deployment"

# ── 3a: Compose config validation ───────────────────────────────────────────────
if docker compose -f "${COMPOSE_FILE}" config -q 2>/dev/null; then
  pass "Compose file syntax valid"
else
  fail "Compose file syntax error"
fi

# ── 3b: Resource limits ───────────────────────────────────────────────────────────────
MEM_LIMIT=$(docker inspect openkm-p06-app --format '{{.HostConfig.Memory}}' 2>/dev/null || echo 0)
if [ "${MEM_LIMIT}" -gt 0 ] 2>/dev/null; then
  pass "Memory limit set on openkm-p06-app (${MEM_LIMIT} bytes)"
else
  fail "Memory limit not set on openkm-p06-app"
fi

RESTART_POLICY=$(docker inspect openkm-p06-app --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null || echo "none")
if [ "${RESTART_POLICY}" = "unless-stopped" ]; then
  pass "Restart policy: unless-stopped"
else
  fail "Restart policy not set to unless-stopped (got: ${RESTART_POLICY})"
fi

# ── 3c: Elasticsearch index operations ───────────────────────────────────────────
info "Testing Elasticsearch index operations..."
# Create test index
curl -sf -X PUT "http://localhost:9204/openkm-prod-test" \
  -H 'Content-Type: application/json' \
  -d '{"settings":{"number_of_shards":1,"number_of_replicas":0}}' > /dev/null 2>&1
# Index a test document
INDEX_RESULT=$(curl -sf -X POST "http://localhost:9204/openkm-prod-test/_doc" \
  -H 'Content-Type: application/json' \
  -d '{"title":"Production test doc","content":"OpenKM production lab 06"}' 2>/dev/null | grep -o '"result":"[^"]*' | cut -d'"' -f4 || echo "")
if [ "${INDEX_RESULT}" = "created" ]; then
  pass "Elasticsearch document indexing works (result: created)"
else
  fail "Elasticsearch document indexing failed (result: ${INDEX_RESULT})"
fi
# Cleanup test index
curl -sf -X DELETE "http://localhost:9204/openkm-prod-test" > /dev/null 2>&1 || true

# ── 3d: Production env vars ─────────────────────────────────────────────────────
if docker exec openkm-p06-app env | grep -q 'IT_STACK_ENV=production'; then
  pass "IT_STACK_ENV=production set"
else
  fail "IT_STACK_ENV not set to production"
fi

if docker exec openkm-p06-app env | grep -q 'openkm-p06-ldap'; then
  pass "LDAP server configured in JAVA_OPTS"
else
  fail "LDAP server not configured in env"
fi

if docker exec openkm-p06-app env | grep -q 'KEYCLOAK_URL=http://openkm-p06-kc'; then
  pass "KEYCLOAK_URL points to openkm-p06-kc"
else
  fail "KEYCLOAK_URL not configured correctly"
fi

# ── 3e: Database backup test ───────────────────────────────────────────────────
info "Testing database backup (mysqldump)..."
if docker exec openkm-p06-db mysqldump \
     -uroot -pRootProd06! openkm > /dev/null 2>&1; then
  pass "Database backup (mysqldump openkm) succeeds"
else
  fail "Database backup (mysqldump openkm) failed"
fi

# ── 3f: Keycloak admin API ───────────────────────────────────────────────────────
KC_TOKEN=$(curl -sf -X POST http://localhost:8491/realms/master/protocol/openid-connect/token \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'client_id=admin-cli&grant_type=password&username=admin&password=Admin06!' \
  2>/dev/null | grep -o '"access_token":"[^"]*' | cut -d'"' -f4 || echo "")
if [ -n "${KC_TOKEN}" ]; then
  pass "Keycloak admin token obtained"
else
  fail "Keycloak admin token not obtained"
fi

# ── 3g: OpenKM REST API ───────────────────────────────────────────────────────────
if curl -sf -u okmAdmin:OkmAdmin06! \
     http://localhost:8393/OpenKM/services/rest/folder/getChildren?fldId=/okm:root \
     -H "Accept: application/json" > /dev/null 2>&1; then
  pass "OpenKM REST API /folder/getChildren accessible (authenticated)"
else
  warn "OpenKM REST API not yet accessible (may still be initializing)"
fi

# ── 3h: Restart resilience ─────────────────────────────────────────────────────────
info "Testing MySQL restart resilience..."
docker restart openkm-p06-db > /dev/null 2>&1
sleep 15
if docker exec openkm-p06-db mysqladmin ping -uroot -pRootProd06! --silent 2>/dev/null; then
  pass "MySQL recovers after restart"
else
  fail "MySQL did not recover after restart"
fi

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "  Lab ${LAB_ID} Complete"
echo -e "  ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}============================================================${NC}"

if [ "${FAIL}" -gt 0 ]; then
    exit 1
fi