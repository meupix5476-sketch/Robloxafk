#!/usr/bin/env bash
#===============================================================================
# backup.sh — backup seguro do mundo + configs + addons.
# Gera: backups/world-AAAA-MM-DD-HHMM.tar.gz  (mantém os últimos N, padrão 5)
# Uso: ./scripts/backup.sh [--keep N]
#===============================================================================
set -u
source "$(dirname "$0")/common.sh"

KEEP="${BACKUP_KEEP:-5}"
[ "${1:-}" = "--keep" ] && KEEP="${2:-5}"

LVL="$(level_name)"
WORLD_DIR="$BEDROCK_DIR/worlds/$LVL"
[ -d "$WORLD_DIR" ] || die "mundo '$LVL' ainda não existe em bedrock-server/worlds/. Inicie o servidor 1 vez para gerá-lo."

mkdir -p "$BACKUP_DIR"
STAMP="$(date '+%Y-%m-%d-%H%M')"
OUT="$BACKUP_DIR/world-$STAMP.tar.gz"
[ -e "$OUT" ] && OUT="$BACKUP_DIR/world-$STAMP-$$.tar.gz"

# 1) Congela salvamento se o servidor estiver com console acessível
HELD=0
if tmux_running "$MC_SESSION"; then
  log "Servidor online — congelando escrita do mundo (save hold/query)..."
  server_cmd "save hold" && HELD=1
  sleep 2
  server_cmd "save query" || true
  sleep 5
else
  log "Servidor offline — copiando arquivos diretamente."
fi

# 2) Compacta mundo + configs + addons + registro de packs do mundo
log "Compactando para $(basename "$OUT")..."
tar -czf "$OUT" -C "$BEDROCK_DIR" \
  "worlds/$LVL" \
  server.properties allowlist.json permissions.json \
  behavior_packs resource_packs \
  2>/dev/null || die "falha ao criar o tar.gz."

# 3) Libera salvamento
if [ "$HELD" -eq 1 ]; then
  server_cmd "save resume" || warn "'save resume' falhou — verifique o console!"
fi

SIZE="$(du -h "$OUT" | cut -f1)"
ok "Backup pronto: $OUT ($SIZE)"

# 4) Poda: mantém só os $KEEP mais recentes
COUNT="$(ls -1 "$BACKUP_DIR"/world-*.tar.gz 2>/dev/null | wc -l)"
if [ "$COUNT" -gt "$KEEP" ]; then
  DEL=$((COUNT - KEEP))
  log "Apagando $DEL backup(s) antigo(s) (mantendo $KEEP)..."
  ls -1tr "$BACKUP_DIR"/world-*.tar.gz | head -n "$DEL" | xargs -r rm -f
fi

log "Backups atuais:"
ls -lh "$BACKUP_DIR"/world-*.tar.gz 2>/dev/null || true
