#!/usr/bin/env bash
# check-dev-infra.sh — one-shot probe of local dev infrastructure.
#
# Surfaces the "backend silently in demo mode" failure class documented in
# runs/learned_patterns.json#46. Run BEFORE attempting verify-in-browser
# during a pre_merge_review HITL, or any time the dev loop produces
# inexplicable 404s from new BE routes.
#
# Probes (in dependency order):
#   1. Docker daemon
#   2. Postgres on :5432
#   3. MinIO on :9000 (S3 photo upload)
#   4. Backend on :3000 (+ demo-vs-prod mode check)
#   5. Frontend dev server on :5173
#
# Exit codes:
#   0 = all required services up
#   1 = at least one required service down
#   2 = Docker daemon down (everything else cascades from this)
#
# Output is human-readable with ANSI color when stdout is a tty.
# Quiet by default; pass --verbose for full diagnostic dumps.

set -u

# ----- terminal helpers ------------------------------------------------------
if [ -t 1 ]; then
  RESET="\033[0m"
  RED="\033[31m"
  GREEN="\033[32m"
  YELLOW="\033[33m"
  BOLD="\033[1m"
  DIM="\033[2m"
else
  RESET=""; RED=""; GREEN=""; YELLOW=""; BOLD=""; DIM=""
fi

ok()    { printf "  ${GREEN}✓${RESET} %s\n" "$1"; }
warn()  { printf "  ${YELLOW}!${RESET} %s\n" "$1"; }
fail()  { printf "  ${RED}✗${RESET} %s\n" "$1"; }
info()  { printf "    ${DIM}%s${RESET}\n" "$1"; }
header(){ printf "\n${BOLD}%s${RESET}\n" "$1"; }

VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1

DOWN=0
DOCKER_DOWN=0

# ----- 1. Docker daemon ------------------------------------------------------
header "1. Docker daemon"
if docker info >/dev/null 2>&1; then
  ok "Docker daemon responding"
  [ "$VERBOSE" = "1" ] && info "$(docker info 2>/dev/null | head -3)"
else
  fail "Docker daemon NOT running"
  info "Fix: open Docker Desktop (Applications → Docker) and wait for the whale icon to settle"
  DOCKER_DOWN=1
  DOWN=$((DOWN + 1))
fi

# ----- 2. Postgres on :5432 --------------------------------------------------
header "2. Postgres (:5432)"
if nc -z localhost 5432 2>/dev/null; then
  ok "Listener on :5432"
  if [ "$VERBOSE" = "1" ] && command -v psql >/dev/null 2>&1; then
    info "$(psql -h localhost -U pet -d pet_health -c 'SELECT version();' 2>&1 | head -2)"
  fi
else
  fail "Nothing listening on :5432"
  if [ "$DOCKER_DOWN" = "1" ]; then
    info "(cascades from Docker — fix above first)"
  else
    info "Fix: cd \$(git rev-parse --show-toplevel) && docker compose up -d postgres"
  fi
  DOWN=$((DOWN + 1))
fi

# ----- 3. MinIO on :9000 -----------------------------------------------------
header "3. MinIO / S3 (:9000)"
if curl -fsS -o /dev/null --max-time 2 http://localhost:9000/minio/health/live 2>/dev/null; then
  ok "MinIO healthy"
else
  if nc -z localhost 9000 2>/dev/null; then
    warn "Listener on :9000 but /minio/health/live didn't return 200"
    info "(may still be starting up; retry in 5s)"
    DOWN=$((DOWN + 1))
  else
    fail "Nothing listening on :9000 (photo upload will fail)"
    if [ "$DOCKER_DOWN" = "1" ]; then
      info "(cascades from Docker)"
    else
      info "Fix: docker compose up -d minio"
    fi
    DOWN=$((DOWN + 1))
  fi
fi

# ----- 4. Backend on :3000 + demo-mode check ---------------------------------
header "4. Backend (:3000)"
if nc -z localhost 3000 2>/dev/null; then
  ok "Listener on :3000"
  # Probe a known production-only route. /me/profile shipped in 004 T002.
  # In demo mode the backend returns 404 'Route GET:/me/profile not found';
  # in prod mode it returns 401 (auth-required).
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 http://localhost:3000/me/profile 2>/dev/null)
  case "$code" in
    401)
      ok "Production mode (route /me/profile returns 401 — auth-required, expected)"
      ;;
    404)
      fail "DEMO MODE — Postgres-driven routes not registered"
      info "The backend started without Postgres and fell back to a demo route set."
      info "Fix: ensure Postgres is up (#2 above), then kill+restart the backend (ts-node-dev)"
      DOWN=$((DOWN + 1))
      ;;
    "")
      warn "Probe timed out — backend may be starting"
      DOWN=$((DOWN + 1))
      ;;
    *)
      warn "Unexpected status $code on /me/profile (expected 401 in prod, 404 in demo)"
      ;;
  esac
else
  fail "Nothing listening on :3000"
  info "Fix: cd src/backend && npm run dev"
  DOWN=$((DOWN + 1))
fi

# ----- 5. Frontend dev server on :5173 ---------------------------------------
header "5. Frontend dev server (:5173)"
if curl -fsS -o /dev/null --max-time 2 http://localhost:5173/ 2>/dev/null; then
  ok "Webpack dev server responding"
  if [ "$VERBOSE" = "1" ]; then
    bundle_size=$(curl -s -o /dev/null -w "%{size_download}" --max-time 5 http://localhost:5173/main.js 2>/dev/null)
    [ -n "$bundle_size" ] && info "main.js size: $((bundle_size / 1024)) KiB"
  fi
else
  fail "Nothing serving on :5173"
  info "Fix: cd src/frontend && npm run web"
  DOWN=$((DOWN + 1))
fi

# ----- summary ---------------------------------------------------------------
echo
if [ "$DOWN" = "0" ]; then
  printf "${GREEN}${BOLD}✓ All required dev infra is up.${RESET}\n"
  printf "${DIM}You can verify-in-browser at http://localhost:5173/${RESET}\n"
  exit 0
else
  printf "${RED}${BOLD}✗ %d service(s) down or degraded.${RESET}\n" "$DOWN"
  printf "${DIM}Fix the items marked ✗ above before verify-in-browser.${RESET}\n"
  [ "$DOCKER_DOWN" = "1" ] && exit 2 || exit 1
fi
