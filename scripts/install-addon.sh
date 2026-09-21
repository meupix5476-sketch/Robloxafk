#!/usr/bin/env bash
#===============================================================================
# install-addon.sh — instala addons (.mcpack / .mcaddon / .zip / .mcworld / pasta)
# Exemplos:
#   ./scripts/install-addon.sh ~/zombie-apocalypse.mcaddon
#   ./scripts/install-addon.sh ~/minha-arma.mcpack --level Survival
#   ./scripts/install-addon.sh ~/mapa-pronto.mcworld --set-level
# O que ele faz:
#   * detecta Behavior vs Resource pelo manifest.json (module_type)
#   * copia para behavior_packs/ e resource_packs/
#   * registra UUID+versão REAIS do manifest em world_*_packs.json (nunca inventa)
#   * acusa conflitos (mesmo pack em versões diferentes, dependência faltando)
#===============================================================================
set -u
source "$(dirname "$0")/common.sh"
require_cmd python3

FILE=""; LEVEL=""; SET_LEVEL=0; FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --level)     LEVEL="${2:-}"; shift 2 ;;
    --set-level) SET_LEVEL=1; shift ;;
    --force)     FORCE=1; shift ;;
    -h|--help)   sed -n '2,16p' "$0"; exit 0 ;;
    *)           FILE="$1"; shift ;;
  esac
done

[ -n "$FILE" ] || die "uso: $0 <arquivo.mcpack|.mcaddon|.zip|.mcworld|pasta> [--level NOME] [--set-level] [--force]"
[ -e "$FILE" ] || die "arquivo não encontrado: $FILE"
[ -z "$LEVEL" ] && LEVEL="$(level_name)"

export ROOT_DIR BEDROCK_DIR
export ADDON_SRC="$FILE" ADDON_LEVEL="$LEVEL"
export ADDON_SET_LEVEL="$SET_LEVEL" ADDON_FORCE="$FORCE"

python3 - <<'PYEOF'
import json, os, re, shutil, sys, tempfile, zipfile
from pathlib import Path

ROOT    = Path(os.environ["ROOT_DIR"])
BEDROCK = Path(os.environ["BEDROCK_DIR"])
SRC     = Path(os.environ["ADDON_SRC"])
LEVEL   = os.environ["ADDON_LEVEL"]
SET_LVL = os.environ["ADDON_SET_LEVEL"] == "1"
FORCE   = os.environ["ADDON_FORCE"] == "1"

BP_DIR, RP_DIR = BEDROCK/"behavior_packs", BEDROCK/"resource_packs"
WORLD_DIR = BEDROCK/"worlds"/LEVEL
BP_JSON, RP_JSON = WORLD_DIR/"world_behavior_packs.json", WORLD_DIR/"world_resource_packs.json"

BP_TYPES = {"data", "script"}
RP_TYPES = {"resources", "skin_pack"}

def log(m):  print(f"[addon] {m}")
def warn(m): print(f"[addon] AVISO: {m}")
def err(m):  print(f"[addon] ERRO: {m}")

def norm_version(v):
    """'1.0.0' ou [1,0,0] -> [1,0,0]. Retorna None se inválido."""
    if isinstance(v, (list, tuple)):
        parts = list(v)
    elif isinstance(v, str):
        parts = re.split(r"[.,]", v.strip())
    else:
        return None
    try:
        nums = [int(str(x).strip()) for x in parts[:3]]
    except ValueError:
        return None
    while len(nums) < 3:
        nums.append(0)
    return nums[:3]

def load_manifest(p: Path):
    try:
        with open(p, encoding="utf-8-sig") as f:
            return json.load(f)
    except Exception as e:
        warn(f"manifest ilegível em {p}: {e}")
        return None

def classify(manifest):
    """Retorna 'bp', 'rp' ou None (desconhecido)."""
    types = set()
    for m in manifest.get("modules", []) or []:
        t = str(m.get("type", "")).strip().lower()
        if t: types.add(t)
    # Módulos de script Bedrock (server scripts) moram no behavior pack
    if types & BP_TYPES or "javascript" in types or "script" in str(types):
        return "bp"
    if types & RP_TYPES:
        return "rp"
    return None

def find_pack_roots(tree: Path):
    """Acha pastas contendo manifest.json (1 nível de zips aninhados incluso)."""
    # desempacota .mcpack/.mcaddon/.zip aninhados (comum dentro de .mcaddon)
    nested_packs = sorted(tree.rglob("*.mcpack")) + sorted(tree.rglob("*.mcaddon")) + sorted(tree.rglob("*.zip"))
    for nested in nested_packs:
        try:
            dest = nested.parent / (nested.stem + "__nested")
            if dest.exists(): continue
            with zipfile.ZipFile(nested) as z:
                z.extractall(dest)
            log(f"sub-pacote expandido: {nested.name}")
        except Exception as e:
            warn(f"não consegui expandir {nested.name}: {e}")
    roots = []
    for man in sorted(tree.rglob("manifest.json")):
        if "__MACOSX" in man.parts: continue
        roots.append(man.parent)
    return roots

