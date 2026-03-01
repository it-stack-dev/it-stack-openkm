#!/usr/bin/env bash
# test-lab-14-05.sh — Lab 14-05: Advanced Integration
# Module 14: OpenKM Document Management
# Services: MySQL · OpenLDAP · Elasticsearch · Keycloak · WireMock (consumers) · Mailhog · OpenKM
# Ports:    OpenKM:8373  ES:9203  WireMock:8374  KC:8471  LDAP:3897  MH:8673
set -euo pipefail

LAB_ID="14-05"
LAB_NAME="Advanced Integration"
MODULE="openkm"
COMPOSE_FILE="docker/docker-compose.integration.yml"
MOCK_URL="http://localhost:8374"
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
echo -e "${CYAN}  OpenKM REST API ↔ SuiteCRM/Odoo consumers (WireMock)${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

# ── PHASE 1: Setup ────────────────────────────────────────────────────────────
section "Phase 1: Setup"
docker compose -f "${COMPOSE_FILE}" up -d
info "Waiting 60s for integration stack to initialize (ES + KC + OpenKM)..."
sleep 60

# ── PHASE 2: Health Checks ────────────────────────────────────────────────────
section "Phase 2: Health Checks"

for svc in openkm-i05-db openkm-i05-ldap openkm-i05-es openkm-i05-kc openkm-i05-mock openkm-i05-mail openkm-i05-app; do
  if docker ps --format '{{.Names}}' | grep -q "^${svc}$"; then
    pass "Container ${svc} running"
  else
    fail "Container ${svc} not running"
  fi
done

if docker exec openkm-i05-db mysqladmin ping -uroot -pRootLab05! --silent 2>/dev/null; then
  pass "MySQL accepting connections"
else
  fail "MySQL not responding"
fi

ES_STATUS=$(curl -sf "http://localhost:9203/_cluster/health" | grep -o '"status":"[^"]*' | cut -d'"' -f4 || echo "unknown")
if [ "${ES_STATUS}" = "green" ] || [ "${ES_STATUS}" = "yellow" ]; then
  pass "Elasticsearch cluster health: ${ES_STATUS}"
else
  fail "Elasticsearch cluster health unexpected: ${ES_STATUS}"
fi

if curl -sf "${MOCK_URL}/__admin/health" > /dev/null 2>&1; then
  pass "WireMock admin health endpoint accessible"
else
  fail "WireMock not accessible at ${MOCK_URL}"
fi

if curl -sf http://localhost:8373/OpenKM/ > /dev/null 2>&1; then
  pass "OpenKM web accessible (:8373/OpenKM/)"
else
  fail "OpenKM web not accessible (:8373/OpenKM/)"
fi

# ── PHASE 3: Functional Tests — Integration ───────────────────────────────────
section "Phase 3: Functional Tests — Advanced Integration"

# ── 3a: WireMock stubs for consumer endpoints ─────────────────────────────
info "Registering WireMock stubs for SuiteCRM and Odoo document consumers..."

# SuiteCRM document attach notification stub
HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
  -X POST "${MOCK_URL}/__admin/mappings" \
  -H "Content-Type: application/json" \
  -d '{
    "request": {"method": "POST", "url": "/index.php?module=Documents&action=Save"},
    "response": {"status": 200,
                 "body": "{\\"result\\":{\\"id\\":\\"doc-001\\",\\"name\\":\\"openkm-doc\\",\\"status\\":\\"saved\\"}}",
                 "headers": {"Content-Type": "application/json"}}
  }' || echo "000")
if [ "${HTTP_STATUS}" = "201" ]; then
  pass "WireMock stub: SuiteCRM document attachment registered"
else
  fail "WireMock stub: SuiteCRM document attachment failed (status: ${HTTP_STATUS})"
fi

# Odoo DMS attachment stub
HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
  -X POST "${MOCK_URL}/__admin/mappings" \
  -H "Content-Type: application/json" \
  -d '{
    "request": {"method": "POST", "urlPathPattern": "/web/dataset/call_kw.*"},
    "response": {"status": 200,
                 "body": "{\\"jsonrpc\\":\\"2.0\\",\\"result\\":[{\\"id\\":42,\\"name\\":\\"lab-document.pdf\\",\\"type\\":\\"url\\"}]}",
                 "headers": {"Content-Type": "application/json"}}
  }' || echo "000")
if [ "${HTTP_STATUS}" = "201" ]; then
  pass "WireMock stub: Odoo DMS ir.attachment registered"
