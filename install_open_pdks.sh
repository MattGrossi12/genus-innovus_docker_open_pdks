#!/usr/bin/env bash
# Instalador Open PDKs: Rocky Linux 8.x, Docker Rootless, Ubuntu 24.04.
# Nenhuma operacao sudo; requer Docker Engine e componentes rootless no host.
# PDKs LambdaPDK: ASAP7, FreePDK45, ICsprout55, SKY130, GF180, IHP130, Interposer.
# PDKs Ciel: familias selecionadas que o Ciel instalado disponibilizar.
# Extras: ASAP7 QRC 1x/4x e ICsprout55 GDS I/O + decks PV.
# Uso: chmod +x install_open_pdks.sh && ./install_open_pdks.sh
# Opcoes: INSTALL_DIR, REBUILD=1, SKIP_DOWNLOAD=1, SKIP_CIEL=1,
#         SKIP_LAMBDA=1, SKIP_EXTRAS=1, RETRIES=2, BASE_IMAGE,
#         MIN_DOCKER_VERSION=20.10.0.
set -Eeuo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/eda-pdks-docker}"
CONTAINER_NAME="${CONTAINER_NAME:-eda-pdks}"
IMAGE_NAME="${IMAGE_NAME:-eda-pdks:ubuntu24.04}"
BASE_IMAGE="${BASE_IMAGE:-ubuntu:24.04}"
MIN_DOCKER_VERSION="${MIN_DOCKER_VERSION:-20.10.0}"
REBUILD="${REBUILD:-0}"
SKIP_DOWNLOAD="${SKIP_DOWNLOAD:-0}"
SKIP_CIEL="${SKIP_CIEL:-0}"
SKIP_LAMBDA="${SKIP_LAMBDA:-0}"
SKIP_EXTRAS="${SKIP_EXTRAS:-0}"
RETRIES="${RETRIES:-2}"
CIEL_VERSION="${CIEL_VERSION:-2.1.0}"
LAMBDA_VERSION="${LAMBDA_VERSION:-0.2.22}"
SC_VERSION="${SC_VERSION:-0.38.11}"
ICS_RELEASE="${ICS_RELEASE:-v1.10.102}"
RUN_ID="${RUN_ID:-$(date '+%Y-%m-%d_%H-%M-%S')}"
CONTAINER_UID="$(id -u)"
CONTAINER_GID="$(id -g)"

info() { printf '\n[OPEN-PDKS] %s\n' "$*"; }
fail() { printf '[ERRO] %s\n' "$*" >&2; exit 1; }
[[ $(id -u) -ne 0 ]] || fail 'Execute com seu usuario normal, sem sudo.'
[[ $RETRIES =~ ^[0-9]+$ ]] || fail 'RETRIES precisa ser inteiro >= 0.'
command -v docker >/dev/null || fail 'Docker CLI nao instalada. O administrador precisa instalar Docker Engine + rootless extras.'

# Acesso exclusivo ao daemon do usuario, sem tocar no Docker do sistema.
unset DOCKER_HOST DOCKER_CONTEXT
D=(docker --context rootless)
rootless_ok() {
  "${D[@]}" info --format '{{json .SecurityOptions}}' 2>/dev/null | grep -q rootless
}
if ! rootless_ok; then
  systemctl --user start docker.service >/dev/null 2>&1 || true
fi
if ! rootless_ok; then
  info 'Configurando Docker Rootless no usuario.'
  for cmd in dockerd-rootless-setuptool.sh dockerd-rootless.sh rootlesskit newuidmap newgidmap systemctl; do
    command -v "$cmd" >/dev/null || fail "Pre-requisito ausente: $cmd"
  done
  systemctl --user show-environment >/dev/null 2>&1 || fail 'systemd --user indisponivel.'
  dockerd-rootless-setuptool.sh --force check || fail 'Requisitos Rootless nao atendidos.'
  dockerd-rootless-setuptool.sh --force install || fail 'Falha no setup Rootless.'
  systemctl --user enable --now docker.service || fail 'Falha ao iniciar Rootless.'
fi
rootless_ok || fail 'Docker Rootless nao esta acessivel.'
DOCKER_SERVER_VERSION="$("${D[@]}" version --format '{{.Server.Version}}' 2>/dev/null || true)"
[[ -n "$DOCKER_SERVER_VERSION" ]] || fail 'Nao foi possivel consultar a versao do Docker Rootless.'
if [[ "$(printf '%s\n%s\n' "$MIN_DOCKER_VERSION" "$DOCKER_SERVER_VERSION" | sort -V | head -n 1)" != "$MIN_DOCKER_VERSION" ]]; then
  fail "Docker $DOCKER_SERVER_VERSION e antigo; minimo requerido: $MIN_DOCKER_VERSION."
