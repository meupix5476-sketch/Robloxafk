#!/usr/bin/env bash
#===============================================================================
# restore.sh — restaura um backup .tar.gz (mundo + configs + addons).
# Faz backup de segurança do estado atual ANTES de restaurar.
# Uso:
#   ./scripts/restore.sh --list                  → lista backups
#   ./scripts/restore.sh <arquivo> [--yes]       → restaura (pede confirmação)
# Ex.: ./scripts/restore.sh backups/world-2026-09-19-2230.tar.gz
#===============================================================================
set -u
source "$(dirname "$0")/common.sh"

if [ "${1:-}" = "--list" ] || [ $# -eq 0 ]; then
  echo "Backups disponíveis em $BACKUP_DIR:"
  ls -lh "$BACKUP_DIR"/world-*.tar.gz 2>/dev/null || echo "(nenhum backup ainda — rode ./scripts/backup.sh)"
  [ $# -eq 0 ] && { echo "uso: $0 <arquivo.tar.gz> [--yes]"; exit 1; }
  exit 0
fi

FILE="$1"
YES=0
[ "${2:-}" = "--yes" ] && YES=1
[ -f "$FILE" ] || die "arquivo não encontrado: $FILE"
case "$FILE" in *.tar.gz) : ;; *) die "esperava um .tar.gz gerado pelo backup.sh";; esac

# Sanidade: o tar precisa conter o essencial
tar -tzf "$FILE" 2>/dev/null | grep -q "^server.properties$" \
  || die "este .tar.gz não parece um backup válido (sem server.properties)."

if [ "$YES" -eq 0 ]; then
  echo "Isso vai SUBSTITUIR o mundo/configs atuais pelo backup:"
  echo "  $FILE"
  read -r -p "Digite SIM para confirmar: " ans
  [ "$ans" = "SIM" ] || die "restauração cancelada."
fi

log "Parando servidor..."
"$ROOT_DIR/scripts/stop.sh" || true

LVL="$(level_name)"
if [ -d "$BEDROCK_DIR/worlds/$LVL" ]; then
  log "Backup de segurança do estado atual..."
  "$ROOT_DIR/scripts/backup.sh" || warn "pré-backup falhou — seguindo assim mesmo."
else
  log "Sem mundo atual — pulando pré-backup."
fi

log "Extraindo $FILE para bedrock-server/..."
tar -xzf "$FILE" -C "$BEDROCK_DIR" || die "falha ao extrair."
ok "Restauração concluída! Inicie com: ./scripts/start.sh"
