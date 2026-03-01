#!/usr/bin/env bash
# test-lab-14-02.sh — Lab 14-02: External Dependencies
# Module 14: OpenKM Document Management
# Tests: external MySQL + Mailhog SMTP relay + REST API
set -euo pipefail

LAB_ID="14-02"
LAB_NAME="External Dependencies"
MODULE="openkm"
COMPOSE_FILE="docker/docker-compose.lan.yml"
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

info "Waiting for external MySQL (openkm-l02-db, up to 90s)..."
for i in $(seq 1 18); do
  if docker exec openkm-l02-db mysqladmin ping -uroot -pRootLab02! --silent 2>/dev/null; then
    pass "External MySQL healthy"; break
  fi
  [[ $i -eq 18 ]] && fail "External MySQL timed out"
  sleep 5
done

info "Waiting for Mailhog (openkm-l02-mail, up to 60s)..."
for i in $(seq 1 12); do
  if curl -sf http://localhost:8613/api/v2/messages > /dev/null 2>&1; then
    pass "Mailhog UI reachable on :8613"; break
  fi
  [[ $i -eq 12 ]] && fail "Mailhog not reachable on :8613"
  sleep 5
done

info "Waiting for OpenKM (up to 2 min)..."
for i in $(seq 1 24); do
  if curl -sf http://localhost:8313/openkm/ > /dev/null 2>&1; then
    pass "OpenKM reachable on :8313/openkm/"; break
  fi
  [[ $i -eq 24 ]] && fail "OpenKM not reachable on :8313/openkm/"
  sleep 5
done

# ── PHASE 3: Functional Tests ─────────────────────────────────────────────────
section "Phase 3: Functional Tests"

# Container states
for cname in openkm-l02-db openkm-l02-mail openkm-l02-app; do
  if docker inspect "${cname}" --format '{{.State.Status}}' 2>/dev/null | grep -q running; then
    pass "${cname} running"
  else
    fail "${cname} not running"
  fi
done

# External DB connectivity from app
if docker exec openkm-l02-app mysql -hopenkm-l02-db -uopenkm -pOpenKMLab02! openkm \
     -e "SELECT 1;" > /dev/null 2>&1; then
  pass "App connects to external MySQL (openkm DB)"
else
  fail "App cannot connect to external MySQL"
fi

# DB has OpenKM tables
TABLE_COUNT=$(docker exec openkm-l02-db mysql -uroot -pRootLab02! openkm \
  -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='openkm';" \
  --skip-column-names 2>/dev/null || echo 0)
if [[ "${TABLE_COUNT:-0}" -gt 20 ]]; then
  pass "External DB has ${TABLE_COUNT} OpenKM tables"
else
  fail "External DB has only ${TABLE_COUNT:-0} tables (expected >20)"
fi

# Mailhog API
if curl -sf http://localhost:8613/api/v2/messages | grep -q 'total\|items'; then
  pass "Mailhog API returns valid JSON"
else
  fail "Mailhog API not valid"
fi

# OpenKM REST API
HTTP_CODE=$(curl -o /dev/null -s -w "%{http_code}" \
  -u okmAdmin:admin \
  http://localhost:8313/openkm/services/rest/repository/info 2>/dev/null || echo 000)
if [[ "${HTTP_CODE}" =~ ^(200|201)$ ]]; then
  pass "OpenKM REST /repository/info HTTP ${HTTP_CODE}"
else
  fail "OpenKM REST HTTP ${HTTP_CODE} (expected 200)"
fi

# SMTP config points to Mailhog
if docker exec openkm-l02-app printenv OPENKM_SMTP_HOST 2>/dev/null | grep -q 'openkm-l02-mail'; then
  pass "SMTP_HOST configured to openkm-l02-mail"
else
  fail "SMTP_HOST not pointing to Mailhog container"
fi

# DB charset is utf8mb4
CHARSET=$(docker exec openkm-l02-db mysql -uroot -pRootLab02! \
  -e "SELECT DEFAULT_CHARACTER_SET_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='openkm';" \
  --skip-column-names 2>/dev/null || echo "unknown")
if [[ "${CHARSET}" == "utf8mb4" ]]; then
  pass "DB charset is utf8mb4"
else
  fail "DB charset is ${CHARSET} (expected utf8mb4)"
fi

# Environment variables
for envvar in OPENKM_DB_HOST OPENKM_DB_NAME OPENKM_DB_USER OPENKM_DB_PASS OPENKM_SMTP_HOST; do
  if docker exec openkm-l02-app printenv "${envvar}" > /dev/null 2>&1; then
    pass "Env var ${envvar} set"
  else
    fail "Env var ${envvar} missing"
  fi
done

# Volumes
for vol in openkm-l02-db-data openkm-l02-data openkm-l02-logs; do
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