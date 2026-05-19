#!/usr/bin/env bash
set -euo pipefail
# deploy_and_status.sh — Deploy and manage Node.js app, BullMQ worker, and FastAPI microservice
# Requires: bash, tmux, node, npm, python3, pip, psql, redis-server, jq
# Usage: ./deploy_and_status.sh [start [install|check|services]|stop|restart|status]
# Version: 1.1.1
# ------------------------------
# Configuration
# ------------------------------
TMUX_SESSION="voice-agent"
PORT=${PORT:-3000}
DATABASE_URL=${DATABASE_URL:-postgres://postgres:postgres@localhost:5432/db}
REDIS_URL=${REDIS_URL:-redis://localhost:6379}
PYTHON_VENV="venv"
FASTAPI_PORT=4001
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PID_FILE="$PROJECT_ROOT/.pids"
# ------------------------------
# Helpers
# ------------------------------
log() { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
err() { printf '\033[1;31m[ERR]\033[0m %s\n' "$*" >&2; exit 1; }
check_cmd() { command -v "$1" >/dev/null 2>&1 || { warn "Missing command: $1"; return 1; }; }
handle_error() {
  warn "$1"
  while true; do
    read -p "Continue anyway? (y/n): " choice
    case "$choice" in
      y|Y ) return 0;;
      n|N ) exit 1;;
      * ) echo "Please answer y or n.";;
    esac
  done
}
# ------------------------------
# Dependency Installation
# ------------------------------
install_dependencies() {
  log "Installing system dependencies..."
  if [[ "$(uname -s)" == "Linux" ]]; then
    sudo apt-get update -y || handle_error "Failed to update package lists"
    sudo apt-get install -y nodejs npm python3 python3-pip python3-venv postgresql redis-server jq tmux || handle_error "Failed to install system dependencies"
    sudo systemctl start postgresql redis || { warn "Failed to start PostgreSQL or Redis services"; handle_error "Service start issue"; }
    sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD 'postgres';" >/dev/null 2>&1 || { warn "Failed to set Postgres password"; handle_error "Postgres password set issue"; }
  else
    warn "Non-Linux system detected. Please install nodejs, npm, python3, pip3, postgresql, redis-server, jq, and tmux manually."
    handle_error "Manual installation required for non-Linux system"
  fi
}
# ------------------------------
# Dependency Checks
# ------------------------------
check_dependencies() {
  log "Checking dependencies..."
  local missing=0
  check_cmd node || missing=1
  check_cmd npm || missing=1
  check_cmd python3 || missing=1
  check_cmd pip3 || missing=1
  check_cmd psql || missing=1
  check_cmd redis-server || missing=1
  check_cmd jq || missing=1
  check_cmd tmux || missing=1
  if [ "$missing" -eq 0 ]; then
    log "All dependencies are installed"
  else
    handle_error "Some dependencies are missing. Consider running './deploy_and_status.sh start install' to install them."
  fi
}
# ------------------------------
# Environment Setup
# ------------------------------
setup_environment() {
  log "Setting up environment..."
  if [ ! -f "$PROJECT_ROOT/.env" ]; then
    log "Copying .env.example to .env..."
    [ -f "$PROJECT_ROOT/.env.example" ] || handle_error ".env.example not found. Please create it with required variables."
    cp "$PROJECT_ROOT/.env.example" "$PROJECT_ROOT/.env" || handle_error "Failed to copy .env.example"
  fi
  source "$PROJECT_ROOT/.env"
  [ -n "${OPENAI_API_KEY:-}" ] || handle_error "Missing OPENAI_API_KEY in .env"
  : "${MODEL_NAME:=gpt-4o-realtime-preview-2024-12-17}"
  : "${VOICE_ID:=ash}"
  [ -n "${ADMIN_API_KEY:-}" ] || handle_error "Missing ADMIN_API_KEY in .env"
  export OPENAI_API_KEY MODEL_NAME VOICE_ID DATABASE_URL REDIS_URL ADMIN_API_KEY
  log "Environment variables loaded"
}
# ------------------------------
# Database Setup
# ------------------------------
setup_database() {
  log "Setting up PostgreSQL..."
  psql "$DATABASE_URL/postgres" -c "SELECT 1" >/dev/null || handle_error "Postgres connection failed. Ensure PostgreSQL is running and DATABASE_URL is correct."
  "$PROJECT_ROOT/dbctl.sh" create || handle_error "Failed to create database"
  "$PROJECT_ROOT/dbctl.sh" migrate || handle_error "Failed to migrate database"
  if [ -f "$PROJECT_ROOT/profnastil_price.json" ]; then
    log "Importing profnastil_price.json..."
    "$PROJECT_ROOT/dbctl.sh" import --json "$PROJECT_ROOT/profnastil_price.json" || handle_error "Failed to import JSON"
  else
    warn "profnastil_price.json not found, skipping import"
  fi
}
# ------------------------------
# Python Virtual Environment Setup
# ------------------------------
setup_python_venv() {
  log "Setting up Python virtual environment..."
  if [ ! -d "$PROJECT_ROOT/$PYTHON_VENV" ]; then
    python3 -m venv "$PROJECT_ROOT/$PYTHON_VENV" || handle_error "Failed to create venv"
  fi
  source "$PROJECT_ROOT/$PYTHON_VENV/bin/activate"
  pip3 install -U pip wheel || handle_error "Failed to update pip"
  pip3 install fastapi uvicorn rapidfuzz faiss-cpu openai || handle_error "Failed to install Python dependencies"
}
# ------------------------------
# Node.js Dependencies
# ------------------------------
setup_node_deps() {
  log "Installing Node.js dependencies..."
  npm ci --prefix "$PROJECT_ROOT" || handle_error "npm ci failed"
}
# ------------------------------
# Start Services
# ------------------------------
start_services() {
  log "Starting services in tmux session '$TMUX_SESSION'..."
  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    handle_error "tmux session '$TMUX_SESSION' already exists. Run './deploy_and_status.sh stop' first."
  fi
  # Ensure logs directory exists
  mkdir -p "$PROJECT_ROOT/logs"
  # Start tmux session
  tmux new-session -d -s "$TMUX_SESSION" "cd $PROJECT_ROOT && npm start > $PROJECT_ROOT/logs/node.log 2>&1"
  tmux new-window -t "$TMUX_SESSION:1" "cd $PROJECT_ROOT && node embeddingsWorker.js > $PROJECT_ROOT/logs/worker.log 2>&1"
  tmux new-window -t "$TMUX_SESSION:2" "cd $PROJECT_ROOT/services/price-search && source $PROJECT_ROOT/$PYTHON_VENV/bin/activate && uvicorn main:app --host 0.0.0.0 --port $FASTAPI_PORT > $PROJECT_ROOT/logs/fastapi.log 2>&1"
  # Save PIDs
  echo "node_server_pid=$(tmux list-panes -t "$TMUX_SESSION:0" -F "#{pane_pid}" | head -n1)" > "$PID_FILE"
  echo "worker_pid=$(tmux list-panes -t "$TMUX_SESSION:1" -F "#{pane_pid}" | head -n1)" >> "$PID_FILE"
  echo "fastapi_pid=$(tmux list-panes -t "$TMUX_SESSION:2" -F "#{pane_pid}" | head -n1)" >> "$PID_FILE"
  # Wait for services to start
  log "Waiting for services to start..."
  sleep 5
  # Health checks
  curl -fsS "http://localhost:$PORT/api/health" >/dev/null && log "Node.js server healthy" || { warn "Node.js server health check failed"; cat "$PROJECT_ROOT/logs/node.log"; handle_error "Node.js health check issue"; }
  if curl -fsS "http://localhost:$FASTAPI_PORT/health" >/dev/null; then
    log "FastAPI microservice healthy"
  else
    warn "FastAPI health check failed"
    [ -f "$PROJECT_ROOT/logs/fastapi.log" ] && cat "$PROJECT_ROOT/logs/fastapi.log"
    handle_error "FastAPI service failed to start. Check logs above for details."
  fi
}
# ------------------------------
# Stop Services
# ------------------------------
stop_services() {
  log "Stopping services..."
  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    tmux kill-session -t "$TMUX_SESSION" || warn "Failed to kill tmux session"
    log "tmux session '$TMUX_SESSION' stopped"
  else
    warn "No tmux session '$TMUX_SESSION' found"
  fi
  rm -f "$PID_FILE"
}
# ------------------------------
# Restart Services
# ----------------------
restart_services() {
  log "Restarting services..."
  stop_services
  start_services
}
# ------------------------------
# Check Status
# ------------------------------
check_status() {
  log "Checking service status..."
  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    log "tmux session '$TMUX_SESSION' is running"
    if [ -f "$PID_FILE" ]; then
      source "$PID_FILE"
      log "Node.js server PID: ${node_server_pid:-unknown}"
      log "BullMQ worker PID: ${worker_pid:-unknown}"
      log "FastAPI microservice PID: ${fastapi_pid:-unknown}"
    else
      warn "PID file not found"
    fi
    curl -fsS "http://localhost:$PORT/api/health" >/dev/null && log "Node.js server: healthy" || warn "Node.js server: unhealthy"
    curl -fsS "http://localhost:$FASTAPI_PORT/health" >/dev/null && log "FastAPI microservice: healthy" || warn "FastAPI microservice: unhealthy"
  else
    log "tmux session '$TMUX_SESSION' is not running"
  fi
}
# ------------------------------
# Check Environment and Database
# ------------------------------
check_environment() {
  log "Checking environment and database..."
  check_dependencies
  setup_environment
  if psql "$DATABASE_URL/postgres" -c "SELECT 1" >/dev/null 2>&1; then
    log "PostgreSQL connection: OK"
  else
    warn "PostgreSQL connection: Failed"
  fi
  if [ -f "$PROJECT_ROOT/profnastil_price.json" ]; then
    log "Price data file: Found"
    local duplicate_skus
    duplicate_skus=$(jq -r '.[] | .name + "_" + (.["Толщина металла (мм)"] | tostring) + "_" + (.["Общая ширина профиля (мм)"] | tostring)' "$PROJECT_ROOT/profnastil_price.json" | sort | uniq -d)
    if [ -n "$duplicate_skus" ]; then
      warn "Duplicate SKUs detected in profnastil_price.json:\n$duplicate_skus"
    else
      log "Price data: No duplicate SKUs detected"
    fi
  else
    warn "Price data file: Not found"
  fi
  if curl -fsS "http://localhost:$PORT/api/health" >/dev/null 2>&1; then
    log "Node.js server: Running"
  else
    log "Node.js server: Not running"
  fi
  if curl -fsS "http://localhost:$FASTAPI_PORT/health" >/dev/null 2>&1; then
    log "FastAPI microservice: Running"
  else
    log "FastAPI microservice: Not running"
  fi
}
# ------------------------------
# Usage
# ------------------------------
usage() {
  cat <<EOF
Usage: $0 [start [install|check|services]|stop|restart|status]
Version: $SCRIPT_VERSION
Commands:
  start Run all actions (install, check, services)
  start install Install system dependencies
  start check Check environment and database setup
  start services Start Node.js server, BullMQ worker, and FastAPI microservice (assumes setups done)
  stop Stop all services
  restart Restart all services
  status Check service status
Examples:
  $0 start # Run full deployment
  $0 start install # Install dependencies only
  $0 start check # Check environment and database
  $0 start services # Start services only
  $0 stop # Stop all services
  $0 status # Check service status
EOF
}
# ------------------------------
# Main
# ------------------------------
main() {
  case "${1:-start}" in
    start)
      shift
      case "${1:-all}" in
        install)
          install_dependencies
          ;;
        check)
          check_environment
          ;;
        services)
          setup_environment
          start_services
          log "Services started. Web-Agent: http://localhost:$PORT | Search API: http://localhost:$FASTAPI_PORT/health"
          ;;
        all)
          install_dependencies
          check_environment
          setup_database
          setup_python_venv
          setup_node_deps
          start_services
          log "Full deployment complete. Web-Agent: http://localhost:$PORT | Search API: http://localhost:$FASTAPI_PORT/health"
          ;;
        *)
          usage
          handle_error "Invalid subcommand for 'start'"
          ;;
      esac
      ;;
    stop)
      stop_services
      ;;
    restart)
      restart_services
      ;;
    status)
      check_status
      ;;
    help|--help|-h)
      usage
      ;;
    *)
      usage
      handle_error "Invalid command"
      ;;
  esac
}
# Trap SIGTERM for graceful shutdown
trap 'stop_services; exit 0' SIGTERM
main "$@"