fi
info "Docker Rootless $DOCKER_SERVER_VERSION validado."
info 'Docker Rootless funcionando.'

mkdir -p "$INSTALL_DIR"/{docker,pdks/ciel,home/.sc,home/.cache,workspace,logs}

cat > "$INSTALL_DIR/docker/Dockerfile" <<'DOCKERFILE'
ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}
ENV DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC HOME=/home/eda \
    PDK_ROOT=/pdks/ciel XDG_CACHE_HOME=/home/eda/.cache \
    VIRTUAL_ENV=/opt/eda-venv PATH=/opt/eda-venv/bin:$PATH PYTHONUNBUFFERED=1
ARG CIEL_VERSION=2.1.0
ARG LAMBDA_VERSION=0.2.22
ARG SC_VERSION=0.38.11
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget git git-lfs python3 python3-pip python3-venv \
      python3-dev build-essential make cmake ninja-build pkg-config \
      tar gzip bzip2 xz-utils zstd unzip zip file jq rsync procps tini \
    && python3 -m venv /opt/eda-venv \
    && /opt/eda-venv/bin/pip install --no-cache-dir --upgrade pip setuptools wheel \
    && /opt/eda-venv/bin/pip install --no-cache-dir \
         "ciel==${CIEL_VERSION}" "lambdapdk==${LAMBDA_VERSION}" "siliconcompiler==${SC_VERSION}" \
    && /opt/eda-venv/bin/pip check \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /pdks/ciel /home/eda/.sc/cache /home/eda/.cache /workspace /opt/eda-scripts
WORKDIR /workspace
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/bin/bash"]
DOCKERFILE

