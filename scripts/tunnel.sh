#!/usr/bin/env bash
#===============================================================================
# tunnel.sh — túnel UDP (playit.gg) para jogar pelo celular/console.
# Por que existe: o encaminhamento de portas do GitHub Codespaces só suporta
# TCP/HTTP(S); Minecraft Bedrock usa UDP/19132, que NÃO passa por ele.
# O playit.gg (gratuito) cria um endereço público UDP que aponta p/ o servidor.
#
# Uso:
#   ./scripts/tunnel.sh setup            → instala agente + guia o login (1ª vez)
#   ./scripts/tunnel.sh start            → liga o túnel (usa secret já salvo)
#   ./scripts/tunnel.sh stop             → desliga o túnel
#   ./scripts/tunnel.sh status           → mostra estado + endereço/porta
#   ./scripts/tunnel.sh set HOST PORTA   → salva endereço mostrado no site
#===============================================================================
set -u
source "$(dirname "$0")/common.sh"

PLAYIT_BIN="$TUNNEL_DIR/bin/playit"
PLAYIT_CLI="$TUNNEL_DIR/bin/playit-cli"
SECRET_FILE="$TUNNEL_DIR/playit.toml"     # NUNCA vai pro git (.gitignore)
SOCK_FILE="$TUNNEL_DIR/playit.sock"
LOG_FILE="$TUNNEL_DIR/playitd.log"
INFO_FILE="$TUNNEL_DIR/tunnel-info.txt"   # HOST e PORTA públicos (gerado)
PLAYIT_VERSION="${PLAYIT_VERSION:-v1.0.10}"

CMD="${1:-status}"

detect_asset() {
  case "$(uname -m)" in
    x86_64)  echo "amd64" ;;
    aarch64) echo "aarch64" ;;
    armv7l)  echo "armv7" ;;
    *) die "arquitetura $(uname -m) sem binário playit conhecido." ;;
  esac
}

download_agent() {
  [ -x "$PLAYIT_BIN" ] && [ -x "$PLAYIT_CLI" ] && { log "Agente playit já baixado."; return; }
  local arch; arch="$(detect_asset)"
  mkdir -p "$TUNNEL_DIR/bin"
  log "Baixando agente playit $PLAYIT_VERSION (releases oficiais no GitHub)..."
  curl -fSL --retry 3 --max-time 300 \
    -o "$PLAYIT_BIN" "https://github.com/playit-cloud/playit-agent/releases/download/$PLAYIT_VERSION/playit-linux-$arch" \
    || die "falha ao baixar o playit. Confira a internet do Codespace."
  curl -fSL --retry 3 --max-time 300 \
    -o "$PLAYIT_CLI" "https://github.com/playit-cloud/playit-agent/releases/download/$PLAYIT_VERSION/playit-cli-linux-$arch" \
    || die "falha ao baixar o playit-cli."
  chmod +x "$PLAYIT_BIN" "$PLAYIT_CLI"
  ok "Agente instalado em tunnel/bin/."
}

playit_running() {
  tmux_running "$PLAYIT_SESSION" && return 0
  [ -f "$TUNNEL_DIR/playit.pid" ] && kill -0 "$(cat "$TUNNEL_DIR/playit.pid" 2>/dev/null)" 2>/dev/null && return 0
  # casa o binário exato (basename), sem pegadas em shells que só mencionam o caminho
  pgrep -f "[t]unnel/bin/playit( |$)" >/dev/null 2>&1
}

claim_flow() {
  echo ""
  echo "=================================================================="
  echo "  LOGIN NO PLAYIT.GG (só precisa 1 vez — pare aqui e leia!)"
  echo "=================================================================="
  local code url
  code="$("$PLAYIT_CLI" claim generate)" || die "playit-cli falhou."
  url="$("$PLAYIT_CLI" claim url "$code" --name modded-crafters)" || die "não gerei a URL de claim."
  echo ""
  echo "  1) Abra este link NO SEU NAVEGADOR (celular ou PC):"
  echo ""
  echo "       $url"
  echo ""
  echo "  2) Entre/crie sua conta playit.gg e clique em CLAIM / ADD AGENT."
  echo "  3) Volte aqui e aperte ENTER."
  echo ""
  read -r -p "  Aperte ENTER depois de concluir no site... " _dummy
  log "Trocando claim pelo secret (aguardando até 10 min, não mostra o secret)..."
  local secret
  secret="$("$PLAYIT_CLI" claim exchange "$code" --wait 600)" || die "claim expirou ou falhou. Rode de novo: ./scripts/tunnel.sh setup"
  printf 'secret_key = "%s"\n' "$secret" > "$SECRET_FILE"
  chmod 600 "$SECRET_FILE"
  unset secret
  ok "Agente autorizado! Secret salvo em tunnel/playit.toml (permissão 600, fora do git)."
}

create_tunnel_hint() {
  echo ""
  echo "=================================================================="
  echo "  CRIAR O TÚNEL MINECRAFT BEDROCK (no site playit.gg)"
  echo "=================================================================="
  echo "  1) Abra https://playit.gg/account/tunnels (logado)."
  echo "  2) Clique em ADD TUNNEL / CREATE."
  echo "  3) Escolha o agente 'modded-crafters'."
  echo "  4) Tipo do túnel:  Minecraft Bedrock  (ou 'Minecraft Bedrock (UDP)')."
  echo "  5) Local IP: 127.0.0.1   Local porta: $(server_port)"
  echo "  6) Salve. O site mostra algo como:  joyful-dragon-1234.at.ply.gg:56789"
  echo ""
  echo "  Depois salve aqui com:"
  echo "      ./scripts/tunnel.sh set joyful-dragon-1234.at.ply.gg 56789"
  echo "=================================================================="
  echo ""
}

