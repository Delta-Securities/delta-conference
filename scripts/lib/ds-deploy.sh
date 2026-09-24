#!/usr/bin/env bash
# =============================================================================
# ds-deploy.sh — общая библиотека деплоя Delta Securities.
#
# НЕ РЕДАКТИРУЙТЕ ЭТОТ ФАЙЛ В РЕПОЗИТОРИИ ПРОЕКТА. Он побайтно одинаков во всех
# репозиториях организации (сверка: sha256sum scripts/lib/ds-deploy.sh).
# Новая версия выпускается в эталоне стандарта и раскладывается PR во все репо.
# Всё проектное — только в scripts/deploy.sh (переменные и функции целей).
#
# Стандарт: DEPLOY_STANDARD.md. Факты проекта: DEPLOY.md в корне репозитория.
#
# Что гарантирует команда `scripts/deploy.sh <prod|staging>`:
#   * выкатывается строго origin/<основная ветка> (prod) или origin/develop
#     (staging) после git fetch — рабочая копия, текущая ветка и незакоммиченные
#     правки на выкатку не влияют;
#   * логика выкатки тоже берётся из этого коммита: скрипт распаковывает
#     scripts/ коммита во временный каталог и перезапускает себя оттуда;
#   * код едет только из `git archive <sha>` (LF, без .env и рабочих файлов);
#   * у коммита должен быть зелёный check-run `ci` (GitHub Actions);
#   * на сервере ведётся маркер .ds-deploy/ (DEPLOYED, MANIFEST, history):
#     без маркера реальная выкатка отказывает (нужна разовая миграция), ручные
#     правки файлов (дрейф) — отказ со списком файлов;
#   * все ИЗМЕНЯЮЩИЕ удалённые действия идут только через ds_run (в --dry-run
#     она лишь печатает), все ЧТЕНИЯ с сервера — только через ds_probe.
#
# Работает в Git Bash на Windows (ПК владельца) и в Linux (GitHub Actions).
# Совместима с `set -euo pipefail`. Секреты не читает и не печатает: set -x
# выключается, .env и похожие на секреты файлы не выкатываются и не хэшируются.
# =============================================================================

DS_DEPLOY_LIB_VERSION=1.0.0

# Никакой трассировки: в командах могут оказаться имена хостов и пути ключей,
# а в проектных хуках — что угодно.
set +x

# ---------------------------------------------------------------------------
# Константы
# ---------------------------------------------------------------------------
DS_CI_CHECK_NAME="ci"          # имя job в .github/workflows/ci.yml
DS_CI_APP_ID=15368             # GitHub Actions (app id check-run'ов)
DS_CI_WAIT_SECONDS=900         # --wait-ci: ждать не дольше 15 минут
DS_MSK_OFFSET=10800            # МСК = UTC+3 (в Git Bash нет tzdata!)
DS_REMOTE_LOCK=/tmp/ds-deploy.lock   # общий лок всех проектов на сервере
DS_SSH_COMMON_OPTS=(
  -o BatchMode=yes
  -o ConnectTimeout=15
  -o ServerAliveInterval=30      # keepalive: долгая сборка без вывода не рвёт
  -o ServerAliveCountMax=10      # соединение (авария deltaprop 24.09.2026)
  -o StrictHostKeyChecking=yes   # только закреплённые отпечатки, без accept-new
  -o IdentitiesOnly=yes
)
# Файлы, похожие на секреты: никогда не выкатываются, не хэшируются, не
# удаляются. Шаблоны — от корня цели (см. «Шаблоны путей» ниже).
# Исключение: имена, оканчивающиеся на .example.
DS_SECRET_PATTERNS=(
  '**/.env' '**/.env.*' '**/*.pem' '**/*.key' '**/*.p12' '**/*.pfx'
  '**/id_rsa*' '**/id_ed25519*' '**/id_ecdsa*' '**/credentials*' '**/auth*.ini'
)

# ---------------------------------------------------------------------------
# Вывод
# ---------------------------------------------------------------------------
ds_info() { printf '%s\n' "$*"; }
ds_warn() { printf '! %s\n' "$*" >&2; }
ds_die()  { printf '✗ %s\n' "$*" >&2; exit "${_DS_DIE_CODE:-1}"; }
_ds_usage_die() { _DS_DIE_CODE=2 ds_die "$*  (см. scripts/deploy.sh --help)"; }

# Отказ по проверке: копится и печатается в конце, выкатка не начинается.
_DS_REFUSALS=()
_ds_block() { _DS_REFUSALS+=("$*"); printf '  ✗ %s\n' "$*"; }

_ds_usage() {
  cat <<'EOF'
Использование:
  scripts/deploy.sh prod    [опции]   выкатить origin/<основная ветка> на прод
  scripts/deploy.sh staging [опции]   выкатить origin/develop на полигон

Опции:
  --dry-run                 все проверки и чтение с сервера, ничего не меняет
  --drift                   то же, что --dry-run, но списки файлов полностью
  --yes                     без интерактивного подтверждения (Claude — только
                            по прямой просьбе владельца в этой сессии)
  --only <цель>             выкатить только эту цель (можно повторять)
  --wait-ci                 если ci ещё идёт — ждать до 15 минут
  --skip-ci <причина>       выкатить без зелёного ci (причина — в журнал)
  --ci-from-needs           только в GitHub Actions: ci проверен через needs
  --ignore-window <причина> выкатить вне разрешённого окна (причина — в журнал)
  --overwrite-drift <причина>
                            перезаписать файлы, изменённые на сервере вручную
                            (они сохраняются в .ds-deploy/backup-*.tgz);
                            с --adopt — миграция с заменой отличающихся файлов
  --adopt                   разовая миграция: поставить маркер (см. DEPLOY.md)
  --adopt-sha <sha>         то же, для более старого коммита основной ветки
  --rollback                вернуть предыдущий успешно выкатанный коммит
  --test-ref <ветка>        ТОЛЬКО с --dry-run: проверить ветку PR (логика и
                            файлы из origin/<ветка>) против сервера до мержа
  -h, --help                эта справка

Коды выхода: 0 — успех; 2 — нет цели деплоя или ошибка вызова; 3 — отказ по
проверке (на сервере ничего не менялось); 4 — сбой во время выкатки (состояние
может быть частичным: запустите --dry-run); 5 — выкачено, но проверка здоровья
не прошла.
EOF
}

# ---------------------------------------------------------------------------
# git и gh. В Git Bash отключаем MSYS-преобразование путей для git.exe/gh.exe:
# иначе `sha:путь` превращается в `sha;путь`. Поэтому пути в git передаются
# только в форме C:/... (DS_REPO_ROOT) или относительными.
# ---------------------------------------------------------------------------
ds_git() { MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' git -C "$DS_REPO_ROOT" "$@"; }
# Временный каталог на ПК. TMPDIR в форме C:\... не годится: tar в Git Bash
# принимает «C:» за удалённый хост.
_ds_mktemp() {
  local base=${TMPDIR:-/tmp}
  case "$base" in *:*|*\\*) base=/tmp ;; esac
  mktemp -d "$base/$1.XXXXXX"
}
_ds_gh() { MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' gh "$@"; }

# ---------------------------------------------------------------------------
# Шаблоны путей (DS_PRESERVE, ds_changed): всегда от корня цели.
#   **      — любые символы, включая /;   **/x — x на любой глубине;
#   *       — любые символы, кроме /;     ?    — один символ, кроме /;
#   dir/    — каталог dir и всё внутри.
# Примеры: .env  data/  backend/*.db*  **/node_modules/  deploy/vpn/
# ---------------------------------------------------------------------------
_ds_glob_re() {
  local p=$1 re="" c i n dir=0
  if [ "${p%/}" != "$p" ]; then dir=1; p=${p%/}; fi
  n=${#p}
  for ((i = 0; i < n; i++)); do
    c=${p:i:1}
    case "$c" in
      '*')
        if [ "${p:i+1:1}" = '*' ]; then
          if [ "${p:i+2:1}" = '/' ]; then re+='(.*/)?'; i=$((i + 2)); else re+='.*'; i=$((i + 1)); fi
        else
          re+='[^/]*'
        fi ;;
      '?') re+='[^/]' ;;
      '.'|'+'|'^'|'$'|'('|')'|'{'|'}'|'|'|'['|']'|'\') re+="\\$c" ;;
      *) re+=$c ;;
    esac
  done
  if [ "$dir" = 1 ]; then printf '^%s/' "$re"; else printf '^%s$' "$re"; fi
}

# Проверка для удалённых хуков: изменился ли хоть один путь по шаблонам.
#   if ds_changed 'backend/**' 'docker-compose*.yml'; then ... fi
ds_changed() {
  local re="" p
  for p in "$@"; do re+="${re:+|}($(_ds_glob_re "$p"))"; done
  [ -n "$re" ] || return 1
  grep -Eq -- "$re" "$DS_CHANGED_FILE"
}

_ds_build_patterns() {
  local p re=""
  for p in "${DS_PRESERVE[@]}"; do re+="${re:+|}($(_ds_glob_re "$p"))"; done
  if [ "${DS_MARKER_DIR#"$DS_DIR"/}" != "$DS_MARKER_DIR" ]; then
    re+="${re:+|}($(_ds_glob_re "${DS_MARKER_DIR#"$DS_DIR"/}/"))"
  fi
  _DS_USER_RE=$re
  re=""
  for p in "${DS_SECRET_PATTERNS[@]}"; do re+="${re:+|}($(_ds_glob_re "$p"))"; done
  _DS_SECRET_RE=$re
  # Каталоги без масок — find на сервере их не обходит (node_modules, data...).
  _DS_PRUNE_DIRS=(.git)
  for p in "${DS_PRESERVE[@]}"; do
    case "$p" in *'*'*|*'?'*|*'['*) continue ;; */) _DS_PRUNE_DIRS+=("${p%/}") ;; esac
  done
  if [ "${DS_MARKER_DIR#"$DS_DIR"/}" != "$DS_MARKER_DIR" ]; then
    _DS_PRUNE_DIRS+=("${DS_MARKER_DIR#"$DS_DIR"/}")
  fi
}