# Ciel: instalar revisao mais recente disponivel por familia permitida.
cat > "$INSTALL_DIR/docker/prefetch_ciel.sh" <<'CIEL'
#!/usr/bin/env bash
set -Eeuo pipefail
export PDK_ROOT="${PDK_ROOT:-/pdks/ciel}"
mkdir -p "$PDK_ROOT" /workspace/ciel_versions
report=/workspace/ciel_resultados.tsv
printf 'familia\tversao\tstatus\n' > "$report"
ciel ls-pdks > /workspace/ciel_familias.json
mapfile -t families < <(python3 - <<'PY'
import json
allowed={'sky130','gf180mcu','ihp-sg13','ihp-sg13g2','freepdk45'}
with open('/workspace/ciel_familias.json',encoding='utf-8') as f:
    data=json.load(f)
if isinstance(data,dict):
    data=data.get('families',data)
if isinstance(data,dict):
    names=list(data)
elif isinstance(data,list):
    names=[x if isinstance(x,str) else x.get('name',x.get('id','')) for x in data if isinstance(x,(dict,str))]
else:
    names=[]
for name in sorted(allowed.intersection(names)):
    print(name)
PY
)
(( ${#families[@]} )) || { echo '[ERRO] Nenhuma familia permitida na lista Ciel.' >&2; exit 1; }
errors=0
for family in "${families[@]}"; do
  echo "[CIEL] $family"
  listing="/workspace/ciel_versions/$family.json"
  if ! ciel ls-remote --pdk-family "$family" > "$listing"; then
    printf '%s\t-\tERRO_LISTAGEM\n' "$family" >> "$report"
    errors=$((errors+1)); continue
  fi
  revision="$(python3 - "$listing" <<'PY'
import json,re,sys
with open(sys.argv[1],encoding='utf-8') as f: data=json.load(f)
sha=re.compile(r'^[0-9a-fA-F]{40,64}$')
version=re.compile(r'^[vVrR]?[0-9]+(?:\.[0-9]+){1,3}(?:[-+][A-Za-z0-9._-]+)?$')
token=re.compile(r'^[A-Za-z0-9][A-Za-z0-9._/-]*$')
def candidate(value, broad=False):
    if not isinstance(value,str) or not value.strip(): return None
    value=value.strip()
    if sha.fullmatch(value) or version.fullmatch(value): return value
    return value if broad and token.fullmatch(value) else None
def find(o):
    if isinstance(o,str):return candidate(o)
    if isinstance(o,list):
        for x in o:
            v=find(x)
            if v:return v
    if isinstance(o,dict):
        for k in ('version','commit','hash','revision','tag'):
            if k in o:
                v=find(o[k])
                if v:return v
        for k in ('name','id'):
            if k in o:
                v=candidate(o[k], broad=True)
                if v:return v
        for k,v in o.items():
            if sha.fullmatch(k):return k
            found=find(v)
            if found:return found
    return None
print(find(data) or '')
PY
)"
  if [[ -z "$revision" ]]; then
    printf '%s\t-\tERRO_REVISAO\n' "$family" >> "$report"
    errors=$((errors+1)); continue
  fi
  if ciel enable --pdk-family "$family" --include-libraries all "$revision"; then
    printf '%s\t%s\tOK\n' "$family" "$revision" >> "$report"
  else
    printf '%s\t%s\tERRO_DOWNLOAD\n' "$family" "$revision" >> "$report"
    errors=$((errors+1))
  fi
done
echo "[CIEL] Resultado: $report; falhas=$errors"
((errors==0))
CIEL

# LambdaPDK: enumerar os modulos selecionados e resolver cada dataroot unico.
cat > "$INSTALL_DIR/docker/prefetch_lambda.py" <<'PY'
#!/usr/bin/env python3
import csv
from collections import defaultdict
from importlib.metadata import version
import os
from pathlib import Path
import sys
import time

SELECTED = ('asap7', 'freepdk45', 'icsprout55', 'sky130', 'gf180', 'ihp130', 'interposer')
RETRIES = int(os.environ.get('RETRIES', '2'))
OUT = Path('/workspace')
OUT.mkdir(parents=True, exist_ok=True)

def write_tsv(filename, header, rows):
    with (OUT / filename).open('w', encoding='utf-8', newline='') as stream:
        writer = csv.writer(stream, delimiter='\t')
        writer.writerow(header)
        writer.writerows(rows)

def module_family(obj):
    parts = obj.__class__.__module__.split('.')
    return parts[1] if len(parts) > 1 and parts[0] == 'lambdapdk' else None

def has_files(path):
    if path.is_file():
        return path.stat().st_size > 0
    if path.is_dir():
        return next(path.iterdir(), None) is not None
    return False

def run():
    from lambdapdk import get_pdks, get_libs
    print('[VERSOES]', *(f'{p}={version(p)}' for p in ('lambdapdk', 'siliconcompiler')), flush=True)
    kinds = {'pdk': list(get_pdks()), 'biblioteca': list(get_libs())}
    per_family = defaultdict(lambda: {'pdk': [], 'biblioteca': [], 'sources': set(), 'issues': []})
    roots = {}
    modules = []
    for kind, objects in kinds.items():
        for obj in objects:
            family = module_family(obj)
            if family not in SELECTED:
                continue
            name = str(obj.name)
            per_family[family][kind].append(name)
            try:
                aliases = obj.getkeys('dataroot')
                if not aliases:
                    raise RuntimeError('Sem dataroot declarado')
                for alias in aliases:
                    url = str(obj.get('dataroot', alias, 'path'))
                    tag = str(obj.get('dataroot', alias, 'tag'))
                    key = (url, tag)
                    item = roots.setdefault(key, {'object': obj, 'alias': alias, 'families': set(), 'names': set()})
                    item['families'].add(family)
                    item['names'].add(str(alias))
                    per_family[family]['sources'].add(key)
                modules.append((kind, family, name, 'REGISTRADO', ','.join(map(str, aliases))))
            except Exception as exc:
                per_family[family]['issues'].append(f'{name}: {exc}')
                modules.append((kind, family, name, 'ERRO', str(exc)))
    write_tsv('lambdapdk_modulos.tsv', ('tipo','familia','modulo','status','detalhe'), modules)
    results = {}
    rows = []
    for index, (key, item) in enumerate(sorted(roots.items()), start=1):
        families = ','.join(sorted(item['families']))
        aliases = ','.join(sorted(item['names']))
        print(f'[{index}/{len(roots)}] {families} : {aliases}', flush=True)
        status, detail = 'ERRO', ''
        for attempt in range(RETRIES + 1):
            try:
                path = Path(item['object'].get_dataroot(item['alias']))
                if not has_files(path):
                    raise RuntimeError(f'Fonte ausente ou vazia: {path}')
                status, detail = 'OK', str(path)
                break
            except Exception as exc:
                detail = f'{type(exc).__name__}: {exc}'
                print(f'    [TENTATIVA {attempt+1}] {detail}', flush=True)
                if attempt < RETRIES:
                    time.sleep(3)
        results[key] = (status, detail)
        rows.append((families, aliases, key[1], status, detail, key[0]))
        print(f'    [{status}] {detail}', flush=True)
    write_tsv('lambdapdk_fontes.tsv', ('familias','dataroots','tag','status','local_ou_erro','origem'), rows)
    family_rows = []
    errors = 0
    for family in SELECTED:
        item = per_family[family]
        missing = [key for key in item['sources'] if results.get(key, ('ERRO',))[0] != 'OK']
        issues = list(item['issues'])
        if not item['pdk']: issues.append('Sem configuracao PDK')
        if not item['biblioteca']: issues.append('Sem biblioteca')
        if not item['sources']: issues.append('Sem dataroot')
        if missing: issues.append(f'{len(missing)} fonte(s) ausente(s)')
        for key in item['sources']:
            state, location = results.get(key, ('ERRO', ''))
            if state == 'OK' and 'siliconcompiler/lambdapdk' in key[0]:
                if not has_files(Path(location) / 'lambdapdk' / family):
                    issues.append('Subpasta nao encontrada no pacote compartilhado')
        status = 'OK_FONTES' if not issues else 'INCOMPLETO'
        errors += status != 'OK_FONTES'
        print(f'[FAMILIA] {family:12} {status:11} PDKs={len(item["pdk"])} '
              f'libs={len(item["biblioteca"])} fontes={len(item["sources"])}', flush=True)
        family_rows.append((family,len(item['pdk']),len(item['biblioteca']),
                            len(item['sources']),len(missing),status,' | '.join(issues)))
    write_tsv('lambdapdk_familias.tsv',
              ('familia','configuracoes','bibliotecas','fontes','faltantes','status','observacoes'),
              family_rows)
    return int(errors != 0)

if __name__ == '__main__':
    sys.exit(run())
PY

# Complementos obtidos durante a qualificacao do fluxo fisico.
cat > "$INSTALL_DIR/docker/prefetch_extras.sh" <<'EXTRAS'
#!/usr/bin/env bash
set -Eeuo pipefail
ICS_RELEASE="${ICS_RELEASE:-v1.10.102}"
report=/workspace/pdks_extras.tsv
printf 'pdk\trecurso\tstatus\tcaminho\n' > "$report"
errors=0
record() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$report"; }

ASAP=/pdks/asap7sc7p5t_28
if [[ ! -e "$ASAP" ]]; then
  git clone --depth 1 --filter=blob:none --sparse \
    https://github.com/The-OpenROAD-Project/asap7sc7p5t_28.git "$ASAP" || true
fi
if [[ -d "$ASAP/.git" ]]; then
  (cd "$ASAP" && git sparse-checkout set qrc) || true
fi
for name in qrcTechFile_typ03_unscaledV02 qrcTechFile_typ03_scaled4xV06; do
  file="$ASAP/qrc/$name"
  if [[ -s "$file" ]]; then record asap7 "$name" OK "$file"
  else record asap7 "$name" AUSENTE "$file"; errors=$((errors+1)); fi
done

ICS=/pdks/icsprout55-upstream
if [[ ! -e "$ICS" ]]; then
  git clone --depth 1 https://github.com/openecos-projects/icsprout55-pdk.git "$ICS" || true
fi
for file in \
  "$ICS/pv/DRC/ICsprout_CalDRC_55LLULP1233_REV1_0_OS.ant" \
  "$ICS/pv/DRC/ICsprout_CalDRC_55LLULP1233_REV1_0_OS.drc" \
  "$ICS/pv/LVS/ICsprout_CalLVS_55LLULP1233_REV1_0_OS.lvs" \
  "$ICS/pv/LVS/subckt.sp"; do
  if [[ -s "$file" ]]; then record icsprout55 "$(basename "$file")" OK "$file"
  else record icsprout55 "$(basename "$file")" AUSENTE "$file"; errors=$((errors+1)); fi
done

GDS="$ICS/IP/IO/gds/ICSIOA_N55_3P3_1P6M1TM.gds"
if [[ -d "$ICS/.git" && ! -s "$GDS" ]]; then
  (cd "$ICS" && \
   make ICsprout_55LLULP1233_IO_251013_gds.tar.bz2 "RELEASE_TAG=$ICS_RELEASE" && \
   mkdir -p IP/IO && \
   tar -xjf ICsprout_55LLULP1233_IO_251013_gds.tar.bz2 -C IP/IO) || true
fi
if [[ -s "$GDS" ]]; then record icsprout55 io_gds OK "$GDS"
else record icsprout55 io_gds AUSENTE "$GDS"; errors=$((errors+1)); fi

echo "[EXTRAS] Resultado: $report; falhas=$errors"
((errors==0))
EXTRAS
chmod +x "$INSTALL_DIR/docker/"*.sh

# Comando de manutencao para o host.
cat > "$INSTALL_DIR/eda-pdk" <<'LAUNCHER'
#!/usr/bin/env bash
set -Eeuo pipefail
CONTAINER_NAME="${CONTAINER_NAME:-eda-pdks}"
unset DOCKER_HOST DOCKER_CONTEXT
D=(docker --context rootless)
"${D[@]}" info >/dev/null 2>&1 || systemctl --user start docker.service >/dev/null 2>&1 || true
"${D[@]}" info >/dev/null 2>&1 || { echo '[ERRO] Docker Rootless indisponivel' >&2; exit 1; }
"${D[@]}" container inspect "$CONTAINER_NAME" >/dev/null 2>&1 || { echo '[ERRO] Container inexistente' >&2; exit 1; }
if [[ "$("${D[@]}" inspect -f '{{.State.Running}}' "$CONTAINER_NAME")" != true ]]; then
  "${D[@]}" start "$CONTAINER_NAME" >/dev/null
fi
cmd="${1:-shell}"; if [[ $# -gt 0 ]]; then shift; fi
case "$cmd" in
  shell)
    if [[ -t 0 && -t 1 ]]; then exec "${D[@]}" exec -it "$CONTAINER_NAME" bash "$@"
    else exec "${D[@]}" exec -i "$CONTAINER_NAME" bash "$@"; fi ;;
  prefetch-ciel) exec "${D[@]}" exec "$CONTAINER_NAME" /opt/eda-scripts/prefetch_ciel.sh "$@" ;;
  prefetch-lambda) exec "${D[@]}" exec "$CONTAINER_NAME" python3 -u /opt/eda-scripts/prefetch_lambda.py "$@" ;;
  prefetch-extras) exec "${D[@]}" exec "$CONTAINER_NAME" /opt/eda-scripts/prefetch_extras.sh "$@" ;;
  status)
    "${D[@]}" info --format 'Rootless={{json .SecurityOptions}}'
    "${D[@]}" inspect -f 'Container={{.Name}} State={{.State.Status}} User={{.Config.User}}' "$CONTAINER_NAME"
    "${D[@]}" inspect -f '{{range .Mounts}}{{println .Source "=>" .Destination}}{{end}}' "$CONTAINER_NAME"
    ;;
  reports) exec "${D[@]}" exec "$CONTAINER_NAME" bash -lc 'find /workspace -maxdepth 1 -type f -name "*.tsv" -printf "%f\n" | sort' ;;
  ciel) exec "${D[@]}" exec "$CONTAINER_NAME" ciel "$@" ;;
  python) exec "${D[@]}" exec "$CONTAINER_NAME" python3 "$@" ;;
  *) exec "${D[@]}" exec "$CONTAINER_NAME" "$cmd" "$@" ;;
