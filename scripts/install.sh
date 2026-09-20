#!/usr/bin/env bash
#===============================================================================
# install.sh — prepara o ambiente e instala o Bedrock Dedicated Server oficial.
# Idempotente: NÃO apaga mundo, addons nem configs. Pode rodar de novo sem medo.
# Uso: ./scripts/install.sh [--force]   (--force rebaixa os binários)
#===============================================================================
set -u
source "$(dirname "$0")/common.sh"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

log "== Etapa 1/5: verificando arquitetura e SO =="
ARCH="$(uname -m)"
log "Arquitetura: $ARCH | SO: $(uname -srm)"
[ "$ARCH" = "x86_64" ] || die "Bedrock Dedicated Server (Linux) exige x86_64. Arquitetura atual: $ARCH"
[ -f /etc/os-release ] && grep -E '^PRETTY_NAME=' /etc/os-release || true

log "== Etapa 2/5: verificando RAM e disco =="
free -h 2>/dev/null || warn "'free' indisponível"
df -h "$ROOT_DIR" | head -n5
MEM_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
if [ "$MEM_MB" -gt 0 ] && [ "$MEM_MB" -lt 1500 ]; then
  warn "RAM total (${MEM_MB} MB) é pouca para BDS + addons pesados. Recomendado: 4 GB+ (Codespace maior)."
fi

log "== Etapa 3/5: instalando dependências =="
DEPS="curl unzip python3"
command -v tmux >/dev/null 2>&1 || DEPS="$DEPS tmux"
command -v jq   >/dev/null 2>&1 || DEPS="$DEPS jq"
MISSING=""
for c in $DEPS; do command -v "$c" >/dev/null 2>&1 || MISSING="$MISSING $c"; done
# tmux/jq podem ter nome de pacote igual ao comando; curl/unzip/python3 também.
PKGS=""
for c in $MISSING; do
  case "$c" in
    python3) PKGS="$PKGS python3" ;;
    *)       PKGS="$PKGS $c" ;;
  esac
done
if [ -n "$PKGS" ]; then
  if command -v apt-get >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
    log "Instalando:$PKGS"
    sudo apt-get update -qq && sudo apt-get install -y -qq $PKGS \
      || die "falha ao instalar dependências via apt."
  else
    die "faltam comandos:$MISSING — instale manualmente (sem sudo/apt neste ambiente)."
  fi
else
  log "Todas as dependências já estão instaladas."
fi

log "== Etapa 4/5: criando estrutura de pastas =="
mkdir -p "$BEDROCK_DIR/worlds" "$BEDROCK_DIR/behavior_packs" \
         "$BEDROCK_DIR/resource_packs" "$BACKUP_DIR" "$TUNNEL_DIR"

# Garante que os templates de config existam (sem sobrescrever os seus)
[ -f "$PROPS_FILE" ]            || die "server.properties sumiu do repositório! Restaure com git."
[ -f "$BEDROCK_DIR/permissions.json" ] || echo "[]" > "$BEDROCK_DIR/permissions.json"
[ -f "$BEDROCK_DIR/allowlist.json" ]   || echo "[]" > "$BEDROCK_DIR/allowlist.json"

log "== Etapa 5/5: Bedrock Dedicated Server (fonte oficial) =="
if [ -x "$BEDROCK_DIR/bedrock_server" ] && [ "$FORCE" -eq 0 ]; then
  ok "bedrock_server já instalado (versão $(installed_version)). Nada a baixar."
  log "Para rebaixar/atualizar: ./scripts/update.sh"
  exit 0
fi

URL="$(bedrock_download_url)"
[ -n "$URL" ] || die "não consegui descobrir a URL oficial. Veja https://www.minecraft.net/en-us/download/server/bedrock/ e tente de novo."
VER="$(version_from_url "$URL")"
log "Versão estável encontrada: ${VER:-?}"
log "URL oficial: $URL"

TMP_ZIP="$(mktemp -u /tmp/bedrock-server-XXXXXX.zip)"
log "Baixando..."
curl -fSL --retry 3 --max-time 600 \
  -A "Mozilla/4.0 (compatible; MSIE 6.0; Windows NT 5.1)" \
  -o "$TMP_ZIP" "$URL" || die "falha no download."

log "Extraindo para bedrock-server/ (preservando mundo/addons/configs)..."
# Preserva arquivos do usuário caso já existam
PRESERVE_DIR="$(mktemp -d /tmp/bds-preserve-XXXXXX)"
for f in server.properties allowlist.json permissions.json; do
  [ -f "$BEDROCK_DIR/$f" ] && cp -a "$BEDROCK_DIR/$f" "$PRESERVE_DIR/$f"
done
unzip -oq "$TMP_ZIP" -d "$BEDROCK_DIR" || die "falha ao extrair o zip."
rm -f "$TMP_ZIP"
for f in server.properties allowlist.json permissions.json; do
  [ -f "$PRESERVE_DIR/$f" ] && cp -a "$PRESERVE_DIR/$f" "$BEDROCK_DIR/$f"
done
rm -rf "$PRESERVE_DIR"

[ -n "$VER" ] && echo "$VER" > "$BEDROCK_DIR/VERSION"
chmod +x "$ROOT_DIR"/scripts/*.sh
chmod +x "$BEDROCK_DIR/bedrock_server"

ok "Instalação concluída! Versão: $(installed_version)"
echo ""
log "Próximos passos:"
log "  1) Iniciar:   ./scripts/start.sh --background   (console: tmux attach -t $MC_SESSION)"
log "  2) Túnel p/ celular: ./scripts/tunnel.sh setup  (exige 1 login no playit.gg)"
log "  3) Addons:    ./scripts/install-addon.sh seu-addon.mcaddon"