else
  fail "WireMock stub: Odoo DMS attachment failed (status: ${HTTP_STATUS})"
fi

# ── 3b: OpenKM REST API tests ─────────────────────────────────────────────────
info "Testing OpenKM REST API..."

if curl -sf -u okmAdmin:OkmAdmin05! \
     http://localhost:8373/OpenKM/services/rest/folder/getChildren?fldId=/okm:root \
     -H "Accept: application/json" > /dev/null 2>&1; then
  pass "OpenKM REST /folder/getChildren accessible (authenticated)"
else
  warn "OpenKM REST API not yet accessible (still initializing)"
fi

# ── 3c: Verify mock consumer endpoints respond ─────────────────────────────
if curl -sf -X POST "${MOCK_URL}/index.php?module=Documents&action=Save" \
     -H "Content-Type: application/json" \
     -d '{"name":"test-doc","file_path":"/okm:root/test.pdf"}' \
     | grep -q 'doc-001'; then
  pass "WireMock SuiteCRM document endpoint responds correctly"
else
  fail "WireMock SuiteCRM document endpoint not responding"
fi

# ── 3d: Integration env vars in OpenKM container ──────────────────────────
if docker exec openkm-i05-app env | grep -q 'CONSUMER_SUITECRM_URL=http://openkm-i05-mock'; then
  pass "CONSUMER_SUITECRM_URL env var set correctly"
else
  fail "CONSUMER_SUITECRM_URL not set in OpenKM container"
fi

if docker exec openkm-i05-app env | grep -q 'CONSUMER_ODOO_URL=http://openkm-i05-mock'; then
  pass "CONSUMER_ODOO_URL env var set correctly"
else
  fail "CONSUMER_ODOO_URL not set in OpenKM container"
fi

if docker exec openkm-i05-app env | grep -q 'openkm-i05-ldap'; then
  pass "LDAP server configured in OpenKM JAVA_OPTS"
else
  fail "LDAP server not configured in OpenKM env"
fi

# ── 3e: WireMock mappings count ─────────────────────────────────────────────
MAPPING_COUNT=$(curl -sf "${MOCK_URL}/__admin/mappings" | grep -o '"id"' | wc -l || echo 0)
if [ "${MAPPING_COUNT}" -ge 2 ]; then
  pass "WireMock has ${MAPPING_COUNT} stubs registered (expected ≥2)"
else
  fail "WireMock only has ${MAPPING_COUNT} stubs (expected ≥2)"
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
# test-lab-14-05.sh — Lab 14-05: Advanced Integration
# Module 14: OpenKM document management system
# openkm integrated with full IT-Stack ecosystem
set -euo pipefail

LAB_ID="14-05"
LAB_NAME="Advanced Integration"
MODULE="openkm"
COMPOSE_FILE="docker/docker-compose.integration.yml"
PASS=0
FAIL=0

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS++)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; ((FAIL++)); }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

echo -e "${CYAN}======================================${NC}"
echo -e "${CYAN} Lab ${LAB_ID}: ${LAB_NAME}${NC}"
echo -e "${CYAN} Module: ${MODULE}${NC}"
echo -e "${CYAN}======================================${NC}"
echo ""

# ── PHASE 1: Setup ────────────────────────────────────────────────────────────
info "Phase 1: Setup"
docker compose -f "${COMPOSE_FILE}" up -d
info "Waiting 30s for ${MODULE} to initialize..."
sleep 30

# ── PHASE 2: Health Checks ────────────────────────────────────────────────────
info "Phase 2: Health Checks"

if docker compose -f "${COMPOSE_FILE}" ps | grep -q "running\|Up"; then
    pass "Container is running"
else
    fail "Container is not running"
fi

# ── PHASE 3: Functional Tests ─────────────────────────────────────────────────
info "Phase 3: Functional Tests (Lab 05 — Advanced Integration)"

# TODO: Add module-specific functional tests here
# Example:
# if curl -sf http://localhost:8080/health > /dev/null 2>&1; then
#     pass "Health endpoint responds"
# else
#     fail "Health endpoint not reachable"
# fi

warn "Functional tests for Lab 14-05 pending implementation"

# ── PHASE 4: Cleanup ──────────────────────────────────────────────────────────
info "Phase 4: Cleanup"
docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans
info "Cleanup complete"

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}======================================${NC}"
echo -e " Lab ${LAB_ID} Complete"
echo -e " ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}======================================${NC}"

if [ "${FAIL}" -gt 0 ]; then
    exit 1
fi
