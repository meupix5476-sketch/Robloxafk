#!/usr/bin/env bash
#===============================================================================
# selftest.sh — bateria de testes automatizados (SEGURO: tudo roda numa cópia
# em /tmp, sem tocar no servidor/mundo real).
# Testa: sintaxe, addons (ok/conflito/dependência/mcworld), backup+poda,
# supervisor anti-crash, background+stop, tunnel set/status, URL oficial.
# Uso: ./scripts/selftest.sh
#===============================================================================
set -u
source "$(dirname "$0")/common.sh"
require_cmd python3

STAGE="$(mktemp -d /tmp/mc-selftest-XXXXXX)"
PASS=0; FAIL=0; SKIP=0

pass() { PASS=$((PASS+1)); echo "  ✅ PASS: $*"; }
fail() { FAIL=$((FAIL+1)); echo "  ❌ FAIL: $*"; }
skip() { SKIP=$((SKIP+1)); echo "  ⏭️  SKIP: $*"; }

cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

log "Montando palco de testes em $STAGE ..."
mkdir -p "$STAGE/bedrock-server/worlds" "$STAGE/bedrock-server/behavior_packs" \
         "$STAGE/bedrock-server/resource_packs" "$STAGE/backups" "$STAGE/tunnel"
cp -r "$ROOT_DIR/scripts" "$STAGE/scripts"
cp -r "$ROOT_DIR/ui" "$STAGE/ui" 2>/dev/null || mkdir -p "$STAGE/ui"
cp "$PROPS_FILE" "$BEDROCK_DIR/permissions.json" "$BEDROCK_DIR/allowlist.json" \
   "$STAGE/bedrock-server/" 2>/dev/null || die "templates de config sumiram?"
S="$STAGE/scripts"  # atalho

