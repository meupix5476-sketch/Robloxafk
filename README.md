# ⛏️ Modded Crafters — Minecraft Bedrock Server (Codespaces)

Servidor **Minecraft Bedrock Dedicated Server** (Linux x86_64, versão estável oficial)
para ~5 jogadores, com suporte a addons pesados (Behavior + Resource Packs).

## 🚀 Iniciar / Parar

```bash
./scripts/install.sh          # 1ª vez (ou automático no Codespace novo)
./scripts/start.sh            # inicia em background
tmux attach -t mc-bedrock     # ver console ao vivo (sair: Ctrl+B, D)
./scripts/stop.sh             # para com segurança (salva o mundo)
./scripts/status.sh           # RAM, disco, CPU, túnel, erros
./scripts/selftest.sh         # bateria de testes (seguro, usa /tmp)
```

## 🌐 Entrar pelo celular (Bedrock → Servidores → Adicionar servidor)

O Codespaces **não encaminha UDP**, então usamos o túnel gratuito **playit.gg**:

```bash
./scripts/tunnel.sh setup     # 1ª vez: mostra 1 link p/ login no playit.gg
./scripts/tunnel.sh status    # ver endereço e porta
```

Depois de criar o túnel **Minecraft Bedrock → 127.0.0.1:19132** no site:

| Campo | Valor |
|---|---|
| **IP/ENDEREÇO** | ver `tunnel/tunnel-info.txt` (ex: `abc-123.at.ply.gg`) |
| **PORTA** | ver `tunnel/tunnel-info.txt` (ex: `54321`) |

Salve com: `./scripts/tunnel.sh set <HOST> <PORTA>`

## 📦 Addons (.mcpack / .mcaddon / .zip / .mcworld)

```bash
./scripts/install-addon.sh ~/meu-addon.mcaddon
./scripts/install-addon.sh ~/mapa.mcworld --set-level   # mundo pronto
./scripts/stop.sh && ./scripts/start.sh                 # reinicie após addons
```

O instalador lê o `manifest.json` real (UUID + versão), registra no mundo e
**avisa conflitos** (mesmo pack em versões diferentes, dependência faltando).

## 💾 Backup / 🔄 Update

```bash
./scripts/backup.sh           # backups/world-AAAA-MM-DD-HHMM.tar.gz (mantém 5)
./scripts/update.sh           # para → backup → atualiza estável → reinicia
```

## 💽 O que sobrevive ao stop/start do Codespace?

| Local | Stop/Start | Codespace deletado |
|---|---|---|
| Tudo em `/workspaces/Robloxafk` (mundo, addons, configs, `tunnel/playit.toml`) | ✅ sobrevive | ❌ perde |
| Arquivos com `git push` (scripts, `server.properties`) | ✅ | ✅ |
| Backups `.tar.gz` (baixe uma cópia!) | ✅ | ❌ perde |

> Mundo/addons/backups **não** vão pro git (grandes demais). Baixe os `.tar.gz`
> periodicamente. Nunca commite `tunnel/playit.toml` (secret!).

## ⚠️ Limitações do Codespaces (regras do jogo)

- **Sem UDP direto**: jogar exige o túnel playit.gg (configurado acima).
- **Suspensão automática** (padrão 30 min sem uso) desliga o servidor; considere
  aumentar o timeout nas configurações do Codespace. Não há como impedir isso —
  é política do GitHub.
- **Cota mensal de horas** (varia por plano e pode acabar): servidor 24/7 estoura
  grátis. Use sob demanda.
- **Trocar de máquina/tipo** (ex: 2 → 4 cores) exige rebuild: faça backup,
  `git push`, baixe o `.tar.gz`.
- **Performance**: addons pesados (zumbis, armas, veículos, scripts) pedem o
  Codespace de **4 cores / 8 GB** ou mais. Monitore com `./scripts/status.sh`.

## 📁 Estrutura

```
bedrock-server/  behavior_packs/  resource_packs/  worlds/  server.properties
backups/         scripts/ (install/start/stop/backup/update/install-addon/tunnel/status)
tunnel/          (agente playit + secret + endereço — fora do git)
```
