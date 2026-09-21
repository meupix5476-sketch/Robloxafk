#!/usr/bin/env bash
#===============================================================================
# cmd.sh — envia um comando ao console do servidor (sem precisar abrir o tmux).
# Exemplos:
#   ./scripts/cmd.sh 'say Olá, servidor!'
#   ./scripts/cmd.sh 'allowlist add Steve'
#   ./scripts/cmd.sh 'op Steve'
#   ./scripts/cmd.sh 'time set day'
#   ./scripts/cmd.sh 'save hold'   (etc.)
# Exige o servidor rodando em modo tmux (o padrão do ./scripts/start.sh).
#===============================================================================
set -u
source "$(dirname "$0")/common.sh"

[ $# -ge 1 ] || {
  echo "uso: $0 '<comando do console>'"
  echo "ex.: $0 'allowlist add Steve'"
  exit 1
}

server_running || die "servidor OFFLINE. Inicie com: ./scripts/start.sh"
server_cmd "$*" || die "sem console interativo (servidor rodando sem tmux?). Veja: tmux attach -t $MC_SESSION"
ok "comando enviado: $*"
log "Dica: veja a resposta em tmux attach -t $MC_SESSION"
