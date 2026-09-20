#!/usr/bin/env bash
#===============================================================================
# status.sh — saúde do servidor: RAM, disco, CPU, mundo, túnel, erros recentes.
# Uso: ./scripts/status.sh
#===============================================================================
set -u
source "$(dirname "$0")/common.sh"

echo "================ BEDROCK STATUS ================"
echo "Versão instalada : $(installed_version)"
if server_running; then echo "Servidor       : ONLINE"; else echo "Servidor       : OFFLINE"; fi
WSIZE="$(du -sh "$BEDROCK_DIR/worlds/$(level_name)" 2>/dev/null | cut -f1)"
[ -z "$WSIZE" ] && WSIZE="(mundo ainda não gerado)"
echo "Mundo          : $(level_name) ($WSIZE)"
echo "Packs          : $(find "$BEDROCK_DIR/behavior_packs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l) BP / $(find "$BEDROCK_DIR/resource_packs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l) RP"
if [ -f "$TUNNEL_DIR/tunnel-info.txt" ]; then
  # shellcheck disable=SC1090
  source "$TUNNEL_DIR/tunnel-info.txt"
  echo "Túnel          : ${TUNNEL_HOST:-?}:${TUNNEL_PORT:-?}"
else
  echo "Túnel          : (não configurado — ./scripts/tunnel.sh setup)"
fi
echo ""
echo "---------------- RAM / DISCO -------------------"
free -h 2>/dev/null || echo "(sem 'free')"
df -h "$ROOT_DIR" | head -n3
echo ""
echo "---------------- PROCESSOS ---------------------"
ps -eo pid,pcpu,pmem,etime,comm,args 2>/dev/null | grep -E 'bedrock_server|playit|PID' | grep -v grep || echo "(bedrock_server e playit não encontrados no ps)"
echo ""
echo "---------------- ERROS RECENTES ----------------"
LOGDIR="$BEDROCK_DIR/logs"
if [ -d "$LOGDIR" ]; then
  ls -lat "$LOGDIR" 2>/dev/null | head -n5
  grep -hEi 'error|fail|crash|exception' "$LOGDIR"/* 2>/dev/null | tail -n15 || echo "(sem erros nos logs)"
else
  echo "(pasta de logs ainda não existe — servidor nunca rodou?)"
fi
echo "================================================="
echo "Top interativo: htop (se instalado) ou top. Para addon guloso:"
echo "  1) veja %CPU/%MEM acima; 2) remova o pack suspeito de behavior_packs/"
echo "     + resource_packs/ e o registro em worlds/<mundo>/world_*_packs.json"