def read_world_packs(path: Path):
    if not path.exists(): return []
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
        return data if isinstance(data, list) else []
    except Exception:
        warn(f"{path.name} corrompido — será recriado do zero.")
        return []

def save_world_packs(path: Path, entries):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(entries, indent=2) + "\n", encoding="utf-8")

def sanitize(name, fallback):
    s = re.sub(r"[^A-Za-z0-9._-]+", "_", (name or "").strip()).strip("._")[:60]
    return s or fallback

# ---------------------------------------------------------------- mundo ----
def is_world_payload(tree: Path) -> bool:
    names = {p.name for p in tree.iterdir()} if tree.is_dir() else set()
    return ("level.dat" in names) or ("levelname.txt" in names) or ("db" in names and "level.dat" in names)

def install_world(tree: Path):
    top = tree
    # .mcworld às vezes embrulha tudo numa subpasta
    if not is_world_payload(top):
        for sub in tree.iterdir():
            if sub.is_dir() and is_world_payload(sub):
                top = sub; break
    if not is_world_payload(top):
        err("isto não parece um .mcworld válido (sem level.dat/levelname.txt).")
        return False
    lvl_file = top/"levelname.txt"
    wname = lvl_file.read_text(encoding="utf-8-sig", errors="replace").strip() if lvl_file.exists() else ""
    wname = sanitize(wname, SRC.stem)
    dest = BEDROCK/"worlds"/wname
    if dest.exists() and not FORCE:
        err(f"mundo '{wname}' já existe. Use --force para substituir ou apague bedrock-server/worlds/{wname}.")
        return False
    if dest.exists(): shutil.rmtree(dest)
    shutil.copytree(top, dest)
    log(f"Mundo instalado em bedrock-server/worlds/{wname}/")
    # relata packs embutidos no mundo
    for kind, p in (("behavior", dest/"world_behavior_packs.json"), ("resource", dest/"world_resource_packs.json")):
        if p.exists():
            try: n = len(json.loads(p.read_text(encoding="utf-8-sig")))
            except Exception: n = "?"
            log(f"  mundo já traz {n} {kind} pack(s) registrado(s) — mantidos como estão.")
    for sub in ("behavior_packs", "resource_packs"):
        if (dest/sub).exists():
            n = len([d for d in (dest/sub).iterdir() if d.is_dir()])
            log(f"  pasta {sub}/ embutida no mundo com {n} pack(s).")
    if SET_LVL:
        props = BEDROCK/"server.properties"
        lines = props.read_text(encoding="utf-8").splitlines() if props.exists() else []
        lines = [l for l in lines if not l.startswith("level-name=")]
        lines.append(f"level-name={wname}")
        props.write_text("\n".join(lines) + "\n", encoding="utf-8")
        log(f"server.properties agora usa level-name={wname}")
    else:
        log(f"Para JOGAR neste mundo: ./scripts/install-addon.sh ... --set-level  (ou edite level-name= no server.properties)")
    return True