echo ""
echo "### 1. Sintaxe bash ###"
SYNTAX_OK=1
for f in "$ROOT_DIR"/scripts/*.sh; do
  bash -n "$f" || { SYNTAX_OK=0; fail "bash -n em $(basename "$f")"; }
done
[ "$SYNTAX_OK" -eq 1 ] && pass "bash -n em todos os scripts"

echo ""
echo "### 2. Addon .mcaddon (BP+RP) ###"
mkdir -p "$STAGE/pk/ZombieBP/scripts" "$STAGE/pk/ZombieRP"
cat > "$STAGE/pk/ZombieBP/manifest.json" <<'EOF'
{"format_version": 2,
 "header": {"name": "T BP", "uuid": "11111111-2222-3333-4444-555555555555",
            "version": [1, 0, 0], "min_engine_version": [1, 21, 0]},
 "modules": [{"type": "data", "uuid": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "version": [1, 0, 0]}],
 "dependencies": [{"uuid": "99999999-8888-7777-6666-555555555555", "version": [2, 1, 0]}]}
EOF
cat > "$STAGE/pk/ZombieRP/manifest.json" <<'EOF'
{"format_version": 2,
 "header": {"name": "T RP", "uuid": "99999999-8888-7777-6666-555555555555",
            "version": "2.1.0", "min_engine_version": [1, 21, 0]},
 "modules": [{"type": "resources", "uuid": "bbbbbbbb-cccc-dddd-eeee-ffffffffffff", "version": [2, 1, 0]}]}
EOF
echo hi > "$STAGE/pk/ZombieBP/scripts/main.js"
(cd "$STAGE/pk" && zip -qr "$STAGE/t.mcaddon" ZombieBP ZombieRP)
if "$S/install-addon.sh" "$STAGE/t.mcaddon" >"$STAGE/o1.log" 2>&1; then
  BPJSON="$STAGE/bedrock-server/worlds/Survival/world_behavior_packs.json"
  if grep -q "11111111-2222-3333-4444-555555555555" "$BPJSON" 2>/dev/null \
     && grep -q "nenhum conflito" "$STAGE/o1.log"; then
    pass "instalação BP+RP + registro UUID real"
  else
    fail "registro em world_*_packs.json incorreto"; cat "$STAGE/o1.log"
  fi
else
  fail "install-addon de .mcaddon válido saiu com erro"; cat "$STAGE/o1.log"
fi

echo ""
echo "### 3. Conflito de versão + dependência faltando ###"
mkdir -p "$STAGE/pk2/RemixBP"
cat > "$STAGE/pk2/RemixBP/manifest.json" <<'EOF'
{"format_version": 2,
 "header": {"name": "T REMIX", "uuid": "11111111-2222-3333-4444-555555555555",
            "version": [2, 0, 0], "min_engine_version": [1, 21, 0]},
 "modules": [{"type": "data", "uuid": "cccccccc-dddd-eeee-ffff-000000000000", "version": [2, 0, 0]}],
 "dependencies": [{"uuid": "00000000-0000-0000-0000-000000000000", "version": [9, 9, 9]}]}
EOF
(cd "$STAGE/pk2" && zip -qr "$STAGE/remix.mcpack" RemixBP)
if "$S/install-addon.sh" "$STAGE/remix.mcpack" >"$STAGE/o2.log" 2>&1; then
  fail "conflito deveria sair com código 1"
else
  grep -q "CONFLITOS ENCONTRADOS" "$STAGE/o2.log" && grep -q "00000000-0000-0000-0000-000000000000" "$STAGE/o2.log" \
    && pass "conflito + dependência faltando detectados" \
    || { fail "relatório de conflito incompleto"; cat "$STAGE/o2.log"; }
fi

echo ""
echo "### 4. Mundo .mcworld ###"
mkdir -p "$STAGE/w1/db"
echo "Mapa T" > "$STAGE/w1/levelname.txt"; echo fake > "$STAGE/w1/level.dat"
(cd "$STAGE" && rm -rf mcw && mkdir mcw && cp -r w1 mcw/ && cd mcw && zip -qr "$STAGE/m.mcworld" w1)
if "$S/install-addon.sh" "$STAGE/m.mcworld" >"$STAGE/o3.log" 2>&1 \
   && [ -f "$STAGE/bedrock-server/worlds/Mapa_T/level.dat" ]; then
  pass ".mcworld instalado"
else
  fail ".mcworld não instalado"; cat "$STAGE/o3.log"
fi

echo ""
echo "### 5. Backup + poda ###"
if "$S/backup.sh" >"$STAGE/o4.log" 2>&1 && ls "$STAGE"/backups/world-*.tar.gz >/dev/null 2>&1; then
  pass "backup gerado"
  for i in 1 2 3 4 5 6 7; do touch "$STAGE/backups/world-2020-01-01-000$i.tar.gz"; done
  "$S/backup.sh" --keep 3 >/dev/null 2>&1
  N="$(ls "$STAGE"/backups/world-*.tar.gz | wc -l)"
  [ "$N" -eq 3 ] && pass "poda mantém 3 (--keep 3)" || fail "poda deixou $N arquivos (esperado 3)"
else
  fail "backup.sh falhou"; cat "$STAGE/o4.log"
fi

echo ""
echo "### 6. Supervisor: 2 crash + stop normal ###"
cat > "$STAGE/bedrock-server/bedrock_server" <<'EOF'
#!/usr/bin/env bash
N=$(cat "$STAGE_COUNT" 2>/dev/null || echo 0); N=$((N+1)); echo $N > "$STAGE_COUNT"
[ "$N" -lt 3 ] && exit 1
exit 0
EOF
chmod +x "$STAGE/bedrock-server/bedrock_server"
export STAGE_COUNT="$STAGE/count"
rm -f "$STAGE_COUNT"
if MAX_CRASHES=5 BASE_DELAY=1 "$S/start.sh" --foreground >"$STAGE/o5.log" 2>&1; then
  [ "$(cat "$STAGE_COUNT")" = "3" ] && pass "reiniciou após crash e parou limpo" \
    || fail "nº de boots inesperado: $(cat "$STAGE_COUNT")"
else
  fail "supervisor deveria terminar com 0"; cat "$STAGE/o5.log"
fi

echo ""
echo "### 7. Supervisor: desiste após N falhas ###"
printf '#!/usr/bin/env bash\nexit 137\n' > "$STAGE/bedrock-server/bedrock_server"
chmod +x "$STAGE/bedrock-server/bedrock_server"
if MAX_CRASHES=2 BASE_DELAY=1 "$S/start.sh" --foreground >"$STAGE/o6.log" 2>&1; then
  fail "crash infinito deveria sair com 1"
else
  grep -q "NÃO vou reiniciar em loop" "$STAGE/o6.log" \
    && pass "desistiu após 2 falhas, sem loop" \
    || { fail "mensagem de desistência ausente"; cat "$STAGE/o6.log"; }
fi

echo ""
echo "### 8. Background + stop ###"
if server_running; then
  skip "servidor REAL rodando — teste de background pulado por segurança"
else
  cat > "$STAGE/bedrock-server/bedrock_server" <<'EOF'
#!/usr/bin/env bash
echo "STUB up"
if [ -t 0 ]; then
  while read -r line; do [ "$line" = "stop" ] && exit 0; done
else
  sleep 120
fi
EOF
  chmod +x "$STAGE/bedrock-server/bedrock_server"
  BG_MINE=0
  if "$S/start.sh" --background >"$STAGE/o7.log" 2>&1; then
    BG_MINE=1
    sleep 2
    STAGE_PID="$(cat "$STAGE/bedrock-server/bedrock-server.pid" 2>/dev/null || echo)"
    if [ -n "$STAGE_PID" ] && kill -0 "$STAGE_PID" 2>/dev/null; then
      pass "background subiu (PID $STAGE_PID)"
    elif have_tmux && tmux has-session -t "$MC_SESSION" 2>/dev/null; then
      pass "background subiu (tmux)"
    else
      fail "background não subiu"; cat "$STAGE/o7.log" "$STAGE/bedrock-server/server.log" 2>/dev/null
    fi
    # 8b. cmd com servidor ONLINE (com tmux envia; sem tmux falha com graça)
    if have_tmux && tmux has-session -t "$MC_SESSION" 2>/dev/null; then
      "$S/cmd.sh" "say selftest" >"$STAGE/o7b.log" 2>&1 \
        && pass "cmd.sh enviou comando (tmux)" \
        || { fail "cmd.sh falhou com tmux"; cat "$STAGE/o7b.log"; }
    else
      if "$S/cmd.sh" "say selftest" >"$STAGE/o7b.log" 2>&1; then
        fail "cmd.sh deveria falhar sem tmux"
      else
        grep -q "sem console" "$STAGE/o7b.log" && pass "cmd.sh falhou com graça (sem tmux)" \
          || { fail "cmd.sh sem tmux: msg inesperada"; cat "$STAGE/o7b.log"; }
      fi
    fi
    if "$S/stop.sh" >"$STAGE/o8.log" 2>&1; then
      sleep 1
      if [ -n "${STAGE_PID:-}" ] && kill -0 "$STAGE_PID" 2>/dev/null; then
        fail "stop não matou o stub"; kill -9 "$STAGE_PID" 2>/dev/null
      else
        pass "stop encerrou o stub"
      fi
    else
      fail "stop.sh saiu com erro"; cat "$STAGE/o8.log"
    fi
  else
    fail "start --background falhou"; cat "$STAGE/o7.log"
  fi
  # faxina garantida (só mexe no que NÓS criamos)
  [ "${BG_MINE:-0}" -eq 1 ] && tmux kill-session -t "$MC_SESSION" 2>/dev/null || true
  [ -n "${STAGE_PID:-}" ] && kill -9 "$STAGE_PID" 2>/dev/null || true
fi

echo ""
echo "### 9. Tunnel set/status ###"
if "$S/tunnel.sh" set selftest-abc.at.ply.gg 11111 >"$STAGE/o9.log" 2>&1 \
   && grep -q "selftest-abc" "$STAGE/tunnel/tunnel-info.txt" 2>/dev/null \
   && "$S/tunnel.sh" status >>"$STAGE/o9.log" 2>&1; then
  pass "tunnel set/status"
else
  fail "tunnel set/status"; cat "$STAGE/o9.log"
fi

echo ""
echo "### 10. cmd com servidor OFFLINE ###"
if server_running; then
  skip "servidor REAL rodando — teste de cmd offline pulado"
elif "$S/cmd.sh" "say oi" >"$STAGE/o10.log" 2>&1; then
  fail "cmd.sh deveria falhar com servidor offline"
else
  grep -q "OFFLINE" "$STAGE/o10.log" && pass "cmd.sh recusou com graça (offline)" \
    || { fail "cmd.sh offline: msg inesperada"; cat "$STAGE/o10.log"; }
fi

echo ""
echo "### 11. Restore (ida e volta) ###"
LATEST="$(ls -1t "$STAGE"/backups/world-*.tar.gz 2>/dev/null | head -n1)"
if [ -z "${LATEST:-}" ]; then
  fail "sem backup no palco para restaurar"
else
  rm -rf "$STAGE/bedrock-server/worlds/Survival"
  if "$S/restore.sh" "$LATEST" --yes >"$STAGE/o11.log" 2>&1 \
     && [ -f "$STAGE/bedrock-server/worlds/Survival/world_behavior_packs.json" ]; then
    pass "restore reconstruiu o mundo"
  else
    fail "restore falhou"; cat "$STAGE/o11.log"
  fi
  "$S/restore.sh" --list >"$STAGE/o11b.log" 2>&1 && grep -q "world-" "$STAGE/o11b.log" \
    && pass "restore --list" || { fail "restore --list"; cat "$STAGE/o11b.log"; }
fi

echo ""
echo "### 12. URL oficial do Bedrock (rede) ###"
URL="$(bedrock_download_url)"
if [ -z "$URL" ]; then
  skip "sem internet p/ minecraft.net neste ambiente (no CI/Codespace valida de verdade)"
elif echo "$URL" | grep -q "bin-linux.*\.zip"; then
  pass "URL estável resolvida: $(echo "$URL" | grep -oE 'bedrock-server-[0-9.]+\.zip')"
else
  fail "URL inesperada: $URL"
fi

echo ""
echo "### 13. Painel web (UI) ###"
export UI_PORT=18081
if "$S/ui.sh" start >"$STAGE/o13.log" 2>&1; then
  sleep 1
  TOKEN="$(cat "$STAGE/ui/.token" 2>/dev/null || echo)"
  if [ -n "$TOKEN" ] && curl -fsS --max-time 10 "http://127.0.0.1:18081/api/status?token=$TOKEN" 2>/dev/null | grep -q '"online"'; then
    pass "UI responde /api/status"
  else
    fail "UI não respondeu"; cat "$STAGE/o13.log"
  fi
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:18081/api/status" 2>/dev/null || echo 000)"
  [ "$CODE" = "403" ] && pass "UI bloqueia sem token (403)" || fail "UI sem token retornou $CODE (esperado 403)"
else
  fail "ui.sh start falhou"; cat "$STAGE/o13.log"
fi
"$S/ui.sh" stop >/dev/null 2>&1 || true
unset UI_PORT

echo ""
echo "=========================================="
echo "SELFTEST: $PASS passou | $FAIL falhou | $SKIP pulou"
echo "=========================================="
[ "$FAIL" -eq 0 ]
