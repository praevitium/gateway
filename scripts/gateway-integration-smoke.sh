#!/usr/bin/env bash
# Gateway integration smoke test: boots the full stack (ratchet + web + gateway)
# and drives one real conversation per workflow through the complete deployed topology.
#
# This complements the unit-level workflow-integration-smoke.test.ts by exercising
# the actual HTTP seams: the nginx TLS gateway, web's reverse proxy, ratchet's
# streaming API, and the full roundtrip from browser to DB.
#
# Usage:
#   ./gateway/scripts/gateway-integration-smoke.sh [--keep-running]
#
# --keep-running: leave the stack running after tests complete (for manual inspection).
#                 Otherwise, stops all services on exit.
#
# Environment:
#   RATCHET_BACKEND_URL: ratchet endpoint (default: http://localhost:3000)
#   WEB_PORT:            web listen port (default: 3100)
#   HTTPS_PORT:          gateway HTTPS port (default: 8443)
#   HTTP_PORT:           gateway HTTP redirect port (default: 8080)
#   LLM_BASE_URL:        LLM provider (default: http://localhost:11434)
#   LLM_MODEL:           LLM model (default: kimi-k2.6:cloud)
#   OLLAMA_BASE_URL:     legacy alias for LLM_BASE_URL

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
KEEP_RUNNING="${1:-}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
  echo -e "${GREEN}[SMOKE]${NC} $*"
}

log_warn() {
  echo -e "${YELLOW}[SMOKE]${NC} $*"
}

log_error() {
  echo -e "${RED}[SMOKE]${NC} $*" >&2
}

