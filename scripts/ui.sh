#!/usr/bin/env bash
#===============================================================================
# ui.sh — painel web de controle (abre no navegador).
# Uso:
#   ./scripts/ui.sh start [PORTA]   → liga (padrão 8080) e mostra o link
#   ./scripts/ui.sh stop            → desliga
#   ./scripts/ui.sh status          → estado + link
#   ./scripts/ui.sh url             → só mostra o link de acesso
#   ./scripts/ui.sh foreground      → roda preso ao terminal (debug)
# O link contém um token secreto — não compartilhe o painel sem ele.
#===============================================================================
set -u
source "$(dirname "$0")/common.sh"
require_cmd python3

UI_DIR="$ROOT_DIR/ui"
SERVER="$UI_DIR/server.py"
PID_FILE_UI="$UI_DIR/ui.pid"
TOKEN_FILE_UI="$UI_DIR/.token"
LOG_FILE_UI="$UI_DIR/ui.log"
PORT="${UI_PORT:-8080}"
[ "${2:-}" != "" ] && [ "${1:-}" = "start" ] && PORT="$2"

ui_running() {
  [ -f "$PID_FILE_UI" ] && kill -0 "$(cat "$PID_FILE_UI" 2>/dev/null)" 2>/dev/null
}

wait_token() {
  for _ in $(seq 1 25); do
    [ -s "$TOKEN_FILE_UI" ] && return 0
    sleep 0.2
  done
  return 1
}

print_url() {
  wait_token || { warn "token ainda não gerado — veja $LOG_FILE_UI"; return 1; }
  local tok base
  tok="$(cat "$TOKEN_FILE_UI")"
  if [ -n "${CODESPACE_NAME:-}" ]; then
    local dom="${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-app.github.dev}"
    base="https://${CODESPACE_NAME}-${PORT}.${dom}"
  else
    base="http://localhost:${PORT}"
  fi
  echo ""
  echo "  🖥️  PAINEL: ${base}/?token=${tok}"
  echo ""
  echo "  (Porta $PORT precisa estar visível: no Codespace ela é aberta"
  echo "   automaticamente; deixe como Privada.)"
  echo ""
}

CMD="${1:-status}"
case "$CMD" in
  start)
    mkdir -p "$UI_DIR/uploads"
    if ui_running; then
      log "Painel já está rodando."
      print_url
      exit 0
    fi
    log "Ligando painel na porta $PORT..."
    UI_PORT="$PORT" nohup python3 "$SERVER" >"$LOG_FILE_UI" 2>&1 &
    echo $! > "$PID_FILE_UI"
    sleep 2
    if ui_running; then
      ok "Painel no ar!"
      print_url
    else
      rm -f "$PID_FILE_UI"
      die "o painel morreu na largada. Veja $LOG_FILE_UI (porta $PORT ocupada?)"
    fi
    ;;
  stop)
    if ui_running; then
      kill "$(cat "$PID_FILE_UI")" 2>/dev/null || true
      sleep 1
      rm -f "$PID_FILE_UI"
    fi
    if ui_running; then die "não consegui parar o painel."; else ok "Painel parado."; fi
    ;;
  status)
    if ui_running; then ok "Painel RODANDO (PID $(cat "$PID_FILE_UI"))."; print_url;
    else log "Painel parado. Ligue com: ./scripts/ui.sh start"; fi
    ;;
  url) print_url ;;
  foreground)
    mkdir -p "$UI_DIR/uploads"
    UI_PORT="$PORT" python3 "$SERVER"
    ;;
  *) die "uso: $0 {start [PORTA]|stop|status|url|foreground}" ;;
esac
