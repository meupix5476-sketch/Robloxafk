#!/usr/bin/env bash
#===============================================================================
# stop.sh — para o servidor com segurança (comando 'stop' → salva o mundo).
# Uso: ./scripts/stop.sh [--force]
#===============================================================================
set -u
source "$(dirname "$0")/common.sh"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

server_running || { log "Servidor já está parado."; rm -f "$PID_FILE"; exit 0; }

if [ "$FORCE" -eq 0 ] && tmux_running "$MC_SESSION"; then
  log "Enviando 'stop' ao console (salvamento seguro)..."
  server_cmd "stop" || die "não consegui falar com a sessão tmux."
  for i in $(seq 1 60); do
    server_running || break
    sleep 2
  done
fi

if server_running; then
  if [ "$FORCE" -eq 1 ] || tmux_running "$MC_SESSION"; then
    warn "Servidor ainda vivo após 120s — encerrando sessão/processo."
    tmux_running "$MC_SESSION" && tmux kill-session -t "$MC_SESSION" 2>/dev/null
    sleep 2
  fi
fi

if [ -f "$PID_FILE" ]; then
  PID="$(cat "$PID_FILE" 2>/dev/null)"
  if [ -n "${PID:-}" ] && kill -0 "$PID" 2>/dev/null; then
    warn "Matando PID $PID..."
    kill "$PID" 2>/dev/null; sleep 5
    kill -0 "$PID" 2>/dev/null && kill -9 "$PID" 2>/dev/null
  fi
  rm -f "$PID_FILE"
fi

pkill -x "bedrock_server" 2>/dev/null && sleep 2
server_running && die "não consegui parar o servidor. Tente: ./scripts/stop.sh --force"
ok "Servidor parado."