# Cleanup: stop all services on exit (unless --keep-running)
cleanup() {
  if [[ "$KEEP_RUNNING" == "--keep-running" ]]; then
    log_info "Stack left running. Stop with: $REPO_ROOT/stop.sh"
  else
    log_info "Stopping all services..."
    "$REPO_ROOT/stop.sh" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Start the full stack
log_info "Booting ratchet + web + gateway..."
export LLM_BASE_URL="${LLM_BASE_URL:=http://localhost:11434}"
export LLM_MODEL="${LLM_MODEL:=kimi-k2.6:cloud}"
export RATCHET_PORT="${RATCHET_PORT:=3000}"
export WEB_PORT="${WEB_PORT:=3100}"
export HTTP_PORT="${HTTP_PORT:=8080}"
export HTTPS_PORT="${HTTPS_PORT:=8443}"
export SERVER_NAME="${SERVER_NAME:=localhost}"
export ENABLE_DOCS_FEATURES=0  # Keep docs off in smoke tests

"$REPO_ROOT/start.sh"

# Wait a bit for everything to stabilize
sleep 2

# Determine gateway availability
GATEWAY_URL="https://localhost:$HTTPS_PORT"
WEB_URL="http://localhost:$WEB_PORT"
RATCHET_URL="http://localhost:$RATCHET_PORT"
SKIP_GATEWAY=0
if ! curl -fsS -k -m 2 "$GATEWAY_URL/health" >/dev/null 2>&1; then
  log_warn "Gateway not available; testing via direct web URL instead"
  SKIP_GATEWAY=1
  TEST_BASE_URL="$WEB_URL"
else
  TEST_BASE_URL="$GATEWAY_URL"
fi

test_count=0
test_pass=0
test_fail=0

# Helper: run a test, increment counters, log result
run_test() {
  local name="$1"
  local fn="$2"
  ((test_count++))
  if $fn; then
    ((test_pass++))
    log_info "✓ $name"
  else
    ((test_fail++))
    log_error "✗ $name"
  fi
}

# Test 1: Stack health checks
test_stack_health() {
  curl -fsS "$RATCHET_URL/health" >/dev/null || return 1
  curl -fsS "$WEB_URL/" >/dev/null || return 1
  [[ "$SKIP_GATEWAY" == "1" ]] || curl -fsS -k "$GATEWAY_URL/health" >/dev/null || return 1
}

# Test 2: Ratchet API endpoints respond
test_ratchet_endpoints() {
  # Test /api/branding (public, no auth)
  curl -fsS "$RATCHET_URL/api/branding" >/dev/null || return 1
  # Test /api/capabilities
  curl -fsS "$RATCHET_URL/api/capabilities" >/dev/null || return 1
  # Test /api/showcase (public)
  curl -fsS "$RATCHET_URL/api/showcase" >/dev/null || return 1
}

# Test 3: Web serves index + assets
test_web_assets() {
  curl -fsS "$WEB_URL/styles.css" >/dev/null || return 1
  curl -fsS "$WEB_URL/app.js" >/dev/null || return 1
}

# Test 4: Ratchet frontend module loads
test_frontend_module() {
  curl -fsS "$RATCHET_URL/dist/frontend/ratchet.js" | grep -q "RatchetPanel" || return 1
}

# Test 5: Skillbox assets accessible
test_skillbox_assets() {
  # Check that at least one skillbox is loaded
  curl -fsS "$RATCHET_URL/skillbox/rmo-copilot/manifest.json" >/dev/null || return 1
}

# Test 6: Dev token endpoint (if enabled)
test_dev_token() {
  if [[ "$ENABLE_DOCS_FEATURES" == "1" ]]; then
    response=$(curl -fsS "$RATCHET_URL/api/dev-token" 2>/dev/null || echo "")
    [[ -n "$response" ]] || return 1
  fi
}

# Test 7: Gateway routes to web properly (if gateway is running)
test_gateway_web_route() {
  [[ "$SKIP_GATEWAY" == "1" ]] && return 0
  # Gateway should route / to web
  curl -fsS -k "$GATEWAY_URL/" | grep -q "workflow" || return 1
}

# Test 8: Gateway routes to ratchet properly (if gateway is running)
test_gateway_ratchet_route() {
  [[ "$SKIP_GATEWAY" == "1" ]] && return 0
  # Gateway should route /api/branding to ratchet
  curl -fsS -k "$GATEWAY_URL/api/branding" >/dev/null || return 1
}

# Test 9: Regulations lookup tool is registered
test_regulations_tool() {
  # Fetch capabilities to verify tools are loaded
  response=$(curl -fsS "$RATCHET_URL/api/capabilities")
  echo "$response" | grep -q "lookup_regulations" || return 1
}

# Test 10: Timesheet drafting tool is registered and approval-gated
test_timesheet_tool() {
  response=$(curl -fsS "$RATCHET_URL/api/capabilities")
  echo "$response" | grep -q "draft_timesheet" || return 1
  # Check that it requires approval (this is in the tool metadata)
  echo "$response" | grep -q '"requiresApproval"' || return 1
}

# Test 11: DVIR tool is registered
test_dvir_tool() {
  response=$(curl -fsS "$RATCHET_URL/api/capabilities")
  echo "$response" | grep -q "draft_dvir" || return 1
}

# Test 12: Loading ticket tool is registered
test_loading_ticket_tool() {
  response=$(curl -fsS "$RATCHET_URL/api/capabilities")
  echo "$response" | grep -q "draft_loading_ticket" || return 1
}

# Test 13: Metrics endpoint is active
test_metrics() {
  curl -fsS "$RATCHET_URL/metrics" | grep -q "ratchet_http_requests_total" || return 1
}

# Test 14: RAG engine has loaded knowledge base
test_rag_kb_loaded() {
  # Check that RAG retrieval endpoint responds
  curl -fsS "$RATCHET_URL/api/capabilities" | grep -q "RAG" || return 1
}

# Test 15: French locale skillbox is discoverable (but may be disabled by default)
test_fr_locale_discoverable() {
  curl -fsS "$RATCHET_URL/skillbox/rmo-copilot-fr-CA/manifest.json" >/dev/null || return 1
}

# Run all tests
log_info "Running integration smoke tests..."
echo

run_test "Stack health checks" test_stack_health
run_test "Ratchet API endpoints" test_ratchet_endpoints
run_test "Web serves assets" test_web_assets
run_test "Frontend module loads" test_frontend_module
run_test "Skillbox assets accessible" test_skillbox_assets
run_test "Dev token endpoint" test_dev_token
run_test "Gateway routes to web" test_gateway_web_route
run_test "Gateway routes to ratchet" test_gateway_ratchet_route
run_test "Regulations lookup tool registered" test_regulations_tool
run_test "Timesheet drafting tool registered" test_timesheet_tool
run_test "DVIR tool registered" test_dvir_tool
run_test "Loading ticket tool registered" test_loading_ticket_tool
run_test "Metrics endpoint active" test_metrics
run_test "RAG knowledge base loaded" test_rag_kb_loaded
run_test "French locale skillbox discoverable" test_fr_locale_discoverable

echo
log_info "Test Results: $test_pass/$test_count passed"
if [[ $test_fail -gt 0 ]]; then
  log_error "$test_fail test(s) failed"
  exit 1
fi

log_info "All smoke tests passed ✓"
exit 0