# stdin: относительные пути → stdout: те, что сохраняются (не выкатываются и
# не трогаются): DS_PRESERVE, маркер, похожие на секреты (кроме *.example).
_ds_kept() {
  DS_U="$_DS_USER_RE" DS_S="$_DS_SECRET_RE" awk '
    (ENVIRON["DS_U"] != "" && $0 ~ ENVIRON["DS_U"]) ||
    ($0 ~ ENVIRON["DS_S"] && $0 !~ /\.example$/)'
}
_ds_not_kept() {
  DS_U="$_DS_USER_RE" DS_S="$_DS_SECRET_RE" awk '
    !((ENVIRON["DS_U"] != "" && $0 ~ ENVIRON["DS_U"]) ||
      ($0 ~ ENVIRON["DS_S"] && $0 !~ /\.example$/))'
}

# ---------------------------------------------------------------------------
# Окно выкатки. Задаётся в МСК: "any" | "none" | записи через «;»:
#   "<дни> <ЧЧ:ММ>-<ЧЧ:ММ>"  дни: daily | mon-fri | sat,sun | mon,wed-fri
#   Пример: "mon-fri 00:00-06:30; sat,sun 00:00-24:00"
# Начало включительно, конец — нет; переход через полночь — двумя записями.
# МСК считается как UTC+3 арифметикой: в Git Bash нет базы часовых поясов,
# TZ=Europe/Moscow там молча даёт UTC.
# _ds_in_window <окно> <epoch UTC>: 0 — в окне, 1 — вне, 2 — ошибка в окне.
# ---------------------------------------------------------------------------
_ds_day_num() {
  case "$1" in
    mon) echo 1 ;; tue) echo 2 ;; wed) echo 3 ;; thu) echo 4 ;;
    fri) echo 5 ;; sat) echo 6 ;; sun) echo 7 ;; *) echo 0 ;;
  esac
}
_ds_day_in() {  # <дни> <номер дня 1..7>
  local spec=$1 dow=$2 tok a b
  [ "$spec" = daily ] && return 0
  for tok in ${spec//,/ }; do
    a=$(_ds_day_num "${tok%-*}"); b=$(_ds_day_num "${tok#*-}")
    [ "$a" != 0 ] && [ "$b" != 0 ] || return 2
    if [ "$a" -le "$b" ]; then
      [ "$dow" -ge "$a" ] && [ "$dow" -le "$b" ] && return 0
    else
      { [ "$dow" -ge "$a" ] || [ "$dow" -le "$b" ]; } && return 0
    fi
  done
  return 1
}
_ds_in_window() {
  local spec=$1 now=$2 msk dow cur days range rest from to f t rc
  case "$spec" in any) return 0 ;; none) return 1 ;; '') return 2 ;; esac
  msk=$((now + DS_MSK_OFFSET))
  dow=$(date -u -d "@$msk" +%u)
  cur=$(date -u -d "@$msk" +%H%M)
  cur=$((10#${cur:0:2} * 60 + 10#${cur:2:2}))
  while read -r days range rest; do
    [ -n "$days" ] || continue
    [ -z "$rest" ] && [ -n "$range" ] || return 2
    from=${range%-*}; to=${range#*-}
    [[ $from =~ ^[0-2][0-9]:[0-5][0-9]$ && $to =~ ^[0-2][0-9]:[0-5][0-9]$ ]] || return 2
    f=$((10#${from%:*} * 60 + 10#${from#*:})); t=$((10#${to%:*} * 60 + 10#${to#*:}))
    [ "$f" -lt "$t" ] && [ "$t" -le 1440 ] || return 2
    rc=0; _ds_day_in "$days" "$dow" || rc=$?
    [ "$rc" != 2 ] || return 2
    [ "$rc" = 0 ] || continue
    if [ "$cur" -ge "$f" ] && [ "$cur" -lt "$t" ]; then return 0; fi
  done < <(printf '%s\n' "$spec" | tr ';' '\n')
  return 1
}
_ds_msk_now() { date -u -d "@$(($(date -u +%s) + DS_MSK_OFFSET))" '+%a %d.%m %H:%M МСК'; }

# ---------------------------------------------------------------------------
# Аргументы
# ---------------------------------------------------------------------------
_ds_reason() {  # <флаг> <значение>
  [ -n "${2:-}" ] && [ "${2#--}" = "$2" ] && [ "${#2}" -ge 5 ] \
    || _ds_usage_die "для $1 нужна причина словами (не короче 5 символов)"
}
_ds_parse_args() {
  DS_ENV=""; DS_DRY=0; DS_VERBOSE=0; DS_YES=0; DS_ONLY=(); DS_WAIT_CI=0
  DS_SKIP_CI=""; DS_CI_FROM_NEEDS=0; DS_IGNORE_WINDOW=""; DS_OVERWRITE_DRIFT=""
  DS_ADOPT=0; DS_ADOPT_SHA=""; DS_ROLLBACK=0; DS_TEST_REF=""
  while [ $# -gt 0 ]; do
    case "$1" in
      prod|staging)
        [ -z "$DS_ENV" ] || _ds_usage_die "окружение указано дважды"
        DS_ENV=$1 ;;
      --dry-run) DS_DRY=1 ;;
      --drift) DS_DRY=1; DS_VERBOSE=1 ;;
      --yes|-y) DS_YES=1 ;;
      --only) [ $# -ge 2 ] || _ds_usage_die "--only без цели"; DS_ONLY+=("$2"); shift ;;
      --only=*) DS_ONLY+=("${1#*=}") ;;
      --wait-ci) DS_WAIT_CI=1 ;;
      --skip-ci) _ds_reason "$1" "${2:-}"; DS_SKIP_CI=$2; shift ;;
      --skip-ci=*) _ds_reason --skip-ci "${1#*=}"; DS_SKIP_CI=${1#*=} ;;
      --ci-from-needs) DS_CI_FROM_NEEDS=1 ;;
      --ignore-window) _ds_reason "$1" "${2:-}"; DS_IGNORE_WINDOW=$2; shift ;;
      --ignore-window=*) _ds_reason --ignore-window "${1#*=}"; DS_IGNORE_WINDOW=${1#*=} ;;
      --overwrite-drift) _ds_reason "$1" "${2:-}"; DS_OVERWRITE_DRIFT=$2; shift ;;
      --overwrite-drift=*) _ds_reason --overwrite-drift "${1#*=}"; DS_OVERWRITE_DRIFT=${1#*=} ;;
      --adopt) DS_ADOPT=1 ;;
      --adopt-sha) [ $# -ge 2 ] || _ds_usage_die "--adopt-sha без коммита"; DS_ADOPT=1; DS_ADOPT_SHA=$2; shift ;;
      --rollback) DS_ROLLBACK=1 ;;
      --test-ref) [ $# -ge 2 ] || _ds_usage_die "--test-ref без ветки"; DS_TEST_REF=$2; shift ;;
      -h|--help) _ds_usage; exit 0 ;;
      *) _ds_usage_die "неизвестный аргумент: $1" ;;
    esac
    shift
  done
  [ -n "$DS_ENV" ] || _ds_usage_die "укажите окружение: prod или staging"
  if [ "$DS_ADOPT" = 1 ] && [ "$DS_ROLLBACK" = 1 ]; then _ds_usage_die "--adopt и --rollback вместе нельзя"; fi
  if [ "$DS_CI_FROM_NEEDS" = 1 ] && [ "${GITHUB_ACTIONS:-}" != true ]; then
    _ds_usage_die "--ci-from-needs допустим только внутри GitHub Actions"
  fi
  if [ "$DS_CI_FROM_NEEDS" = 1 ] && { [ "$DS_ROLLBACK" = 1 ] || [ -n "$DS_ADOPT_SHA" ]; }; then
    _ds_usage_die "--ci-from-needs нельзя с --rollback/--adopt-sha"
  fi
  if [ -n "$DS_TEST_REF" ]; then
    [ "$DS_DRY" = 1 ] || _ds_usage_die "--test-ref допустим только вместе с --dry-run"
    [[ $DS_TEST_REF =~ ^[A-Za-z0-9._/-]+$ ]] || _ds_usage_die "--test-ref: недопустимое имя ветки"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Репозиторий: корень, owner/repo, основная ветка