detect_from_log() {
  # Tenta achar "host:porta" público no log do agente
  [ -f "$LOG_FILE" ] || return 1
  grep -oE '[a-z0-9.-]+\.(at\.ply\.gg|ply\.gg):[0-9]+' "$LOG_FILE" 2>/dev/null | tail -n1
}

start_daemon() {
  playit_running && { log "Túnel já está rodando."; return; }
  local args=()
  if [ -n "${PLAYIT_SECRET:-}" ]; then
    log "Usando PLAYIT_SECRET do ambiente (Codespace secret)."
    args=(--secret "$PLAYIT_SECRET")
  elif [ -f "$SECRET_FILE" ]; then
    args=(--secret-path "$SECRET_FILE")
  else
    die "sem secret. Rode: ./scripts/tunnel.sh setup"
  fi
  if have_tmux; then
    log "Iniciando playit em background (tmux '$PLAYIT_SESSION')..."
    tmux new-session -d -s "$PLAYIT_SESSION" \
      "cd '$TUNNEL_DIR' && '$PLAYIT_BIN' ${args[*]} --socket-path '$SOCK_FILE' -l '$LOG_FILE'; echo '--- playit encerrou (código '\$?') ---'; sleep 86400"
    sleep 3
    playit_running && ok "playit rodando! Log: tunnel/playitd.log" || die "playit morreu na largada. Veja tunnel/playitd.log"
  else
    warn "sem tmux — rodando com nohup."
    cd "$TUNNEL_DIR" || die "sem acesso a $TUNNEL_DIR"
    nohup "$PLAYIT_BIN" "${args[@]}" --socket-path "$SOCK_FILE" -l "$LOG_FILE" >"$TUNNEL_DIR/playit.out" 2>&1 &
    echo $! > "$TUNNEL_DIR/playit.pid"
    ok "playit rodando via nohup (PID $!)."
  fi
}

show_info() {
  echo ""
  if [ -f "$INFO_FILE" ]; then
    # shellcheck disable=SC1090
    source "$INFO_FILE"
    echo "  IP/ENDEREÇO: ${TUNNEL_HOST:-?}"
    echo "  PORTA:       ${TUNNEL_PORT:-?}"
  else
    echo "  IP/ENDEREÇO: (ainda não salvo — crie o túnel no site e use 'tunnel.sh set HOST PORTA')"
    echo "  PORTA:       (ainda não salva)"
    local found
    found="$(detect_from_log)" && echo "  Detectado no log (confirme no site): $found"
  fi
  echo ""
  echo "  No Minecraft Bedrock: Jogar → Servidores → Adicionar servidor,"
  echo "  coloque o ENDEREÇO e a PORTA acima."
  echo ""
}

case "$CMD" in
  setup)
    download_agent
    if [ -n "${PLAYIT_SECRET:-}" ]; then
      log "PLAYIT_SECRET detectado — pulando login."
    elif [ ! -f "$SECRET_FILE" ]; then
      claim_flow
    else
      log "Secret já existe — pulando login."
    fi
    start_daemon
    create_tunnel_hint
    show_info
    ;;
  start)
    download_agent
    start_daemon
    show_info
    ;;
  stop)
    if tmux_running "$PLAYIT_SESSION"; then tmux kill-session -t "$PLAYIT_SESSION"; fi
    if [ -f "$TUNNEL_DIR/playit.pid" ]; then
      kill "$(cat "$TUNNEL_DIR/playit.pid" 2>/dev/null)" 2>/dev/null || true
      rm -f "$TUNNEL_DIR/playit.pid"
      sleep 2
    fi
    playit_running && die "não consegui parar o playit." || ok "Túnel parado."
    ;;
  set)
    HOST="${2:-}"; PORT="${3:-}"
    [ -n "$HOST" ] && [ -n "$PORT" ] || die "uso: $0 set <HOST> <PORTA>  (ex: $0 set abc.at.ply.gg 12345)"
    printf 'TUNNEL_HOST="%s"\nTUNNEL_PORT="%s"\n' "$HOST" "$PORT" > "$INFO_FILE"
    ok "Endereço salvo!"
    show_info
    ;;
  status)
    if playit_running; then ok "playit RODANDO."; else warn "playit PARADO."; fi
    if [ -x "$PLAYIT_CLI" ]; then
      "$PLAYIT_CLI" --socket-path "$SOCK_FILE" status 2>/dev/null || log "(daemon sem IPC agora — ele pode estar iniciando)"
    fi
    show_info
    ;;
  download)
    download_agent
    ;;
  claim-url)
    # Não-interativo (p/ o painel web): imprime "CODIGO|URL"
    download_agent
    CODE="$("$PLAYIT_CLI" claim generate)" || die "playit-cli falhou."
    URL="$("$PLAYIT_CLI" claim url "$CODE" --name modded-crafters)" || die "não gerei a URL."
    printf '%s|%s\n' "$CODE" "$URL"
    ;;
  claim-finish)
    # Não-interativo: troca o claim pelo secret (aguarda até 2 min)
    CODE="${2:-}"
    [ -n "$CODE" ] || die "uso: $0 claim-finish <CODIGO>"
    SECRET="$("$PLAYIT_CLI" claim exchange "$CODE" --wait 120)" \
      || die "claim expirou ou não foi autorizado no site."
    printf 'secret_key = "%s"\n' "$SECRET" > "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"
    unset SECRET
    ok "claim concluído — secret salvo."
    ;;
  *)
    die "comando desconhecido: $CMD  (use: setup | start | stop | status | set | download | claim-url | claim-finish)"
    ;;
esac