esac
LAUNCHER
chmod +x "$INSTALL_DIR/eda-pdk"

if [[ "$REBUILD" == 1 ]]; then
  info 'Removendo apenas o container para reconstruir a imagem; dados persistentes preservados.'
  "${D[@]}" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi
if [[ "$REBUILD" == 1 ]] || ! "${D[@]}" image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
  info 'Construindo imagem Ubuntu 24.04 e instalando ferramentas Python.'
  "${D[@]}" build --pull \
    --build-arg "BASE_IMAGE=$BASE_IMAGE" \
    --build-arg "CIEL_VERSION=$CIEL_VERSION" \
    --build-arg "LAMBDA_VERSION=$LAMBDA_VERSION" \
    --build-arg "SC_VERSION=$SC_VERSION" \
    -t "$IMAGE_NAME" "$INSTALL_DIR/docker"
else
  info 'Reutilizando imagem Docker existente; para atualizar use REBUILD=1.'
fi

if "${D[@]}" container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  existing_user="$("${D[@]}" inspect -f '{{.Config.User}}' "$CONTAINER_NAME")"
  existing_mounts="$("${D[@]}" inspect -f '{{range .Mounts}}{{println .Source "=>" .Destination}}{{end}}' "$CONTAINER_NAME")"
  expected_mounts="$INSTALL_DIR/pdks => /pdks
