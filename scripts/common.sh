#===============================================================================
# common.sh — helpers compartilhados por todos os scripts deste repositório.
# Uso: source "$(dirname "$0")/common.sh"
#===============================================================================

# Diretório raiz do repositório (pai de scripts/)
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BEDROCK_DIR="$ROOT_DIR/bedrock-server"
BACKUP_DIR="$ROOT_DIR/backups"
TUNNEL_DIR="$ROOT_DIR/tunnel"
PROPS_FILE="$BEDROCK_DIR/server.properties"

MC_SESSION="mc-bedrock"     # nome da sessão tmux do servidor
PLAYIT_SESSION="playit"     # nome da sessão tmux do túnel playit
PID_FILE="$BEDROCK_DIR/bedrock-server.pid"

# --- log helpers -------------------------------------------------------------
log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
ok()   { printf '[%s] \033[32mOK\033[0m %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] \033[33mAVISO\033[0m %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die()  { printf '[%s] \033[31mERRO\033[0m %s\n' "$(date '+%H:%M:%S')" "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "comando '$1' não encontrado. Rode: ./scripts/install.sh"
}

have_tmux() { command -v tmux >/dev/null 2>&1; }

tmux_running() { # $1 = nome da sessão
  have_tmux && tmux has-session -t "$1" 2>/dev/null
}

# --- server.properties -------------------------------------------------------
# Lê uma chave do server.properties (retorna "" se ausente)
prop() { # $1 = chave
  [ -f "$PROPS_FILE" ] || { echo ""; return; }
  grep -E "^$1=" "$PROPS_FILE" | tail -n1 | cut -d= -f2-
}

level_name() {
  local lvl
  lvl="$(prop 'level-name')"
  [ -n "$lvl" ] && echo "$lvl" || echo "Survival"
}

server_port() {
  local p
  p="$(prop 'server-port')"
  [ -n "$p" ] && echo "$p" || echo "19132"
}

# --- Bedrock download oficial ------------------------------------------------
# Descobre a URL estável atual do Bedrock Dedicated Server (Linux x86_64)
# a partir da API oficial da Microsoft/Minecraft. Nunca Preview/Beta:
# o endpoint "download/links" só lista builds estáveis públicas.
bedrock_download_url() {
  local url=""
  # Fonte 1 (preferida): API oficial de downloads
  url="$(curl -fsSL --max-time 30 \
    -A "Mozilla/4.0 (compatible; MSIE 6.0; Windows NT 5.1)" \
    "https://net-secondary.web.minecraft-services.net/api/v1.0/download/links" 2>/dev/null \
    | python3 -c "
import json,sys
try:
    data = json.load(sys.stdin)
    for l in data.get('result', {}).get('links', []):
        if l.get('downloadType') == 'serverBedrockLinux':
            print(l.get('downloadUrl', ''))
            break
except Exception:
    pass
" 2>/dev/null)"
  # Fonte 2 (fallback): página oficial de download
  if [ -z "$url" ]; then
    url="$(curl -fsSL --max-time 30 \
      -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" \
      "https://www.minecraft.net/en-us/download/server/bedrock/" 2>/dev/null \
      | grep -o 'https://[^"]*bin-linux/[^"]*\.zip' | head -n1)"
  fi
  echo "$url"
}

# Extrai "1.21.x.y" de uma URL como .../bedrock-server-1.21.95.1.zip
version_from_url() { # $1 = url
  echo "$1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1
}

installed_version() {
  [ -f "$BEDROCK_DIR/VERSION" ] && cat "$BEDROCK_DIR/VERSION" || echo "desconhecida"
}

# --- servidor rodando? -------------------------------------------------------
server_running() {
  if tmux_running "$MC_SESSION"; then return 0; fi
  if [ -f "$PID_FILE" ]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null)"
    # ignora o próprio PID (filho supervisionado)
    if [ -n "$pid" ] && [ "$pid" != "$$" ] && kill -0 "$pid" 2>/dev/null; then return 0; fi
  fi
  pgrep -x "bedrock_server" >/dev/null 2>&1
}

# Envia um comando para o console do servidor (via tmux). Retorna 1 se indisponível.
server_cmd() { # $1 = comando (ex: "stop", "save hold")
  tmux_running "$MC_SESSION" || return 1
  tmux send-keys -t "$MC_SESSION" "$1" Enter
}