# ---------------------------------------------------------------- packs ----
def install_packs(tree: Path):
    global WORLD_DIR, BP_JSON, RP_JSON
    roots = find_pack_roots(tree)
    if not roots:
        err("nenhum manifest.json encontrado. O arquivo é um addon Bedrock válido?")
        return False

    bp_entries, rp_entries = read_world_packs(BP_JSON), read_world_packs(RP_JSON)
    bp_by_id = {e.get("pack_id"): e for e in bp_entries if e.get("pack_id")}
    rp_by_id = {e.get("pack_id"): e for e in rp_entries if e.get("pack_id")}
    known_ids = set(bp_by_id) | set(rp_by_id)
    conflicts, missing_deps, installed, dep_checks = [], [], [], []

    for proot in roots:
        man = load_manifest(proot/"manifest.json")
        if not man: continue
        header = man.get("header", {}) or {}
        pack_id = str(header.get("uuid", "")).strip()
        ver = norm_version(header.get("version"))
        pname = header.get("name", proot.name)
        if not pack_id or ver is None:
            err(f"'{proot.name}': manifest sem uuid/versão válidos — pack ignorado (não invento UUID).")
            continue
        kind = classify(man)
        if kind is None:
            warn(f"'{pname}': tipo de módulo desconhecido — pulando. (Esperado: data/script p/ BP, resources p/ RP.)")
            continue
        target_base = BP_DIR if kind == "bp" else RP_DIR
        folder = sanitize(proot.name, pack_id[:8])
        dest = target_base/folder
        if dest.exists():
            if not FORCE:
                # mesmo pack já instalado? compara uuid do destino
                dman = load_manifest(dest/"manifest.json")
                did = str((dman or {}).get("header", {}).get("uuid", "")).strip() if dman else ""
                if did == pack_id:
                    warn(f"'{pname}': já instalado em {target_base.name}/{folder} — pulando (use --force p/ reinstalar).")
                else:
                    conflicts.append(f"PASTA OCUPADA: {target_base.name}/{folder} pertence a outro pack (UUID {did or '?'}), e '{pname}' ({pack_id}) quer o mesmo nome.")
                # ainda registra/checa abaixo
            else:
                shutil.rmtree(dest)
        if not dest.exists():
            shutil.copytree(proot, dest)
            log(f"instalado: {target_base.name}/{folder}  ← {pname} {'.'.join(map(str,ver))}")

        # registra no mundo (world_*_packs.json)
        reg = bp_by_id if kind == "bp" else rp_by_id
        if pack_id in reg:
            old = reg[pack_id].get("version")
            if list(old) != list(ver):
                conflicts.append(
                    f"VERSÃO DUPLICADA ({'BP' if kind=='bp' else 'RP'}): '{pname}' registra {pack_id} v{'.'.join(map(str,ver))}, "
                    f"mas o mundo já usa v{'.'.join(map(str,old))}. Addons diferentes pedindo o mesmo pack!")
            else:
                log(f"já registrado no mundo: {pname} v{'.'.join(map(str,ver))}")
        else:
            reg[pack_id] = {"pack_id": pack_id, "version": ver}
            known_ids.add(pack_id)
            log(f"registrado no mundo '{LEVEL}': {pname} v{'.'.join(map(str,ver))}")
        installed.append((kind, pack_id, pname, ver))
        # checagem de dependências em 2ª passagem (packs do MESMO .mcaddon
        # ainda não foram todos registrados aqui — evita falso positivo)
        dep_checks.append((pname, man.get("dependencies", []) or []))

    WORLD_DIR.mkdir(parents=True, exist_ok=True)
    save_world_packs(BP_JSON, list(bp_by_id.values()))
    save_world_packs(RP_JSON, list(rp_by_id.values()))
    for pname, deps in dep_checks:
        for dep in deps:
            if not isinstance(dep, dict): continue
            duid = str(dep.get("uuid", "")).strip()
            if duid and duid not in known_ids:
                missing_deps.append(f"'{pname}' precisa do pack {duid} (v{dep.get('version', '?')}) — não instalado/registrado.")
    log(f"world_behavior_packs.json: {len(bp_by_id)} pack(s) | world_resource_packs.json: {len(rp_by_id)} pack(s)")

    print()
    if conflicts:
        print("=========== CONFLITOS ENCONTRADOS ===========")
        for c in conflicts: print("  [!]", c)
        print("Resolva antes de jogar: normalmente é 1 addon pedindo versão diferente do mesmo pack.")
        print("=============================================")
    else:
        log("nenhum conflito de UUID/versão entre os packs. ✔")
    if missing_deps:
        print("=========== DEPENDÊNCIAS FALTANDO ===========")
        for d in sorted(set(missing_deps)): print("  [?]", d)
        print("Instale os packs acima (geralmente vêm junto no .mcaddon original).")
        print("=============================================")
    if not installed:
        err("nada foi instalado.")
        return False
    log(f"{len(installed)} pack(s) processado(s). Reinicie o servidor: ./scripts/stop.sh && ./scripts/start.sh")
    return not conflicts

# ------------------------------------------------------------------ main ---
def main():
    BP_DIR.mkdir(parents=True, exist_ok=True)
    RP_DIR.mkdir(parents=True, exist_ok=True)
    suffix = SRC.suffix.lower()
    if SRC.is_dir():
        log(f"instalando a partir da pasta {SRC} ...")
        if is_world_payload(SRC):
            sys.exit(0 if install_world(SRC) else 1)
        sys.exit(0 if install_packs(SRC) else 1)
    if suffix not in (".mcpack", ".mcaddon", ".zip", ".mcworld"):
        err(f"extensão '{suffix}' não suportada. Use .mcpack, .mcaddon, .zip ou .mcworld (ou uma pasta).")
        sys.exit(1)
    tmp = Path(tempfile.mkdtemp(prefix="addon-"))
    try:
        log(f"extraindo {SRC.name} ...")
        with zipfile.ZipFile(SRC) as z:
            z.extractall(tmp)
        # normaliza: se tudo está dentro de 1 subpasta só, entra nela
        kids = [p for p in tmp.iterdir() if p.name != "__MACOSX"]
        if len(kids) == 1 and kids[0].is_dir() and not (kids[0]/"manifest.json").exists() and not is_world_payload(kids[0]):
            tmp = kids[0]
        if suffix == ".mcworld" or is_world_payload(tmp):
            ok = install_world(tmp)
        else:
            ok = install_packs(tmp)
        sys.exit(0 if ok else 1)
    except zipfile.BadZipFile:
        err("arquivo zip corrompido ou inválido.")
        sys.exit(1)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

main()
PYEOF