# ---------------------------------------------------------------------------
_ds_init_repo() {
  local sd url path
  if [ -z "${DS_REPO_ROOT:-}" ]; then
    sd=$(dirname "${BASH_SOURCE[-1]}")
    DS_REPO_ROOT=$(git -C "$sd" rev-parse --show-toplevel 2>/dev/null) \
      || ds_die "scripts/deploy.sh запущен не из git-репозитория"
  fi
  [ -n "${DS_GH_REPO:-}" ] || ds_die "в scripts/deploy.sh не задан DS_GH_REPO (например Delta-Securities/spread-arb)"
  DS_REPO_NAME=${DS_GH_REPO#*/}
  url=$(ds_git remote get-url origin 2>/dev/null) || ds_die "у репозитория нет remote origin"
  case "$url" in
    https://github.com/*|git@github.com:*|ssh://git@github.com/*)
      path=${url#*github.com}; path=${path#[:/]}; path=${path%.git}; path=${path%/} ;;
    *) path="" ;;
  esac
  if [ "$path" = "$DS_GH_REPO" ]; then
    :
  elif [ "$path" = "danya-urb/$DS_REPO_NAME" ]; then
    ds_warn "origin указывает на старый адрес danya-urb/$DS_REPO_NAME — работает через редирект; поправьте: git remote set-url origin https://github.com/$DS_GH_REPO.git"
  elif [ -z "$path" ] && [ "${DS_SELFTEST:-}" = 1 ]; then
    :
  else
    ds_die "origin ($url) не совпадает с $DS_GH_REPO"
  fi
  DS_MAIN_BRANCH=$(ds_git ls-remote --symref origin HEAD 2>/dev/null \
    | awk '$1 == "ref:" { sub("^refs/heads/", "", $2); print $2; exit }') || true
  [ -n "$DS_MAIN_BRANCH" ] || ds_die "не удалось определить основную ветку origin (git ls-remote --symref origin HEAD)"
  if [ "$DS_ENV" = prod ]; then DS_BRANCH=$DS_MAIN_BRANCH; else DS_BRANCH=develop; fi
  # Проверка ветки PR до мержа — только в --dry-run (см. _ds_parse_args).
  if [ -n "$DS_TEST_REF" ]; then DS_BRANCH=$DS_TEST_REF; fi
}

# git fetch в собственную ссылку refs/ds-deploy/<ветка>: локальные ветки,
# checkout и FETCH_HEAD не трогаются.
_ds_fetch_branch() {
  ds_git fetch --quiet --no-tags origin "+refs/heads/$1:refs/ds-deploy/$1" \
    || ds_die "git fetch origin $1 не удался (нет сети или ветки $1)"
  ds_git rev-parse --verify --quiet "refs/ds-deploy/$1^{commit}" || ds_die "нет ветки origin/$1"
}

# ---------------------------------------------------------------------------
# Перезапуск из архива коммита: логика выкатки = логика из этого коммита.
# ---------------------------------------------------------------------------
_ds_reexec() {
  local sha dir other
  sha=$(_ds_fetch_branch "$DS_BRANCH")
  dir=$(_ds_mktemp ds-deploy)
  if ! ds_git -c core.autocrlf=false -c core.eol=lf archive --format=tar "$sha" scripts 2>/dev/null \
       | tar -x -C "$dir" -f - 2>/dev/null \
     || [ ! -f "$dir/scripts/deploy.sh" ] || [ ! -f "$dir/scripts/lib/ds-deploy.sh" ]; then
    rm -rf -- "$dir"
    _DS_DIE_CODE=3 ds_die "в origin/$DS_BRANCH (${sha:0:9}) ещё нет стандартных scripts/deploy.sh и scripts/lib/ds-deploy.sh — выкатка возможна только после мержа PR со стандартом"
  fi
  printf '%s\n' "$sha" > "$dir/.ds-reexec"
  other=$(sed -n 's/^DS_DEPLOY_LIB_VERSION=//p' "$dir/scripts/lib/ds-deploy.sh" | head -n 1)
  if [ "$other" != "$DS_DEPLOY_LIB_VERSION" ]; then
    ds_info "библиотека в рабочей копии $DS_DEPLOY_LIB_VERSION, в origin/$DS_BRANCH — $other (используется $other)"
  fi
  export DS_REEXEC="$sha" DS_REEXEC_DIR="$dir" DS_REPO_ROOT
  exec bash "$dir/scripts/deploy.sh" "$@"
}

_ds_verify_reexec() {
  local self want cur
  DS_REEXEC_DIR=${DS_REEXEC_DIR:-/nonexistent}
  [ -f "$DS_REEXEC_DIR/.ds-reexec" ] && [ "$(cat "$DS_REEXEC_DIR/.ds-reexec")" = "$DS_REEXEC" ] \
    || ds_die "DS_REEXEC задан вручную — так нельзя; запустите scripts/deploy.sh без него"
  self=$(cd "$(dirname "${BASH_SOURCE[-1]}")/.." && pwd -P)
  want=$(cd "$DS_REEXEC_DIR" && pwd -P)
  [ "$self" = "$want" ] || ds_die "скрипт запущен не из архива коммита ($self)"
  cur=$(ds_git rev-parse --verify --quiet "refs/ds-deploy/$DS_BRANCH^{commit}") || true
  [ "$cur" = "$DS_REEXEC" ] || ds_die "origin/$DS_BRANCH изменилась во время запуска — повторите команду"
}

# ---------------------------------------------------------------------------
# Проверка CI: у коммита должен быть завершённый успешный check-run `ci`
# приложения GitHub Actions. Только GET-запросы.
# ---------------------------------------------------------------------------
declare -gA _DS_CI_DONE=()
_ds_ci_status() {
  local out
  out=$(_ds_gh api "repos/$DS_GH_REPO/commits/$1/check-runs?check_name=$DS_CI_CHECK_NAME&filter=latest&per_page=100" \
    --jq '[.check_runs[] | select(.app.id == '"$DS_CI_APP_ID"' and .name == "'"$DS_CI_CHECK_NAME"'")]
          | sort_by(.started_at // "") | last
          | if . == null then "none none" else "\(.status) \(.conclusion // "none")" end' 2>/dev/null) || out=""
  printf '%s\n' "${out:-error error}"
}
_ds_ci_gate() {  # <sha>; при неуспехе — _ds_block
  local sha=$1 st conc deadline=$((SECONDS + DS_CI_WAIT_SECONDS))
  [ -z "${_DS_CI_DONE[$sha]:-}" ] || return 0
  _DS_CI_DONE[$sha]=1
  if [ -n "$DS_SKIP_CI" ]; then
    ds_warn "проверка ci для ${sha:0:9} ПРОПУЩЕНА: $DS_SKIP_CI"
    return 0
  fi
  if [ "$DS_CI_FROM_NEEDS" = 1 ]; then
    ds_info "  ci: проверен в этом же workflow (needs: ci), коммит ${sha:0:9}"
    return 0
  fi
  if ! command -v gh >/dev/null 2>&1; then
    _ds_block "нет gh — не могу проверить ci у ${sha:0:9}"
    return 0
  fi
  while :; do
    read -r st conc < <(_ds_ci_status "$sha")
    case "$st/$conc" in
      completed/success) ds_info "  ci: зелёный у ${sha:0:9}"; return 0 ;;
      completed/*) _ds_block "ci у ${sha:0:9} завершился с результатом «$conc» — выкатывать нельзя"; return 0 ;;
      none/*) _ds_block "у ${sha:0:9} нет прогона ci (job «ci» в .github/workflows/ci.yml)"; return 0 ;;
      error/*) _ds_block "не удалось получить статус ci у ${sha:0:9} (gh api; gh auth status?)"; return 0 ;;
      *)
        if [ "$DS_WAIT_CI" = 1 ] && [ "$SECONDS" -lt "$deadline" ]; then
          ds_info "  ci ещё идёт ($st) — жду…"; sleep 20; continue
        fi
        _ds_block "ci у ${sha:0:9} ещё не завершён ($st) — повторите позже или добавьте --wait-ci"
        return 0 ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Транспорт. DS_HOST=local — фиктивная цель «локальная папка» (только для
# самопроверки, DS_SELFTEST=1): те же скрипты исполняются локальным bash.
# ---------------------------------------------------------------------------
_ds_ssh_argv() {
  local kh=$DS_KNOWN_HOSTS pc jk
  _DS_SSH=(ssh "${DS_SSH_COMMON_OPTS[@]}" -o "UserKnownHostsFile=$kh" -i "$DS_KEY")
  if [ -n "$DS_JUMP" ]; then
    jk=${DS_JUMP_KEY:-$DS_KEY}
    pc="ssh ${DS_SSH_COMMON_OPTS[*]} -o UserKnownHostsFile=$(printf %q "$kh") -i $(printf %q "$jk") -W %h:%p $(printf %q "$DS_JUMP")"
    _DS_SSH+=(-o "ProxyCommand=$pc")
  fi
  _DS_SSH+=("$DS_USER@$DS_HOST")
}
_ds_transport_script() {  # stdin — скрипт для bash на сервере
  if [ "$DS_HOST" = local ]; then
    bash -s
  else
    _ds_ssh_argv
    "${_DS_SSH[@]}" 'bash -s'
  fi
}
_ds_transport_apply() {  # <пакет.tar>: распаковать во временный каталог сервера и выполнить run.sh
  local pkg=$1 cmd
  # shellcheck disable=SC2016  # $d раскрывается на сервере
  cmd='d=$(mktemp -d /tmp/ds-deploy.XXXXXX) && tar -x -C "$d" -f - && exec bash "$d/ctl/run.sh" "$d"'
  if [ "$DS_HOST" = local ]; then
    bash -c "$cmd" < "$pkg"
  else
    _ds_ssh_argv
    "${_DS_SSH[@]}" "bash -c $(printf %q "$cmd")" < "$pkg"
  fi
}

# ЕДИНСТВЕННАЯ точка ЧТЕНИЯ с сервера. Скрипт, который сюда передаётся,
# обязан только читать (cat/test/find/sha256sum/df). Выполняется и в --dry-run.
ds_probe() {  # <описание> <текст скрипта>
  [ "${DS_VERBOSE:-0}" = 0 ] || ds_info "  чтение: $1"
  printf '%s\n' "$2" | _ds_transport_script
}

# ЕДИНСТВЕННАЯ точка ИЗМЕНЯЮЩИХ удалённых действий. В --dry-run только
# печатает, что было бы сделано, и ничего не выполняет.
ds_run() {  # <описание> <команда> [аргументы...]
  local desc=$1; shift
  if [ "$DS_DRY" = 1 ]; then
    ds_info "  [dry-run] НЕ выполняю: $desc"
    return 0
  fi
  ds_info "→ $desc"
  "$@"
}

# ---------------------------------------------------------------------------
# Чтение состояния сервера (только чтение)
# ---------------------------------------------------------------------------
_ds_probe_state_script() {
  declare -p DS_DIR DS_SUDO DS_MARKER_DIR _DS_PRUNE_DIRS
  cat <<'EOF'
SUDO=""; if [ "$DS_SUDO" = 1 ]; then SUDO="sudo -n"; fi
M=$DS_MARKER_DIR
echo "@@SUDO"; if [ -n "$SUDO" ] && ! $SUDO true 2>/dev/null; then echo fail; else echo ok; fi
echo "@@DIREXISTS"; if $SUDO test -d "$DS_DIR"; then echo yes; else echo no; fi
echo "@@DEPLOYED"; $SUDO cat "$M/DEPLOYED" 2>/dev/null || true
echo "@@HISTORY"; $SUDO tail -n 50 "$M/history" 2>/dev/null || true
echo "@@OLDMAN"; $SUDO cat "$M/MANIFEST" 2>/dev/null || true
echo "@@DRIFTRAW"
if $SUDO test -f "$M/MANIFEST"; then
  $SUDO cat "$M/MANIFEST" | awk -v p="$DS_DIR/" '{ print substr($0, 1, 64) "  " p substr($0, 67) }' \
    | $SUDO sha256sum -c --quiet - 2>/dev/null || true
fi
echo "@@GIT"; if $SUDO test -e "$DS_DIR/.git"; then echo yes; else echo no; fi
echo "@@FREE"
d=$DS_DIR; while [ "$d" != / ] && ! $SUDO test -d "$d"; do d=$(dirname "$d"); done
$SUDO df -Pm "$d" 2>/dev/null | awk 'NR == 2 { print $4 }' || true
echo "@@FILES"
if $SUDO test -d "$DS_DIR"; then
  args=(-path "$DS_DIR/.git")
  for p in "${_DS_PRUNE_DIRS[@]}"; do args+=(-o -path "$DS_DIR/$p"); done
  $SUDO find "$DS_DIR" -xdev \( "${args[@]}" \) -prune -o -type f -printf '%P\n' 2>/dev/null \
    | LC_ALL=C sort | head -n 50000 || true
fi
echo "@@END"
EOF
}
_ds_probe_hash_script() {  # <файл со списком относительных путей>
  declare -p DS_DIR DS_SUDO
  cat <<'EOF'
SUDO=""; if [ "$DS_SUDO" = 1 ]; then SUDO="sudo -n"; fi
echo "@@SRVMAN"
awk -v p="$DS_DIR/" '{ print p $0 }' <<'DS_PATHS_EOF' | tr '\n' '\0' | $SUDO xargs -0 -r sha256sum -- 2>/dev/null || true
EOF
  cat "$1"
  printf 'DS_PATHS_EOF\necho "@@END"\n'
}
_ds_split_probe() {  # <вывод> <каталог>: секции @@NAME → файлы name
  awk -v dir="$2" '
    /^@@[A-Z]+$/ { f = dir "/" tolower(substr($0, 3)); printf "" > f; next }
    f != "" { print > f }' "$1"
  [ -f "$2/end" ]
}

# ---------------------------------------------------------------------------
# Проектная конфигурация цели
# ---------------------------------------------------------------------------
_ds_load_target() {
  local t=$1
  DS_TARGET=$t
  DS_HOST=""; DS_USER=""; DS_KEY=""; DS_JUMP=""; DS_JUMP_KEY=""; DS_DIR=""
  DS_SUDO=0; DS_CHOWN=""; DS_MARKER_DIR=""; DS_SUBDIR=""; DS_BUILD_OUT=""
  DS_KNOWN_HOSTS=""; DS_ADOPT_MODE=verify
  DS_WINDOW=$_DS_ENV_WINDOW; DS_MIN_FREE_MB=$_DS_ENV_MIN_FREE
  DS_PRESERVE=(); DS_EXPORT=()
  declare -F "ds_target_$t" >/dev/null || ds_die "в scripts/deploy.sh нет функции ds_target_$t"
  "ds_target_$t"
  DS_DIR=${DS_DIR%/}
  [ -n "$DS_HOST" ] || ds_die "цель $t: не задан DS_HOST"
  case "$DS_DIR" in /?*) ;; *) ds_die "цель $t: DS_DIR должен быть абсолютным путём, не «/»" ;; esac
  if [ "$DS_HOST" = local ]; then
    [ "${DS_SELFTEST:-}" = 1 ] || ds_die "цель $t: DS_HOST=local допустим только в самопроверке"
    DS_SUDO=0
  else
    [ -n "$DS_USER" ] && [ -n "$DS_KEY" ] || ds_die "цель $t: нужны DS_USER и DS_KEY"
    [ -f "$DS_KEY" ] || ds_die "цель $t: нет ключа $DS_KEY"
  fi
  if [ "$DS_ENV" = prod ] && [ -z "$DS_WINDOW" ]; then
    ds_die "цель $t: для prod обязателен DS_WINDOW (\"any\" или окна в МСК)"
  fi
  [ -n "$DS_WINDOW" ] || DS_WINDOW=any
  case "$DS_ADOPT_MODE" in verify|replace) ;; *) ds_die "цель $t: DS_ADOPT_MODE — verify или replace" ;; esac
  [[ $DS_MIN_FREE_MB =~ ^[0-9]+$ ]] || ds_die "цель $t: DS_MIN_FREE_MB — число МБ"
  [ -n "$DS_MARKER_DIR" ] || DS_MARKER_DIR="$DS_DIR/.ds-deploy"
  case "$DS_MARKER_DIR" in
    /var/www/*|*/public/*|*/site/*|*/html/*)
      ds_warn "цель $t: маркер $DS_MARKER_DIR, похоже, в веб-корне — задайте DS_MARKER_DIR вне него" ;;
  esac
  if [ -z "$DS_KNOWN_HOSTS" ]; then
    if [ -f "$DS_REEXEC_DIR/scripts/lib/known_hosts" ]; then
      DS_KNOWN_HOSTS="$DS_REEXEC_DIR/scripts/lib/known_hosts"
    else
      DS_KNOWN_HOSTS="$HOME/.ssh/known_hosts"
    fi
  fi
  if declare -F "ds_${t}_build" >/dev/null && [ -z "$DS_BUILD_OUT" ]; then
    ds_die "цель $t: есть ds_${t}_build, но не задан DS_BUILD_OUT (каталог результата сборки)"
  fi
  _ds_build_patterns
}

# ---------------------------------------------------------------------------
# Полезная нагрузка: payload.tar + MANIFEST (sha256 и путь) из коммита
# ---------------------------------------------------------------------------
_ds_manifest_of() {  # <каталог> → stdout «sha256  путь» (в Git Bash sha256sum пишет «sha256 *путь»)
  (cd "$1" && find . -type f -printf '%P\0' | LC_ALL=C sort -z | xargs -0 -r sha256sum --) \
    | sed -E 's/^([0-9a-f]{64}) [ *]/\1  /'
}
# Вызывать отдельной командой (не в if/&&/||, иначе set -e внутри не работает);
# итог — в _DS_PAYLOAD_OK (1 — нагрузка готова).
_ds_make_payload() {  # <sha> <каталог плана>
  local sha=$1 P=$2 tree=$1 out rc
  _DS_PAYLOAD_OK=0
  : > "$P/excluded.lst"
  if declare -F "ds_${DS_TARGET}_build" >/dev/null; then
    if [ "$DS_DRY" = 1 ]; then
      ds_info "  сборка ds_${DS_TARGET}_build в --dry-run пропущена: список изменений цели будет известен при выкатке"
      : > "$P/new.man"; echo 1 > "$P/nobuild"
      _DS_PAYLOAD_OK=1
      return 0
    fi
    mkdir -p "$P/src"
    ds_git -c core.autocrlf=false -c core.eol=lf archive --format=tar "$sha" | tar -x -C "$P/src" -f -
    ds_info "  сборка ds_${DS_TARGET}_build из архива ${sha:0:9} (не из рабочей копии)…"
    set +e
    (set -e; cd "$P/src"; "ds_${DS_TARGET}_build")
    rc=$?
    set -e
    [ "$rc" = 0 ] || { _ds_block "$DS_TARGET: сборка упала (код $rc)"; return 0; }
    out="$P/src/$DS_BUILD_OUT"
    [ -d "$out" ] || { _ds_block "$DS_TARGET: после сборки нет каталога $DS_BUILD_OUT"; return 0; }
    (cd "$out" && find . -type f -printf '%P\n' | LC_ALL=C sort) | _ds_kept > "$P/excluded.lst"
    (cd "$out" && tr '\n' '\0' < "$P/excluded.lst" | xargs -0 -r rm -f --)
    (cd "$out" && find . -type f -printf '%P\n' | LC_ALL=C sort | tar -cf "$P/payload.tar" -T -)
    _ds_manifest_of "$out" > "$P/new.man"
  else
    [ -z "$DS_SUBDIR" ] || tree="$sha:$DS_SUBDIR"
    ds_git -c core.autocrlf=false -c core.eol=lf archive --format=tar "$tree" > "$P/payload.tar" \
      || { _ds_block "$DS_TARGET: git archive $tree не удался"; return 0; }
    tar -tf "$P/payload.tar" | grep -v '/$' | _ds_kept > "$P/excluded.lst" || true
    if [ -s "$P/excluded.lst" ]; then
      tar --delete -f "$P/payload.tar" -T "$P/excluded.lst"
    fi
    mkdir -p "$P/pl"
    tar -x -C "$P/pl" -f "$P/payload.tar"
    _ds_manifest_of "$P/pl" > "$P/new.man"
  fi
  if grep -q '^\\' "$P/new.man"; then
    _ds_block "$DS_TARGET: имена файлов с «\\» или переводом строки не поддерживаются"
    return 0
  fi
  _DS_PAYLOAD_OK=1
  return 0
}

# ---------------------------------------------------------------------------
# План цели: чтение сервера, сравнение, проверки. Ничего не меняет.
# ---------------------------------------------------------------------------
_ds_show_list() {  # <заголовок> <файл>
  local n lim=30
  [ -s "$2" ] || return 0
  n=$(wc -l < "$2" | tr -d ' ')
  ds_info "  $1: $n"
  [ "$DS_VERBOSE" = 1 ] && lim=100000
  head -n "$lim" "$2" | sed 's/^/      /'
  [ "$n" -le "$lim" ] || ds_info "      … и ещё $((n - lim)) (полный список: --drift)"
}

_ds_plan_target() {
  local t=$1 P="$_DS_W/$1" prev prev_result mode sha now rc cand free
  mkdir -p "$P"
  _ds_load_target "$t"
  ds_info ""
  if [ "$DS_HOST" = local ]; then
    ds_info "■ Цель $t → локальная папка $DS_DIR"
  else
    ds_info "■ Цель $t → $DS_USER@$DS_HOST:$DS_DIR${DS_JUMP:+ (через $DS_JUMP)}"
  fi

  # 1. Состояние сервера (только чтение).
  if ! ds_probe "маркер, дрейф, список файлов" "$(_ds_probe_state_script)" > "$P/probe1.out" \
     || ! _ds_split_probe "$P/probe1.out" "$P"; then
    _ds_block "$t: не удалось прочитать состояние сервера (ssh, ключ, known_hosts?)"
    return 0
  fi
  if [ "$(cat "$P/sudo")" != ok ]; then _ds_block "$t: sudo -n на сервере не работает"; fi
  prev=$(sed -n 's/^sha=//p' "$P/deployed")
  prev_result=$(sed -n 's/^result=//p' "$P/deployed")

  # 2. Режим и коммит.
  sha=$DS_REEXEC; mode=deploy
  if [ "$DS_ADOPT" = 1 ]; then
    if [ -n "$prev" ]; then
      _ds_block "$t: сервер уже мигрирован (маркер на ${prev:0:9}) — --adopt не нужен"
    fi
    mode="adopt-$DS_ADOPT_MODE"
    if [ -n "$DS_ADOPT_SHA" ]; then
      sha=$(ds_git rev-parse --verify --quiet "$DS_ADOPT_SHA^{commit}") \
        || { _ds_block "$t: коммит $DS_ADOPT_SHA не найден"; return 0; }
      ds_git merge-base --is-ancestor "$sha" "refs/ds-deploy/$DS_BRANCH" \
        || { _ds_block "$t: $DS_ADOPT_SHA не входит в origin/$DS_BRANCH"; return 0; }
    fi
  elif [ -z "$prev" ]; then
    if [ "$DS_ENV" = staging ] && [ "$DS_ADOPT_MODE" = replace ]; then
      mode=adopt-replace
      ds_warn "$t: на полигоне нет маркера — первая выкатка перезапишет файлы из git (DS_ADOPT_MODE=replace)"
    else
      _ds_block "$t: сервер не мигрирован (нет маркера ${DS_MARKER_DIR}) — выполните разовую миграцию по DEPLOY.md, затем scripts/deploy.sh $DS_ENV --adopt"
    fi
  fi
  if [ "$DS_ROLLBACK" = 1 ]; then
    cand=$(awk -F'\t' -v cur="$prev" '($3 == "ok" || $3 == "adopted") && $2 != cur { c = $2 } END { print c }' "$P/history")
    if [ -z "$cand" ]; then
      _ds_block "$t: в истории сервера нет предыдущего успешного коммита для отката"
      return 0
    fi
    ds_git cat-file -e "$cand^{commit}" 2>/dev/null && ds_git merge-base --is-ancestor "$cand" "refs/ds-deploy/$DS_BRANCH" \
      || { _ds_block "$t: коммит отката ${cand:0:9} не входит в origin/$DS_BRANCH"; return 0; }
    sha=$cand; mode=rollback
    ds_info "  откат: ${prev:0:9} → ${sha:0:9}"
  fi
  if [ "$sha" != "$DS_REEXEC" ]; then _ds_ci_gate "$sha"; fi
  ds_info "  коммит: $(ds_git log -1 --format='%h %ad %s' --date=short "$sha")"
  if [ -n "$prev" ]; then
    ds_info "  на сервере: ${prev:0:9} (результат: ${prev_result:-?})"
    [ "$prev_result" != pending ] || ds_warn "$t: прошлая выкатка оборвалась (result=pending) — сверяю файлы"
    if [ "$prev" = "$sha" ] && [ "$mode" = deploy ]; then
      ds_info "  на сервере уже этот коммит — выкатка повторит шаги pre/post/health"
    fi
  else
    ds_info "  на сервере: маркера нет"
  fi
  if [ "$(cat "$P/git")" = yes ]; then ds_warn "$t: в каталоге цели есть .git (устаревший клон) — убрать при миграции"; fi

  # 3. Нагрузка и манифест.
  _ds_make_payload "$sha" "$P"
  [ "$_DS_PAYLOAD_OK" = 1 ] || return 0
  _ds_show_list "НЕ выкатывается (DS_PRESERVE или похоже на секрет)" "$P/excluded.lst"

  # 4. Сравнение.
  cut -c67- "$P/new.man" > "$P/new.paths"
  cut -c67- "$P/oldman" > "$P/old.paths"
  awk -v p="$DS_DIR/" 'index($0, p) == 1 { s = substr($0, length(p) + 1); sub(/: FAILED( open or read)?$/, "", s); print s }' \
    "$P/driftraw" | LC_ALL=C sort -u > "$P/drift0.lst"
  if [ -n "$prev" ]; then
    awk 'NR == FNR { o[substr($0, 67)] = substr($0, 1, 64); next }
         { p = substr($0, 67); s[p] = 1
           if (!(p in o)) print "A\t" p; else if (o[p] != substr($0, 1, 64)) print "M\t" p }
         END { for (p in o) if (!(p in s)) print "D\t" p }' "$P/oldman" "$P/new.man" \
      | LC_ALL=C sort -t "$(printf '\t')" -k2 > "$P/diff.txt"
  else
    sed 's/^/A\t/' "$P/new.paths" > "$P/diff.txt"
  fi
  cut -f2- "$P/diff.txt" > "$P/changed.lst"
  grep '^D' "$P/diff.txt" | cut -f2- | _ds_not_kept > "$P/prune.lst" || true
  # Хэши на сервере нужны для: дрейфа, новых для маркера файлов, миграции.
  { cat "$P/drift0.lst"; grep '^A' "$P/diff.txt" | cut -f2- || true; } | LC_ALL=C sort -u \
    | LC_ALL=C comm -12 - "$P/files" > "$P/hash.req"
  : > "$P/srvman.rel"
  if [ -s "$P/hash.req" ]; then
    if ! ds_probe "хэши файлов на сервере" "$(_ds_probe_hash_script "$P/hash.req")" > "$P/probe2.out" \
       || ! _ds_split_probe "$P/probe2.out" "$P"; then
      _ds_block "$t: не удалось прочитать хэши файлов на сервере"
      return 0
    fi
    awk -v p="$DS_DIR/" '{ h = substr($0, 1, 64); s = substr($0, 67); if (index(s, p) == 1) print h "  " substr(s, length(p) + 1) }' \
      "$P/srvman" > "$P/srvman.rel"
  fi
  # Дрейф: файл из старого манифеста изменён, и не совпадает с новым.
  awk -v F="$P/files" -v N="$P/new.man" -v S="$P/srvman.rel" '
    BEGIN { while ((getline l < F) > 0) fs[l] = 1
            while ((getline l < N) > 0) nh[substr(l, 67)] = substr(l, 1, 64)
            while ((getline l < S) > 0) sh[substr(l, 67)] = substr(l, 1, 64) }
    { p = $0
      if ((p in sh) && (p in nh) && sh[p] == nh[p]) next
      if (!(p in fs) && !(p in nh)) next
      print p }' "$P/drift0.lst" > "$P/drift.lst"
  # Конфликт: файла нет в старом манифесте, но на сервере лежит другой.
  grep '^A' "$P/diff.txt" | cut -f2- | awk -v N="$P/new.man" -v S="$P/srvman.rel" '
    BEGIN { while ((getline l < N) > 0) nh[substr(l, 67)] = substr(l, 1, 64)
            while ((getline l < S) > 0) sh[substr(l, 67)] = substr(l, 1, 64) }
    ($0 in sh) && sh[$0] != nh[$0]' > "$P/conflict.lst" || true
  # Чужие файлы: не из git, не сохраняемые. Не трогаются, только список.
  LC_ALL=C sort -u "$P/new.paths" "$P/old.paths" | LC_ALL=C comm -23 "$P/files" - | _ds_not_kept > "$P/extras.lst" || true
  LC_ALL=C comm -23 "$P/new.paths" "$P/files" > "$P/missing.lst"
  cat "$P/drift.lst" "$P/conflict.lst" | LC_ALL=C sort -u | LC_ALL=C comm -12 - "$P/files" > "$P/backup.lst"
  if [ -f "$P/nobuild" ]; then
    # --dry-run без сборки: новый манифест неизвестен — сравнивать не с чем.
    : > "$P/diff.txt"; : > "$P/changed.lst"; : > "$P/prune.lst"; : > "$P/extras.lst"
    : > "$P/conflict.lst"; : > "$P/missing.lst"; : > "$P/backup.lst"
    awk -v F="$P/files" 'BEGIN { while ((getline l < F) > 0) fs[l] = 1 } ($0 in fs)' "$P/drift0.lst" > "$P/drift.lst"
    ds_info "  без сборки проверены только дрейф, место и окно; полная сверка — при реальном запуске"
  fi

  # 5. Проверки и отчёт.
  if [ -f "$P/nobuild" ]; then
    :
  elif [ -n "$prev" ] && [ "$mode" != adopt-verify ]; then
    ds_info "  изменения: +$(grep -c '^A' "$P/diff.txt" || true) ~$(grep -c '^M' "$P/diff.txt" || true) -$(wc -l < "$P/prune.lst" | tr -d ' ') файлов"
    if [ -n "$prev" ] && ds_git cat-file -e "$prev^{commit}" 2>/dev/null; then
      ds_git log --oneline --no-decorate "$prev..$sha" | head -n 15 | sed 's/^/      /'
    fi
    [ "$DS_VERBOSE" = 0 ] || _ds_show_list "файлы" "$P/diff.txt"
  fi
  awk -v N="$P/new.man" 'BEGIN { while ((getline l < N) > 0) nh[substr(l, 67)] = substr(l, 1, 64) }
    { p = substr($0, 67); if ((p in nh) && nh[p] != substr($0, 1, 64)) print p }' "$P/srvman.rel" > "$P/mismatch.lst"
  case "$mode" in
    deploy|rollback)
      if [ -z "$prev" ]; then
        ds_info "  сверка сервера с ${sha:0:9} (для плана миграции):"
        _ds_show_list "нет на сервере" "$P/missing.lst"
        _ds_show_list "отличаются от коммита" "$P/mismatch.lst"
        _ds_show_list "лишние (не из git и не в DS_PRESERVE)" "$P/extras.lst"
      elif [ -s "$P/drift.lst" ] || [ -s "$P/conflict.lst" ]; then
        _ds_show_list "ДРЕЙФ: изменены на сервере вручную" "$P/drift.lst"
        _ds_show_list "КОНФЛИКТ: на сервере уже лежит другой файл с тем же именем" "$P/conflict.lst"
        if [ -n "$DS_OVERWRITE_DRIFT" ]; then
          ds_warn "$t: файлы будут перезаписаны (копия — в ${DS_MARKER_DIR}/backup-*.tgz): $DS_OVERWRITE_DRIFT"
        else
          _ds_block "$t: на сервере есть ручные правки — сначала перенесите их в git через PR или верните; осознанная перезапись: --overwrite-drift \"причина\""
        fi
      fi ;;
    adopt-verify)
      _ds_show_list "нет на сервере" "$P/missing.lst"
      _ds_show_list "отличаются от коммита" "$P/mismatch.lst"
      _ds_show_list "лишние (не из git и не в DS_PRESERVE)" "$P/extras.lst"
      if [ -s "$P/missing.lst" ] || [ -s "$P/mismatch.lst" ]; then
        if [ -n "$DS_OVERWRITE_DRIFT" ]; then
          # Осознанная миграция с заменой (например, CRLF → LF): файлы из git
          # перезаписываются, отличающиеся сохраняются в backup-*.tgz, дальше —
          # обычная выкатка с перезапуском (нужно окно).
          mode=adopt-replace
          ds_warn "$t: миграция с заменой отличающихся файлов из git (копия — в ${DS_MARKER_DIR}/backup-*.tgz): $DS_OVERWRITE_DRIFT"
        else
          _ds_block "$t: сервер не совпадает с ${sha:0:9} — маркер ставится только на точное совпадение; замена файлов из git: --adopt --overwrite-drift \"причина\" (см. план миграции в DEPLOY.md)"
        fi
      fi
      if [ -s "$P/extras.lst" ] && [ -z "$DS_OVERWRITE_DRIFT" ]; then
        _ds_block "$t: на сервере лишние файлы — перенесите в архив или добавьте в DS_PRESERVE (или --overwrite-drift \"причина\": они останутся нетронутыми)"
      fi
      if [ "$(cat "$P/git")" = yes ]; then
        if [ -z "$DS_OVERWRITE_DRIFT" ]; then _ds_block "$t: сначала перенесите $DS_DIR/.git в архив (план миграции)"; fi
      fi ;;
    adopt-replace)
      ds_info "  первая выкатка без маркера: будет записано файлов $(wc -l < "$P/new.paths" | tr -d ' ')"
      _ds_show_list "будут перезаписаны (отличаются)" "$P/conflict.lst" ;;
  esac
  if [ "$mode" != adopt-verify ] && [ -n "$prev" ]; then
    _ds_show_list "чужие файлы на сервере (не трогаются)" "$P/extras.lst"
    [ ! -s "$P/prune.lst" ] || [ "$DS_VERBOSE" = 1 ] || _ds_show_list "будут удалены (убраны из git)" "$P/prune.lst"
  fi
  # Место на диске.
  free=$(head -n 1 "$P/free")
  if [ "$mode" != adopt-verify ]; then
    if [[ ! $free =~ ^[0-9]+$ ]]; then
      _ds_block "$t: не удалось узнать свободное место на сервере"
    elif [ "$free" -lt "$DS_MIN_FREE_MB" ]; then
      _ds_block "$t: на сервере свободно $free МБ, нужно не меньше $DS_MIN_FREE_MB (DS_MIN_FREE_MB) — сначала освободите место"
    else
      ds_info "  свободно на сервере: $free МБ (минимум $DS_MIN_FREE_MB)"
    fi
  fi
  # Окно выкатки.
  now=$(date -u +%s); rc=0
  _ds_in_window "$DS_WINDOW" "$now" || rc=$?
  if [ "$rc" = 2 ]; then
    _ds_block "$t: ошибка в DS_WINDOW «$DS_WINDOW»"
  elif [ "$mode" = adopt-verify ]; then
    :
  elif [ "$rc" = 0 ]; then
    ds_info "  окно: $DS_WINDOW — сейчас $(_ds_msk_now), в окне"
  elif [ -n "$DS_IGNORE_WINDOW" ]; then
    ds_warn "$t: вне окна ($DS_WINDOW, сейчас $(_ds_msk_now)) — выкатываю по флагу: $DS_IGNORE_WINDOW"
  else
    _ds_block "$t: сейчас $(_ds_msk_now) — вне разрешённого окна «$DS_WINDOW»"
  fi
  if [ "$mode" != adopt-verify ]; then
    if declare -F "ds_${t}_remote_post" >/dev/null; then
      ds_info "  после распаковки: ds_${t}_remote_post (сборка/перезапуск — см. scripts/deploy.sh)"
    else
      ds_info "  после распаковки: ничего не перезапускается"
    fi
  fi
  printf 'DS_P_SHA=%q\nDS_P_PREV=%q\nDS_P_MODE=%q\n' "$sha" "$prev" "$mode" > "$P/plan.env"
  return 0
}

# ---------------------------------------------------------------------------
# Выкатка цели: пакет (ctl/ + payload.tar) → ОДНА SSH-сессия → run.sh
# ---------------------------------------------------------------------------
_ds_vars_script() {
  local f v
  declare -p DS_ENV DS_TARGET DS_SHA DS_EXPECT_PREV DS_DIR DS_SUDO DS_CHOWN \
    DS_MARKER_DIR DS_MIN_FREE_MB DS_MODE DS_OPERATOR DS_REMOTE_LOCK
  printf 'DS_REPO=%q\nDS_LIB_VERSION=%q\n' "$DS_GH_REPO" "$DS_DEPLOY_LIB_VERSION"
  for v in "${DS_EXPORT[@]}"; do declare -p "$v"; done
  declare -f _ds_glob_re ds_changed
  for f in $(compgen -A function | grep -E "^ds_(${DS_TARGET}_remote_|remote_)" || true); do
    declare -f "$f"
  done
}

_ds_runner_script() {
  cat <<'DS_RUNNER_EOF'
# ds-deploy: исполняется на сервере в одной SSH-сессии, под общим локом.
set -euo pipefail
S=$1
. "$S/ctl/vars.sh"
SUDO=""; if [ "$DS_SUDO" = 1 ]; then SUDO="sudo -n"; fi
DS_SUDO_CMD=$SUDO
DS_PREV_SHA=$DS_EXPECT_PREV
DS_CHANGED_FILE="$S/ctl/CHANGED"
export DS_SUDO_CMD DS_PREV_SHA DS_CHANGED_FILE
M=$DS_MARKER_DIR
_lockdir=""
_cleanup() { if [ -n "$_lockdir" ]; then rmdir "$_lockdir" 2>/dev/null || true; fi; rm -rf -- "$S"; }
trap _cleanup EXIT
say() { printf '  [сервер] %s\n' "$*"; }
ds_retry() {  # <попыток> <пауза, с> <команда...>
  local n=$1 d=$2 i; shift 2
  for ((i = 1; i <= n; i++)); do if "$@"; then return 0; fi; sleep "$d"; done
  return 1
}
_abs() { awk -v p="$DS_DIR/" '{ print p $0 }' "$1"; }
_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_write_deployed() {
  printf 'sha=%s\nprev=%s\nresult=%s\nmode=%s\nutc=%s\noperator=%s\nrepo=%s\nenv=%s\ntarget=%s\nlib=%s\n' \
    "$DS_SHA" "$DS_EXPECT_PREV" "$1" "$DS_MODE" "$(_utc)" "$DS_OPERATOR" "$DS_REPO" "$DS_ENV" "$DS_TARGET" "$DS_LIB_VERSION" \
    | $SUDO tee "$M/DEPLOYED.new" >/dev/null
  $SUDO mv -f "$M/DEPLOYED.new" "$M/DEPLOYED"
}
_history() {
  { $SUDO cat "$M/history" 2>/dev/null || true
    printf '%s\t%s\t%s\t%s\t%s\n' "$(_utc)" "$DS_SHA" "$1" "$DS_OPERATOR" "$DS_MODE"; } \
    | tail -n 50 | $SUDO tee "$M/history.new" >/dev/null
  $SUDO mv -f "$M/history.new" "$M/history"
}
_hook() {  # вызывать только как отдельную команду (не в if/&&/||): иначе set -e в хуке не работает
  local fn="ds_${DS_TARGET}_remote_$1" rc
  declare -F "$fn" >/dev/null || return 0
  say "шаг $1: $fn"
  (set -e; cd "$DS_DIR" 2>/dev/null || cd /; "$fn")
  rc=$?
  return "$rc"
}

# Общий лок всех проектов на этом сервере.
if command -v flock >/dev/null 2>&1; then
  if [ ! -e "$DS_REMOTE_LOCK" ]; then (umask 000; : >> "$DS_REMOTE_LOCK") 2>/dev/null || true; fi
  exec 9<"$DS_REMOTE_LOCK"
  if ! flock -n 9; then
    say "на сервере идёт другая выкатка — жду до 15 минут"
    flock -w 900 9 || { echo "лок $DS_REMOTE_LOCK не освободился за 15 минут" >&2; exit 23; }
  fi
else
  _t=0
  until mkdir "$DS_REMOTE_LOCK.d" 2>/dev/null; do
    _t=$((_t + 1)); [ "$_t" -lt 900 ] || { echo "лок $DS_REMOTE_LOCK.d занят" >&2; exit 23; }; sleep 1
  done
  _lockdir="$DS_REMOTE_LOCK.d"
fi

# Маркер не изменился с момента проверки.
cur=""
if $SUDO test -f "$M/DEPLOYED"; then cur=$($SUDO sed -n 's/^sha=//p' "$M/DEPLOYED"); fi
if [ "$cur" != "$DS_EXPECT_PREV" ]; then
  echo "маркер изменился с момента проверки: ожидали «${DS_EXPECT_PREV:-нет}», на сервере «${cur:-нет}»" >&2
  exit 21
fi

if [ "$DS_MODE" = adopt-verify ]; then
  if ! awk -v p="$DS_DIR/" '{ print substr($0, 1, 64) "  " p substr($0, 67) }' "$S/ctl/MANIFEST" \
       | $SUDO sha256sum -c --quiet - >/dev/null 2>&1; then
    echo "файлы на сервере изменились с момента проверки" >&2
    exit 20
  fi
  $SUDO mkdir -p "$M"
  $SUDO cp "$S/ctl/MANIFEST" "$M/MANIFEST.new"; $SUDO mv -f "$M/MANIFEST.new" "$M/MANIFEST"
  _write_deployed adopted
  _history adopted
  say "маркер поставлен: $DS_SHA (ничего не перезаписано и не перезапущено)"
  exit 0
fi

# Новые расхождения с момента проверки → отказ.
if $SUDO test -f "$M/MANIFEST"; then
  now_fail=$($SUDO cat "$M/MANIFEST" | awk -v p="$DS_DIR/" '{ print substr($0, 1, 64) "  " p substr($0, 67) }' \
    | $SUDO sha256sum -c --quiet - 2>/dev/null \
    | awk -v p="$DS_DIR/" 'index($0, p) == 1 { s = substr($0, length(p) + 1); sub(/: FAILED( open or read)?$/, "", s); print s }' \
    | LC_ALL=C sort -u || true)
  new_fail=$(printf '%s\n' "$now_fail" | sed '/^$/d' | LC_ALL=C comm -23 - "$S/ctl/DRIFT0" || true)
  if [ -n "$new_fail" ]; then
    echo "с момента проверки на сервере изменились файлы:" >&2
    printf '%s\n' "$new_fail" >&2
    exit 20
  fi
fi

# Место на диске.
d=$DS_DIR; while [ "$d" != / ] && ! $SUDO test -d "$d"; do d=$(dirname "$d"); done
free=$($SUDO df -Pm "$d" | awk 'NR == 2 { print $4 }')
if [ "${free:-0}" -lt "$DS_MIN_FREE_MB" ]; then
  echo "свободно $free МБ, нужно $DS_MIN_FREE_MB" >&2
  exit 24
fi

set +e; _hook pre; rc=$?; set -e
if [ "$rc" != 0 ]; then echo "шаг pre упал (код $rc) — файлы не менялись" >&2; exit 30; fi

$SUDO mkdir -p "$DS_DIR" "$M"
if [ -s "$S/ctl/BACKUP" ]; then
  bk="$M/backup-$(date -u +%Y%m%dT%H%M%SZ).tgz"
  $SUDO tar -czf "$bk" -C "$DS_DIR" -T "$S/ctl/BACKUP"
  say "копия файлов с ручными правками: $bk"
fi
_write_deployed pending
# Распаковка поверх: --overwrite пишет в существующий файл (inode сохраняется),
# поэтому одиночные bind-маунты (Caddyfile, config.toml) видят новое содержимое.
# Никаких mv/rename для файлов проекта.
$SUDO tar -x --overwrite --no-same-owner -f "$S/payload.tar" -C "$DS_DIR"
if [ -n "$DS_CHOWN" ]; then
  awk -v p="$DS_DIR/" '{ print p $0; n = split($0, a, "/"); d = ""
       for (i = 1; i < n; i++) { d = d (i > 1 ? "/" : "") a[i]; print p d } }' "$S/ctl/PATHS" \
    | LC_ALL=C sort -u | tr '\n' '\0' | $SUDO xargs -0 -r chown -h -- "$DS_CHOWN"
fi
if [ -s "$S/ctl/PRUNE" ]; then
  _abs "$S/ctl/PRUNE" | tr '\n' '\0' | $SUDO xargs -0 -r rm -f --
  say "удалено убранных из git файлов: $(wc -l < "$S/ctl/PRUNE" | tr -d ' ')"
fi
$SUDO cp "$S/ctl/MANIFEST" "$M/MANIFEST.new"; $SUDO mv -f "$M/MANIFEST.new" "$M/MANIFEST"
say "файлы выложены: $DS_SHA"

set +e; _hook post; rc=$?; set -e
if [ "$rc" != 0 ]; then _write_deployed post-failed; _history post-failed; echo "шаг post упал (код $rc)" >&2; exit 31; fi
set +e; _hook health; rc=$?; set -e
if [ "$rc" != 0 ]; then _write_deployed health-failed; _history health-failed; echo "проверка здоровья не прошла (код $rc)" >&2; exit 32; fi
_write_deployed ok
_history ok
say "готово: $DS_SHA"
DS_RUNNER_EOF
}

_ds_apply_target() {  # <цель>; возвращает код для журнала
  local t=$1 P="$_DS_W/$1" rc desc
  _ds_load_target "$t"
  # shellcheck disable=SC1091
  . "$P/plan.env"
  DS_SHA=$DS_P_SHA; DS_EXPECT_PREV=$DS_P_PREV; DS_MODE=$DS_P_MODE
  mkdir -p "$P/pkg/ctl"
  cp "$P/new.man" "$P/pkg/ctl/MANIFEST"
  cp "$P/new.paths" "$P/pkg/ctl/PATHS"
  cp "$P/prune.lst" "$P/pkg/ctl/PRUNE"
  cp "$P/changed.lst" "$P/pkg/ctl/CHANGED"
  cp "$P/drift0.lst" "$P/pkg/ctl/DRIFT0"
  if [ -n "$DS_OVERWRITE_DRIFT" ]; then cp "$P/backup.lst" "$P/pkg/ctl/BACKUP"; else : > "$P/pkg/ctl/BACKUP"; fi
  if [ -f "$P/payload.tar" ]; then cp "$P/payload.tar" "$P/pkg/payload.tar"; else tar -cf "$P/pkg/payload.tar" -T /dev/null; fi
  _ds_runner_script > "$P/pkg/ctl/run.sh"
  _ds_vars_script > "$P/pkg/ctl/vars.sh"
  (cd "$P/pkg" && tar -cf "$P/package.tar" ctl payload.tar)
  if [ "$DS_HOST" = local ]; then desc="$DS_MODE ${DS_SHA:0:9} → $DS_DIR"; else desc="$DS_MODE ${DS_SHA:0:9} → $DS_USER@$DS_HOST:$DS_DIR"; fi
  set +e
  ds_run "$desc" _ds_transport_apply "$P/package.tar"
  rc=$?
  set -e
  _DS_APPLY_RC=$rc
  return 0
}

# ---------------------------------------------------------------------------
# Журнал на ПК, лок на ПК, оператор
# ---------------------------------------------------------------------------
_ds_operator() {
  local who
  if [ "${GITHUB_ACTIONS:-}" = true ]; then
    printf 'github-actions:%s' "${GITHUB_ACTOR:-?}"
    return 0
  fi
  who="${USER:-${USERNAME:-$(whoami 2>/dev/null || echo '?')}}@$(hostname 2>/dev/null || echo pc)"
  if [ "${CLAUDECODE:-}" = 1 ]; then who="claude-code($who)"; fi
  printf '%s' "$who"
}
_ds_journal() {  # <цель> <sha> <итог>
  local flags=""
  [ "$DS_DRY" = 0 ] || flags+="dry-run "
  [ -z "$DS_SKIP_CI" ] || flags+="skip-ci=«$DS_SKIP_CI» "
  [ "$DS_CI_FROM_NEEDS" = 0 ] || flags+="ci-from-needs "
  [ -z "$DS_IGNORE_WINDOW" ] || flags+="ignore-window=«$DS_IGNORE_WINDOW» "
  [ -z "$DS_OVERWRITE_DRIFT" ] || flags+="overwrite-drift=«$DS_OVERWRITE_DRIFT» "
  [ "$DS_ADOPT" = 0 ] || flags+="adopt "
  [ "$DS_ROLLBACK" = 0 ] || flags+="rollback "
  mkdir -p "$DS_STATE_DIR" 2>/dev/null || return 0
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$DS_REPO_NAME" "$DS_ENV" "$1" "$2" "$3" \
    "$DS_OPERATOR" "$(printf '%s' "$flags" | tr '\t\n' '  ')" >> "$DS_STATE_DIR/deploy.log" || true
}
_ds_lock_local() {
  _DS_LOCAL_LOCK="$DS_STATE_DIR/lock-$DS_REPO_NAME.d"
  mkdir -p "$DS_STATE_DIR"
  if ! mkdir "$_DS_LOCAL_LOCK" 2>/dev/null; then
    _DS_LOCAL_LOCK=""
    _DS_DIE_CODE=3 ds_die "уже идёт выкатка $DS_REPO_NAME с этого ПК ($DS_STATE_DIR/lock-$DS_REPO_NAME.d, $(cat "$DS_STATE_DIR/lock-$DS_REPO_NAME.d/info" 2>/dev/null || echo '?')). Если точно не идёт — удалите этот каталог."
  fi
  printf '%s %s pid %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$DS_OPERATOR" "$$" > "$_DS_LOCAL_LOCK/info"
}
_ds_cleanup() {
  if [ -n "${_DS_LOCAL_LOCK:-}" ]; then rm -rf -- "$_DS_LOCAL_LOCK"; fi
  if [ -n "${_DS_W:-}" ]; then rm -rf -- "$_DS_W"; fi
  case "${DS_REEXEC_DIR:-}" in */ds-deploy.*) rm -rf -- "$DS_REEXEC_DIR" ;; esac
}

# ---------------------------------------------------------------------------
# Точка входа: scripts/deploy.sh вызывает `ds_main "$@"` в конце.
# ---------------------------------------------------------------------------
ds_main() {
  set -euo pipefail
  local t tip rc code=0 failed="" all ok
  _ds_parse_args "$@"
  _ds_init_repo
  if [ -z "${DS_REEXEC:-}" ]; then
    _ds_reexec "$@"   # не возвращается
  fi
  _ds_verify_reexec
  _DS_W=""; _DS_LOCAL_LOCK=""
  trap _ds_cleanup EXIT
  trap 'exit 130' INT TERM
  DS_STATE_DIR=${DS_STATE_DIR:-$HOME/.delta-deploy}
  DS_OPERATOR=$(_ds_operator)

  declare -F ds_config >/dev/null || ds_die "в scripts/deploy.sh нет функции ds_config"
  DS_TARGETS=""; DS_OPTIONAL_TARGETS=""; DS_NO_DEPLOY=""; DS_WINDOW=""; DS_MIN_FREE_MB=3000
  ds_config
  if [ -n "$DS_NO_DEPLOY" ]; then
    ds_info "Деплоя нет: $DS_NO_DEPLOY"
    exit 2
  fi
  _DS_ENV_WINDOW=$DS_WINDOW; _DS_ENV_MIN_FREE=$DS_MIN_FREE_MB
  [ -n "$DS_TARGETS" ] || _DS_DIE_CODE=2 ds_die "для окружения $DS_ENV в проекте нет целей (DS_TARGETS)"
  if [ "${#DS_ONLY[@]}" -gt 0 ]; then
    all=" $DS_TARGETS $DS_OPTIONAL_TARGETS "
    for t in "${DS_ONLY[@]}"; do
      [[ $all == *" $t "* ]] || _ds_usage_die "нет цели «$t» (есть: $DS_TARGETS $DS_OPTIONAL_TARGETS)"
    done
    _DS_SEL=("${DS_ONLY[@]}")
  else
    read -r -a _DS_SEL <<< "$DS_TARGETS"
  fi

  ds_info "════ $DS_GH_REPO → $DS_ENV   (ds-deploy $DS_DEPLOY_LIB_VERSION)"
  ds_info "  источник: origin/$DS_BRANCH = $(ds_git log -1 --format='%h %ad %s' --date=short "$DS_REEXEC")"
  ds_info "  логика выкатки — из этого же коммита; рабочая копия не используется"
  if [ -n "$DS_TEST_REF" ]; then
    ds_info "  ПРОВЕРКА ВЕТКИ $DS_TEST_REF (--test-ref): только чтение, выкатывать отсюда нельзя"
  fi
  ds_info "  оператор: $DS_OPERATOR$([ "$DS_DRY" = 1 ] && printf '   РЕЖИМ: --dry-run (сервер не меняется)')"

  if [ "$DS_CI_FROM_NEEDS" = 1 ] && [ "$DS_REEXEC" != "${GITHUB_SHA:-}" ]; then
    ds_info "origin/$DS_BRANCH ушла вперёд (${DS_REEXEC:0:9} ≠ ${GITHUB_SHA:-?}) — выкатит следующий прогон"
    exit 0
  fi
  if [ "$DS_DRY" = 0 ]; then _ds_lock_local; fi
  _DS_W=$(_ds_mktemp ds-deploy-work)

  if [ "$DS_ROLLBACK" = 0 ] && [ -z "$DS_ADOPT_SHA" ]; then _ds_ci_gate "$DS_REEXEC"; fi
  for t in "${_DS_SEL[@]}"; do
    _ds_plan_target "$t"
  done

  ds_info ""
  if [ "${#_DS_REFUSALS[@]}" -gt 0 ]; then
    ds_info "════ ОТКАЗ: выкатка не начиналась, на сервере ничего не менялось"
    printf '  - %s\n' "${_DS_REFUSALS[@]}"
    for t in "${_DS_SEL[@]}"; do _ds_journal "$t" "$DS_REEXEC" "refused"; done
    exit 3
  fi
  if [ "$DS_DRY" = 1 ]; then
    for t in "${_DS_SEL[@]}"; do _ds_apply_target "$t"; _ds_journal "$t" "$DS_REEXEC" "dry-run-ok"; done
    ds_info "════ dry-run: проверки пройдены, реальная выкатка сейчас была бы разрешена"
    exit 0
  fi

  if [ "$DS_ENV" = prod ] && [ "$DS_YES" = 0 ]; then
    [ -t 0 ] || _DS_DIE_CODE=3 ds_die "нет терминала для подтверждения. Владелец запускает сам; Claude добавляет --yes только по прямой просьбе владельца"
    printf 'Выкатить на ПРОД? Для подтверждения введите имя репозитория (%s): ' "$DS_REPO_NAME"
    read -r ok
    if [ "$ok" != "$DS_REPO_NAME" ]; then
      for t in "${_DS_SEL[@]}"; do _ds_journal "$t" "$DS_REEXEC" "cancelled"; done
      _DS_DIE_CODE=3 ds_die "не подтверждено — ничего не выкачено"
    fi
  fi

  for t in "${_DS_SEL[@]}"; do
    _ds_apply_target "$t"
    rc=$_DS_APPLY_RC
    case "$rc" in
      0)
        if declare -F "ds_${t}_health" >/dev/null; then
          set +e; (set -e; "ds_${t}_health"); rc=$?; set -e
          if [ "$rc" != 0 ]; then
            ds_warn "$t: проверка здоровья с ПК (ds_${t}_health) не прошла"
            _ds_journal "$t" "$DS_SHA" "health-failed(pc)"; code=5; failed="$t"; break
          fi
        fi
        if [ "$DS_MODE" = adopt-verify ]; then
          _ds_journal "$t" "$DS_SHA" "adopted"
          ds_info "✓ $t: маркер поставлен на ${DS_SHA:0:9} (файлы и сервисы не трогались)"
        else
          _ds_journal "$t" "$DS_SHA" "ok"
          ds_info "✓ $t: выкачено ${DS_SHA:0:9}"
        fi ;;
      20|21|23|24|30)
        _ds_journal "$t" "$DS_SHA" "refused-remote($rc)"
        ds_warn "$t: сервер отказал (код $rc) — файлы не менялись"; code=3; failed="$t"; break ;;
      32)
        _ds_journal "$t" "$DS_SHA" "health-failed"
        ds_warn "$t: код выложен, но проверка здоровья не прошла"; code=5; failed="$t"; break ;;
      *)
        _ds_journal "$t" "$DS_SHA" "failed($rc)"
        ds_warn "$t: сбой во время выкатки (код $rc) — состояние может быть частичным"; code=4; failed="$t"; break ;;
    esac
  done
  if [ "$code" != 0 ]; then
    ds_info ""
    ds_info "════ НЕ ГОТОВО (цель $failed). Что делать — DEPLOY_STANDARD.md, «Если выкатка не удалась»:"
    ds_info "  1) scripts/deploy.sh $DS_ENV --dry-run — посмотреть состояние;"
    ds_info "  2) откат: scripts/deploy.sh $DS_ENV --rollback${DS_ONLY:+ --only $failed}  (или revert-PR и обычная выкатка)"
    exit "$code"
  fi
  ds_info "════ готово: $DS_GH_REPO $DS_ENV"
  exit 0
}
