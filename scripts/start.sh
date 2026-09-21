#!/usr/bin/env bash
#===============================================================================
# start.sh — inicia o Bedrock Dedicated Server com supervisão anti-crash.
# Uso:
#   ./scripts/start.sh                 → inicia em background (tmux), volta p/ shell
#   ./scripts/start.sh --foreground    → inicia preso ao terminal (mostra console/logs)
#   ./scripts/start.sh --background    → igual ao padrão (tmux)
# Console ao vivo (modo background):  tmux attach -t mc-bedrock   (sair: Ctrl+B, D)
#===============================================================================
set -u
source "$(dirname "$0")/common.sh"

MODE="background"
SKIP_CHECK=0
for arg in "$@"; do
  [ "$arg" = "--foreground" ] && MODE="foreground"
  [ "$arg" = "--background" ] && MODE="background"
  [ "$arg" = "--child" ] && SKIP_CHECK=1   # interno: filho supervisionado
done

MAX_CRASHES="${MAX_CRASHES:-5}"   # após N falhas consecutivas, desiste
BASE_DELAY="${BASE_DELAY:-10}"    # atraso base (s) entre reinícios (10,20,30...)

[ -x "$BEDROCK_DIR/bedrock_server" ] || die "bedrock_server não instalado. Rode: ./scripts/install.sh"
[ "$SKIP_CHECK" -eq 0 ] && server_running && die "o servidor já está rodando. Pare com: ./scripts/stop.sh"

if [ "$MODE" = "background" ]; then
  if have_tmux; then
    log "Iniciando em background (tmux, sessão '$MC_SESSION')..."
    tmux new-session -d -s "$MC_SESSION" "$ROOT_DIR/scripts/start.sh --foreground --child"
    sleep 3
    if tmux_running "$MC_SESSION"; then
      ok "Servidor iniciado! Console ao vivo: tmux attach -t $MC_SESSION"
      log "Logs também em: bedrock-server/logs/ (e content log, se ativado)"
    else
      die "a sessão tmux morreu na largada. Rode ./scripts/start.sh --foreground para ver o erro."
    fi
    exit 0
  else
    warn "tmux não encontrado — usando nohup (sem console interativo). Instale tmux p/ ter console."
    cd "$BEDROCK_DIR" || die "sem acesso a $BEDROCK_DIR"
    export LD_LIBRARY_PATH="$BEDROCK_DIR:${LD_LIBRARY_PATH:-}"
    nohup "$ROOT_DIR/scripts/start.sh" --foreground --child >"$BEDROCK_DIR/server.log" 2>&1 &
    echo $! >"$PID_FILE"
    ok "Servidor iniciado via nohup (PID $!). Log: bedrock-server/server.log"
    exit 0
  fi
fi

# --- modo foreground supervisionado (roda DENTRO do tmux, ou no seu terminal) --
cd "$BEDROCK_DIR" || die "sem acesso a $BEDROCK_DIR"
export LD_LIBRARY_PATH="$BEDROCK_DIR:${LD_LIBRARY_PATH:-}"
log "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
log "Mundo: '$(level_name)' | porta UDP: $(server_port) | players: $(prop 'max-players')"

CRASHES=0
while true; do
  log ">>> Iniciando bedrock_server (tentativa $((CRASHES + 1)))..."
  START_TS="$(date +%s)"
  ./bedrock_server
  CODE=$?
  END_TS="$(date +%s)"
  UPTIME=$((END_TS - START_TS))

  if [ "$CODE" -eq 0 ]; then
    ok "Servidor encerrado normalmente (comando 'stop'). Até logo!"
    rm -f "$PID_FILE"
    exit 0
  fi

  # Se ficou vivo por >5 min, zera o contador (crash isolado, não loop)
  if [ "$UPTIME" -gt 300 ]; then CRASHES=0; fi
  CRASHES=$((CRASHES + 1))

  if [ "$CRASHES" -ge "$MAX_CRASHES" ]; then
    rm -f "$PID_FILE"
    die "servidor crashou $CRASHES vezes seguidas (último código: $CODE). NÃO vou reiniciar em loop. Veja os erros acima / bedrock-server/logs/ e rode ./scripts/start.sh de novo após corrigir."
  fi

  DELAY=$((BASE_DELAY * CRASHES))
  warn "bedrock_server saiu com código $CODE após ${UPTIME}s (falha $CRASHES/$MAX_CRASHES). Reiniciando em ${DELAY}s... (Ctrl+C para cancelar)"
  sleep "$DELAY"
done
