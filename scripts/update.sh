#!/usr/bin/env bash
#===============================================================================
# update.sh — atualiza o BDS para a versão ESTÁVEL mais recente (nunca Preview).
# Fluxo: para com segurança → backup → baixa oficial → preserva mundo/addons/
# configs → atualiza binários → inicia de novo.
# Uso: ./scripts/update.sh [--no-start]
#===============================================================================
set -u
source "$(dirname "$0")/common.sh"

NO_START=0
[ "${1:-}" = "--no-start" ] && NO_START=1
WAS_RUNNING=0
server_running && WAS_RUNNING=1

log "== 1/6 Parando servidor com segurança =="
"$ROOT_DIR/scripts/stop.sh" || true

log "== 2/6 Backup pré-atualização =="
if [ -d "$BEDROCK_DIR/worlds/$(level_name)" ]; then
  "$ROOT_DIR/scripts/backup.sh" || warn "backup falhou — seguindo mesmo assim (arriscado!)."
else
  log "Ainda não há mundo gerado — pulando backup."
fi

log "== 3/6 Descobrindo versão estável atual (fonte oficial) =="
URL="$(bedrock_download_url)"
[ -n "$URL" ] || die "não consegui descobrir a URL oficial. Tente mais tarde."
VER="$(version_from_url "$URL")"
CUR="$(installed_version)"
log "Instalada: $CUR | Disponível: ${VER:-?}"
if [ -n "$VER" ] && [ "$VER" = "$CUR" ] && [ -x "$BEDROCK_DIR/bedrock_server" ]; then
  ok "Já está na versão estável mais recente ($CUR). Nada a fazer."
  [ "$NO_START" -eq 0 ] && [ "$WAS_RUNNING" -eq 1 ] && "$ROOT_DIR/scripts/start.sh" --background
  exit 0
fi

log "== 4/6 Baixando Bedrock $VER da Microsoft/Minecraft =="
TMP_ZIP="$(mktemp -u /tmp/bedrock-server-XXXXXX.zip)"
curl -fSL --retry 3 --max-time 600 \
  -A "Mozilla/4.0 (compatible; MSIE 6.0; Windows NT 5.1)" \
  -o "$TMP_ZIP" "$URL" || die "falha no download."

log "== 5/6 Atualizando binários (preservando SEUS dados) =="
PRESERVE_DIR="$(mktemp -d /tmp/bds-preserve-XXXXXX)"
# Tudo que é SEU fica de fora da atualização:
for item in worlds behavior_packs resource_packs server.properties allowlist.json permissions.json; do
  [ -e "$BEDROCK_DIR/$item" ] && cp -a "$BEDROCK_DIR/$item" "$PRESERVE_DIR/$item"
done
unzip -oq "$TMP_ZIP" -d "$BEDROCK_DIR" || die "falha ao extrair."
rm -f "$TMP_ZIP"
for item in worlds behavior_packs resource_packs server.properties allowlist.json permissions.json; do
  if [ -e "$PRESERVE_DIR/$item" ]; then
    rm -rf "$BEDROCK_DIR/$item"
    cp -a "$PRESERVE_DIR/$item" "$BEDROCK_DIR/$item"
  fi
done
rm -rf "$PRESERVE_DIR"
chmod +x "$BEDROCK_DIR/bedrock_server"
[ -n "$VER" ] && echo "$VER" > "$BEDROCK_DIR/VERSION"
ok "Binários atualizados: $CUR → ${VER:-?} (mundo/addons/configs intactos)"

log "== 6/6 Reiniciando =="
if [ "$NO_START" -eq 0 ] && [ "$WAS_RUNNING" -eq 1 ]; then
  "$ROOT_DIR/scripts/start.sh" --background
else
  log "Servidor estava parado — NÃO iniciei sozinho. Para iniciar: ./scripts/start.sh"
fi
ok "Update concluído!"
