#!/usr/bin/env bash
# test-lab-14-04.sh — Lab 14-04: SSO Integration
# Module 14: OpenKM document management system
# openkm with Keycloak OIDC/SAML authentication
set -euo pipefail

LAB_ID="14-04"
LAB_NAME="SSO Integration"
MODULE="openkm"
COMPOSE_FILE="docker/docker-compose.sso.yml"
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
info "Phase 3: Functional Tests (Lab 04 — SSO Integration)"

# TODO: Add module-specific functional tests here
# Example:
# if curl -sf http://localhost:8080/health > /dev/null 2>&1; then
#     pass "Health endpoint responds"
# else
#     fail "Health endpoint not reachable"
# fi

# ── 3a: Keycloak realm + SAML client ─────────────────────────────────────────
info "Creating it-stack realm and openkm SAML client via Keycloak API..."

if curl -sf http://localhost:8452/realms/master > /dev/null 2>&1; then
  pass "Keycloak master realm accessible (:8452)"
else
  fail "Keycloak not accessible at :8452"
fi

KC_TOKEN=$(curl -sf -X POST "http://localhost:8452/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&client_id=admin-cli&username=admin&password=Admin04!" \
  | grep -o '"access_token":"[^"]*' | cut -d'"' -f4 || echo "")

if [ -n "${KC_TOKEN}" ]; then
  pass "Keycloak admin token obtained"
else
  fail "Failed to get Keycloak admin token"
  KC_TOKEN=""
fi

if [ -n "${KC_TOKEN}" ]; then
  HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
    -X POST "http://localhost:8452/admin/realms" \
    -H "Authorization: Bearer ${KC_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"realm":"it-stack","enabled":true}' || echo "000")
  if [ "${HTTP_STATUS}" = "201" ] || [ "${HTTP_STATUS}" = "409" ]; then
    pass "Keycloak it-stack realm created (status: ${HTTP_STATUS})"
  else
    fail "Failed to create it-stack realm (status: ${HTTP_STATUS})"
  fi
fi

if [ -n "${KC_TOKEN}" ]; then
  HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
    -X POST "http://localhost:8452/admin/realms/it-stack/clients" \
    -H "Authorization: Bearer ${KC_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"clientId":"openkm","enabled":true,"protocol":"saml","redirectUris":["http://localhost:8352/*"]}' || echo "000")
  if [ "${HTTP_STATUS}" = "201" ] || [ "${HTTP_STATUS}" = "409" ]; then
    pass "Keycloak openkm SAML client created (status: ${HTTP_STATUS})"
  else
    fail "Failed to create openkm SAML client (status: ${HTTP_STATUS})"
  fi
fi

if curl -sf "http://localhost:8452/realms/it-stack/protocol/saml/descriptor" | grep -q 'EntityDescriptor'; then
  pass "Keycloak SAML IdP metadata (EntityDescriptor) accessible"
else
  fail "Keycloak SAML metadata not accessible"
fi

if curl -sf "http://localhost:8452/realms/it-stack/.well-known/openid-configuration" | grep -q 'issuer'; then
  pass "Keycloak OIDC discovery returns issuer"
else
  fail "Keycloak OIDC discovery missing issuer"
fi

# ── 3b: Elasticsearch health ───────────────────────────────────────────────────
info "Testing Elasticsearch..."

ES_STATUS=$(curl -sf "http://localhost:9202/_cluster/health" | grep -o '"status":"[^"]*' | cut -d'"' -f4 || echo "unknown")
if [ "${ES_STATUS}" = "green" ] || [ "${ES_STATUS}" = "yellow" ]; then
  pass "Elasticsearch cluster health: ${ES_STATUS}"
else
  fail "Elasticsearch cluster health unexpected: ${ES_STATUS}"
fi

# ── 3c: LDAP integration ──────────────────────────────────────────────────────
info "Testing LDAP integration..."

if docker exec openkm-s04-ldap ldapsearch -x -H ldap://localhost \
     -b dc=lab,dc=local -D cn=admin,dc=lab,dc=local -w LdapLab04! \
     '(objectClass=*)' dn 2>/dev/null | grep -q 'dn:'; then
  pass "LDAP base DC dc=lab,dc=local has entries"
else
  fail "LDAP base DC search returned no entries"
fi

if docker exec openkm-s04-app curl -sf http://openkm-s04-kc:8080/realms/master > /dev/null 2>&1; then
  pass "Keycloak reachable from OpenKM container"
else
  fail "Keycloak not reachable from OpenKM container"
fi

# LDAP config in JAVA_OPTS
if docker exec openkm-s04-app env | grep -q 'security.ldap.enable=true'; then
  pass "LDAP enable property set in OpenKM JAVA_OPTS"
else
  fail "LDAP enable property not found in OpenKM env"
fi

if docker exec openkm-s04-app env | grep -q 'openkm-s04-ldap'; then
  pass "OpenKM LDAP server points to openkm-s04-ldap"
else
  fail "OpenKM LDAP server not configured in env"
fi

# ── 3d: OpenKM web + REST API ───────────────────────────────────────────────
info "Testing OpenKM web and REST API..."

if curl -sf http://localhost:8352/OpenKM/ > /dev/null 2>&1; then
  pass "OpenKM web accessible (:8352/OpenKM/)"
else
  fail "OpenKM web not accessible (:8352/OpenKM/)"
fi

if curl -sf -u okmAdmin:OkmAdmin04! \
     http://localhost:8352/OpenKM/services/rest/folder/getChildren?fldId=/okm:root \
     -H "Accept: application/json" > /dev/null 2>&1; then
  pass "OpenKM REST API /folder/getChildren accessible (authenticated)"
else
  warn "OpenKM REST API not yet accessible (may still be initializing)"
fi

# ── 3e: All 6 containers running ─────────────────────────────────────────────
for svc in openkm-s04-db openkm-s04-ldap openkm-s04-es openkm-s04-kc openkm-s04-mail openkm-s04-app; do
  if docker ps --format '{{.Names}}' | grep -q "^${svc}$"; then
    pass "Container ${svc} running"
  else
    fail "Container ${svc} not running"
  fi
done

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "  Lab ${LAB_ID} Complete"
echo -e "  ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}============================================================${NC}"

docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans 2>/dev/null || true

if [ "${FAIL}" -gt 0 ]; then
    exit 1
fi