$INSTALL_DIR/home => /home/eda
$INSTALL_DIR/workspace => /workspace"
  if [[ "$existing_user" != "$CONTAINER_UID:$CONTAINER_GID" || "$existing_mounts" != "$expected_mounts" ]]; then
    info 'Container existente com usuario ou volumes diferentes; recriando somente o container.'
    "${D[@]}" rm -f "$CONTAINER_NAME" >/dev/null
  fi
fi
if ! "${D[@]}" container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  info 'Criando container Ubuntu com armazenamento persistente.'
  "${D[@]}" run -d --name "$CONTAINER_NAME" --restart unless-stopped \
    --hostname eda-pdks --user "$CONTAINER_UID:$CONTAINER_GID" \
    -e HOME=/home/eda -e PDK_ROOT=/pdks/ciel \
    -e RETRIES="$RETRIES" -e ICS_RELEASE="$ICS_RELEASE" \
    -v "$INSTALL_DIR/pdks:/pdks:z" \
    -v "$INSTALL_DIR/home:/home/eda:z" \
    -v "$INSTALL_DIR/workspace:/workspace:z" \
    "$IMAGE_NAME" sleep infinity >/dev/null
fi
if [[ "$("${D[@]}" inspect -f '{{.State.Running}}' "$CONTAINER_NAME")" != true ]]; then
  "${D[@]}" start "$CONTAINER_NAME" >/dev/null
fi

# Atualiza scripts internos inclusive em containers preexistentes.
"${D[@]}" exec "$CONTAINER_NAME" mkdir -p /opt/eda-scripts
for script in prefetch_ciel.sh prefetch_lambda.py prefetch_extras.sh; do
  "${D[@]}" cp "$INSTALL_DIR/docker/$script" "$CONTAINER_NAME:/opt/eda-scripts/$script"
done
"${D[@]}" exec -u 0:0 "$CONTAINER_NAME" chmod +x /opt/eda-scripts/prefetch_ciel.sh /opt/eda-scripts/prefetch_extras.sh
"${D[@]}" exec "$CONTAINER_NAME" python3 -c \
  'from importlib.metadata import version; print("ciel",version("ciel"),"lambdapdk",version("lambdapdk"),"siliconcompiler",version("siliconcompiler"))'

if [[ "$SKIP_DOWNLOAD" == 1 ]]; then
  info 'SKIP_DOWNLOAD=1: configuracao finalizada sem downloads.'
  exit 0
fi
errors=0
run_stage() {
  local logfile="$1"; shift
  if "$@" 2>&1 | tee "$INSTALL_DIR/logs/$logfile"; then
    info "Etapa concluida: $logfile"
  else
    info "Falha em $logfile; consultar relatorio correspondente."
    errors=$((errors+1))
  fi
}
if [[ "$SKIP_CIEL" != 1 ]]; then
  run_stage "ciel_${RUN_ID}.log" "${D[@]}" exec "$CONTAINER_NAME" /opt/eda-scripts/prefetch_ciel.sh
fi
if [[ "$SKIP_LAMBDA" != 1 ]]; then
  run_stage "lambdapdk_${RUN_ID}.log" "${D[@]}" exec -e RETRIES="$RETRIES" "$CONTAINER_NAME" \
    python3 -u /opt/eda-scripts/prefetch_lambda.py
fi
if [[ "$SKIP_EXTRAS" != 1 ]]; then
  run_stage "extras_${RUN_ID}.log" "${D[@]}" exec -e ICS_RELEASE="$ICS_RELEASE" "$CONTAINER_NAME" \
    /opt/eda-scripts/prefetch_extras.sh
fi
info "Instalacao finalizada: $INSTALL_DIR"
printf 'Shell: %s/eda-pdk shell\n' "$INSTALL_DIR"
printf 'Relatorios: %s/workspace/*.tsv\n' "$INSTALL_DIR"
printf 'Logs: %s/logs/\n' "$INSTALL_DIR"
((errors==0)) || fail "$errors etapa(s) falharam. Arquivos ja baixados foram preservados."
info 'Todas as etapas selecionadas foram concluidas.'
