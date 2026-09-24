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
#   * на сервере ведётся маркер .ds-deploy/ (DEPLOYED, MANIFEST, MANIFEST.ok,
#     history): без маркера реальная выкатка отказывает (нужна разовая
#     миграция), ручные правки файлов (дрейф) — отказ со списком файлов;
#   * на сервер записываются только файлы, которые отличаются от выкатанных
#     (остальные не трогаются: сохраняются inode, время и права); бит
#     исполнения, снятый в git, у существующих файлов восстанавливается;
#   * окно выкатки проверяется и на ПК, и на сервере прямо перед шагом pre;
#   * все ИЗМЕНЯЮЩИЕ удалённые действия идут только через ds_run (в --dry-run
#     она лишь печатает), все ЧТЕНИЯ с сервера — только через ds_probe;
#   * обрыв SSH посреди выкатки не убивает её на сервере: вывод раннера идёт
#     через tee в журнал /tmp/ds-deploy.*.log (при сбое он остаётся).
#
# Работает в Git Bash на Windows (ПК владельца) и в Linux (GitHub Actions).
# Совместима с `set -euo pipefail`. Секреты не читает и не печатает: set -x
# выключается, .env и похожие на секреты файлы не выкатываются и не хэшируются.
# =============================================================================

DS_DEPLOY_LIB_VERSION=1.2.0

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
# Исключение: имена, оканчивающиеся на .example. Файл из git, похожий на
# секрет, — отказ выкатки (утечка или ложное срабатывание — решает человек):
# убрать из git, внести в DS_PRESERVE (не выкатывать) или в
# DS_DEPLOY_SECRETLIKE (это не секрет — выкатывать).
DS_SECRET_PATTERNS=(
  '**/.env' '**/.env.*' '**/*.pem' '**/*.key' '**/*.p12' '**/*.pfx'
  '**/id_rsa*' '**/id_ed25519*' '**/id_ecdsa*' '**/auth*.ini'
  '**/credentials' '**/credentials.json' '**/credentials.ini' '**/credentials.y*ml'
)
DS_FILES_LIMIT=50000           # больше файлов в каталоге цели — отказ (DS_PRESERVE)

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
                            (ci у него не нужен, пока файлы не перезаписываются)
  --rollback                вернуть предыдущий успешно выкатанный коммит
                            (ci не нужен, если маркер на нём ставился --adopt)
  --test-ref <ветка>        ТОЛЬКО с --dry-run: проверить ветку PR (логика и
                            файлы из origin/<ветка>) против сервера до мержа
  -h, --help                эта справка

В --dry-run цели со сборкой (ds_<цель>_build) собираются на ПК во временном
каталоге — так видно, какие файлы изменятся; сервер не меняется. Проектная
проверка ds_<цель>_remote_check (только чтение) выполняется и в --dry-run.

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
# Список $DS_CHANGED_FILE: по пути в строке, от корня ЦЕЛИ (при DS_SUBDIR — от
# подкаталога), включая удалённые из git файлы; при первой выкатке — все файлы;
# после неуспешной прошлой выкатки — всё, что изменилось с последней успешной.
ds_changed() {
  local re="" p
  for p in "$@"; do re+="${re:+|}($(_ds_glob_re "$p"))"; done
  [ -n "$re" ] || return 1
  grep -Eq -- "$re" "$DS_CHANGED_FILE"
}

_ds_build_patterns() {
  local p re="" r ed
  for p in "${DS_PRESERVE[@]}"; do re+="${re:+|}($(_ds_glob_re "$p"))"; done
  if [ "${DS_MARKER_DIR#"$DS_DIR"/}" != "$DS_MARKER_DIR" ]; then
    re+="${re:+|}($(_ds_glob_re "${DS_MARKER_DIR#"$DS_DIR"/}/"))"
  fi
  _DS_USER_RE=$re
  re=""
  for p in "${DS_SECRET_PATTERNS[@]}"; do re+="${re:+|}($(_ds_glob_re "$p"))"; done
  _DS_SECRET_RE=$re
  re=""
  for p in "${DS_DEPLOY_SECRETLIKE[@]}"; do re+="${re:+|}($(_ds_glob_re "$p"))"; done
  _DS_ALLOW_RE=$re
  # Каталоги из DS_PRESERVE find на сервере не обходит (node_modules, data...):
  # без масок — по пути (-path), с масками — по тому же регулярному выражению,
  # что и на ПК (-regex), чтобы не отсечь лишнего.
  _DS_PRUNE_DIRS=(.git); _DS_PRUNE_RES=()
  ed=$(printf '%s' "$DS_DIR" | sed 's/[][\\.^$*+?(){}|]/\\&/g')
  for p in "${DS_PRESERVE[@]}"; do
    case "$p" in
      */) ;;
      *) continue ;;
    esac
    case "$p" in
      *'*'*|*'?'*|*'['*)
        r=$(_ds_glob_re "${p%/}"); _DS_PRUNE_RES+=("$ed/${r#^}") ;;
      *) _DS_PRUNE_DIRS+=("${p%/}") ;;
    esac
  done
  if [ "${DS_MARKER_DIR#"$DS_DIR"/}" != "$DS_MARKER_DIR" ]; then
    _DS_PRUNE_DIRS+=("${DS_MARKER_DIR#"$DS_DIR"/}")
  fi
}

# stdin: относительные пути → stdout: те, что сохраняются (не выкатываются и
# не трогаются): DS_PRESERVE, маркер, похожие на секреты (кроме *.example и
# DS_DEPLOY_SECRETLIKE).
_ds_kept() {
  DS_U="$_DS_USER_RE" DS_S="$_DS_SECRET_RE" DS_A="$_DS_ALLOW_RE" awk '
    (ENVIRON["DS_U"] != "" && $0 ~ ENVIRON["DS_U"]) ||
    ($0 ~ ENVIRON["DS_S"] && $0 !~ /\.example$/ && (ENVIRON["DS_A"] == "" || $0 !~ ENVIRON["DS_A"]))'
}
_ds_not_kept() {
  DS_U="$_DS_USER_RE" DS_S="$_DS_SECRET_RE" DS_A="$_DS_ALLOW_RE" awk '
    !((ENVIRON["DS_U"] != "" && $0 ~ ENVIRON["DS_U"]) ||
      ($0 ~ ENVIRON["DS_S"] && $0 !~ /\.example$/ && (ENVIRON["DS_A"] == "" || $0 !~ ENVIRON["DS_A"])))'
}
# stdin: пути → stdout: похожие на секрет и НЕ покрытые DS_PRESERVE/DS_DEPLOY_SECRETLIKE.
_ds_secretlike() {
  DS_U="$_DS_USER_RE" DS_S="$_DS_SECRET_RE" DS_A="$_DS_ALLOW_RE" awk '
    $0 ~ ENVIRON["DS_S"] && $0 !~ /\.example$/ &&
    (ENVIRON["DS_A"] == "" || $0 !~ ENVIRON["DS_A"]) &&
    (ENVIRON["DS_U"] == "" || $0 !~ ENVIRON["DS_U"])'
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
  # Полигон есть только там, где есть develop. Без неё — «деплоя нет» (код 2),
  # а не ошибка git fetch. Код 2 от ls-remote — «ветки нет»; сбой сети — дальше.
  if [ "$DS_ENV" = staging ] && [ -z "$DS_TEST_REF" ]; then
    local rc=0
    ds_git ls-remote --exit-code --heads origin develop >/dev/null 2>&1 || rc=$?
    if [ "$rc" = 2 ]; then
      ds_info "Деплоя нет: у проекта нет полигона (на origin нет ветки develop)"
      exit 2
    fi
  fi
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
  # Раннер пишет не в SSH-сокет, а в tee (SIGPIPE у tee игнорируется): если
  # связь оборвётся, tee продолжит писать в журнал $d.log, а раннер и его шаги
  # (сборка, systemctl) доработают до конца — без обрыва между pre и post.
  # Код раннера — в $d.rc. Журнал удаляется только при успехе, дошедшем до ПК
  # (tee не получил ошибку записи); при сбое или обрыве связи он остаётся.
  # Одна строка без $'…': логин-оболочка на сервере может быть не bash.
  # umask 077 — только для журнала: у раннера umask прежний (от него зависят
  # права выкатываемых файлов, если выкатка идёт без sudo).
  # shellcheck disable=SC2016  # $d раскрывается на сервере
  cmd='d=$(mktemp -d /tmp/ds-deploy.XXXXXX) || exit 97; (umask 077; : > "$d.log"; : > "$d.rc") || exit 97; tar -x -C "$d" -f - || exit 97; { bash "$d/ctl/run.sh" "$d" </dev/null 2>&1; echo "$?" > "$d.rc"; } | { trap "" PIPE; tee -a "$d.log"; }; trc=$?; rc=$(cat "$d.rc" 2>/dev/null); [ -n "$rc" ] || rc=98; if [ "$rc" = 0 ] && [ "$trc" = 0 ]; then rm -f -- "$d.log" "$d.rc"; fi; exit "$rc"'
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
  declare -p DS_DIR DS_SUDO DS_MARKER_DIR _DS_PRUNE_DIRS _DS_PRUNE_RES DS_FILES_LIMIT
  cat <<'EOF'
SUDO=""; if [ "$DS_SUDO" = 1 ]; then SUDO="sudo -n"; fi
M=$DS_MARKER_DIR
echo "@@SUDO"; if [ -n "$SUDO" ] && ! $SUDO true 2>/dev/null; then echo fail; else echo ok; fi
echo "@@DIREXISTS"; if $SUDO test -d "$DS_DIR"; then echo yes; else echo no; fi
echo "@@DEPLOYED"; $SUDO cat "$M/DEPLOYED" 2>/dev/null || true
echo "@@HISTORY"; $SUDO tail -n 50 "$M/history" 2>/dev/null || true
echo "@@OLDMAN"; $SUDO cat "$M/MANIFEST" 2>/dev/null || true
echo "@@OKFLAG"; if $SUDO test -f "$M/MANIFEST.ok"; then echo yes; else echo no; fi
echo "@@OKMAN"; $SUDO cat "$M/MANIFEST.ok" 2>/dev/null || true
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
  for p in "${_DS_PRUNE_RES[@]}"; do args+=(-o "(" -type d -regex "$p" ")"); done
  $SUDO find "$DS_DIR" -xdev -regextype posix-extended \( "${args[@]}" \) -prune -o -type f -printf '%P\n' 2>/dev/null \
    | head -n "$((DS_FILES_LIMIT + 1))" | LC_ALL=C sort || true
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
  DS_PRESERVE=(); DS_EXPORT=(); DS_DEPLOY_SECRETLIKE=()
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
  # Маркер не должен быть виден из веба. /var/www/<логин>/data — домашний
  # каталог shared-хостинга (ISPmanager), веб-корни там — .../data/www/<сайт>.
  case "$DS_MARKER_DIR/" in
    */public_html/*|*/public/*|*/html/*|*/site/*|*/htdocs/*|*/wwwroot/*|*/data/www/*)
      ds_warn "цель $t: маркер $DS_MARKER_DIR, похоже, в веб-корне — задайте DS_MARKER_DIR вне него" ;;
    /var/www/*/data/*) ;;
    /var/www/*)
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
    # Сборка и в --dry-run: она локальная, во временном каталоге, сервер не
    # трогает — зато dry-run показывает настоящие изменения и сверку миграции.
    mkdir -p "$P/src"
    ds_git -c core.autocrlf=false -c core.eol=lf archive --format=tar "$sha" | tar -x -C "$P/src" -f -
    ds_info "  сборка ds_${DS_TARGET}_build из архива ${sha:0:9} (не из рабочей копии; на ПК)…"
    set +e
    (set -e; cd "$P/src"; "ds_${DS_TARGET}_build")
    rc=$?
    set -e
    [ "$rc" = 0 ] || { _ds_block "$DS_TARGET: сборка упала (код $rc)"; return 0; }
    out="$P/src/$DS_BUILD_OUT"
    [ -d "$out" ] || { _ds_block "$DS_TARGET: после сборки нет каталога $DS_BUILD_OUT"; return 0; }
    (cd "$out" && find . -type f -printf '%P\n' | LC_ALL=C sort) > "$P/built.lst"
    # Результат сборки проверяется так же, как файлы из git: похожее на секрет
    # (например .env.production, скопированный сборкой в out/) — отказ, а не
    # молчаливое исключение. Бит исполнения у результата сборки не проверяется:
    # на ПК с Windows (NTFS) его нет; скрипты для cron/systemd — цели из git.
    _ds_secretlike < "$P/built.lst" > "$P/secretlike.lst" || true
    if [ -s "$P/secretlike.lst" ]; then
      _ds_show_list "ФАЙЛЫ В РЕЗУЛЬТАТЕ СБОРКИ ($DS_BUILD_OUT) ПОХОЖИ НА СЕКРЕТ" "$P/secretlike.lst"
      _ds_block "$DS_TARGET: сборка положила в $DS_BUILD_OUT файлы, похожие на секрет — уберите их из результата сборки (ds_${DS_TARGET}_build), либо DS_PRESERVE (не выкатывать), либо DS_DEPLOY_SECRETLIKE (не секрет — выкатывать)"
      return 0
    fi
    _ds_kept < "$P/built.lst" > "$P/excluded.lst" || true
    (cd "$out" && tr '\n' '\0' < "$P/excluded.lst" | xargs -0 -r rm -f --)
    (cd "$out" && find . -type f -printf '%P\n' | LC_ALL=C sort | tar -cf "$P/payload.tar" -T -)
    _ds_manifest_of "$out" > "$P/new.man"
  else
    [ -z "$DS_SUBDIR" ] || tree="$sha:$DS_SUBDIR"
    ds_git -c core.autocrlf=false -c core.eol=lf archive --format=tar "$tree" > "$P/payload.tar" \
      || { _ds_block "$DS_TARGET: git archive $tree не удался"; return 0; }
    tar -tf "$P/payload.tar" | grep -v '/$' | LC_ALL=C sort > "$P/git.lst" || true
    # Файл из git, похожий на секрет: утечка или ложное срабатывание — решает человек.
    _ds_secretlike < "$P/git.lst" > "$P/secretlike.lst" || true
    if [ -s "$P/secretlike.lst" ]; then
      _ds_show_list "ФАЙЛЫ ИЗ GIT ПОХОЖИ НА СЕКРЕТ" "$P/secretlike.lst"
      _ds_block "$DS_TARGET: в git есть файлы, похожие на секрет — уберите их из git (если это секрет), либо DS_PRESERVE (не выкатывать), либо DS_DEPLOY_SECRETLIKE (не секрет — выкатывать)"
      return 0
    fi
    _ds_kept < "$P/git.lst" > "$P/excluded.lst" || true
    if [ -s "$P/excluded.lst" ]; then
      tar --delete -f "$P/payload.tar" -T "$P/excluded.lst"
    fi
    mkdir -p "$P/pl"
    tar -x -C "$P/pl" -f "$P/payload.tar"
    _ds_manifest_of "$P/pl" > "$P/new.man"
    # Скрипты без бита исполнения в git: на сервере у существующих файлов бит
    # восстанавливается, но новые файлы придут без него. Режим и путь — из
    # git ls-tree (путь целиком после табуляции: пробелы в именах не мешают).
    ds_git -c core.quotePath=false ls-tree -r "$tree" \
      | awk -v X="$P/excluded.lst" '
          BEGIN { while ((getline l < X) > 0) ex[l] = 1 }
          { i = index($0, "\t"); p = substr($0, i + 1); split(substr($0, 1, i - 1), m, " ") }
          m[1] == "100644" && p ~ /\.sh$/ && p !~ /^scripts\/(lib\/|deploy\.sh$)/ && !(p in ex) { print p }' \
      > "$P/noexec.lst" || true
    if [ -s "$P/noexec.lst" ]; then
      ds_warn "$DS_TARGET: .sh без бита исполнения в git ($(wc -l < "$P/noexec.lst" | tr -d ' ')): поставьте git update-index --chmod=+x <файл> (например «$(head -n 1 "$P/noexec.lst")»)"
    fi
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

_ds_man_diff() {  # <старый манифест> <новый манифест> → «A|M|D<TAB>путь»
  awk 'FILENAME == ARGV[1] { o[substr($0, 67)] = substr($0, 1, 64); next }
       { p = substr($0, 67); s[p] = 1
         if (!(p in o)) print "A\t" p; else if (o[p] != substr($0, 1, 64)) print "M\t" p }
       END { for (p in o) if (!(p in s)) print "D\t" p }' "$1" "$2" \
    | LC_ALL=C sort -t "$(printf '\t')" -k2
}

# Отказ «сервер не мигрирован» (DS_ADOPT_MODE=verify). Подсказка строится по
# сверке сервера с коммитом, чтобы сразу назвать команду, которая сработает.
_ds_block_unmigrated() {  # <цель> <каталог плана | пусто, если сверки нет>
  local t=$1 P=${2:-} only="" how
  if [ "${#_DS_SEL[@]}" -gt 1 ]; then only=" --only $t"; fi
  how="scripts/deploy.sh $DS_ENV$only --adopt"
  if [ -n "$P" ] && { [ -s "$P/missing.lst" ] || [ -s "$P/mismatch.lst" ]; }; then
    how+=" --overwrite-drift \"причина\" (файлы сервера отличаются от git: они заменятся из git, копия — в backup-*.tgz; это выкатка с перезапуском — в окно)"
  elif [ -n "$P" ] && [ -s "$P/extras.lst" ]; then
    how+=" (сначала лишние файлы — в архив или в DS_PRESERVE, иначе --adopt откажет)"
  elif [ -n "$P" ] && [ "$(cat "$P/git" 2>/dev/null)" = yes ]; then
    how+=" (сначала $DS_DIR/.git — в архив)"
  fi
  _ds_block "$t: сервер не мигрирован (нет маркера ${DS_MARKER_DIR}) — выполните разовую миграцию по DEPLOY.md, затем $how"
}

# Проектная проверка ds_<цель>_remote_check: ТОЛЬКО чтение, через ds_probe,
# выполняется и в --dry-run (до окна и подтверждения). Получает те же
# переменные, что хуки (DS_EXPORT, DS_SHA, DS_PREV_SHA, DS_FIRST_DEPLOY,
# DS_SUDO_CMD, ds_changed/DS_CHANGED_FILE) и DS_MANIFEST_FILE — «sha256  путь»
# выкатываемых файлов. Самих файлов (payload) на сервере на этом шаге нет.
# Ненулевой код — отказ выкатки. Списки лежат во временном /tmp/ds-check.*
# (удаляется сразу).
_ds_probe_check_script() {  # <каталог плана> <sha> <prev> <prev_result>
  local P=$1 f v
  declare -p DS_ENV DS_TARGET DS_DIR DS_SUDO DS_MARKER_DIR
  printf 'DS_SHA=%q\nDS_PREV_SHA=%q\nDS_PREV_RESULT=%q\nDS_REPO=%q\nDS_LIB_VERSION=%q\n' \
    "$2" "$3" "$4" "$DS_GH_REPO" "$DS_DEPLOY_LIB_VERSION"
  for v in "${DS_EXPORT[@]}"; do declare -p "$v"; done
  declare -f _ds_glob_re ds_changed
  for f in $(compgen -A function | grep -E "^ds_(${DS_TARGET}_remote_|remote_)" || true); do
    declare -f "$f"
  done
  cat <<'EOF'
set -uo pipefail
DS_SUDO_CMD=""; if [ "$DS_SUDO" = 1 ]; then DS_SUDO_CMD="sudo -n"; fi
DS_FIRST_DEPLOY=0; if [ -z "$DS_PREV_SHA" ]; then DS_FIRST_DEPLOY=1; fi
ds_retry() {  # <попыток> <пауза, с> <команда...>
  local n=$1 d=$2 i; shift 2
  for ((i = 1; i <= n; i++)); do if "$@"; then return 0; fi; sleep "$d"; done
  return 1
}
_ds_ck=$(mktemp -d /tmp/ds-check.XXXXXX) || { echo "@@RC 99"; exit 0; }
trap 'rm -rf -- "$_ds_ck"' EXIT
DS_CHANGED_FILE="$_ds_ck/CHANGED"; DS_MANIFEST_FILE="$_ds_ck/MANIFEST"
export DS_SUDO_CMD DS_FIRST_DEPLOY DS_CHANGED_FILE DS_MANIFEST_FILE DS_SHA DS_PREV_SHA DS_PREV_RESULT
cat > "$DS_CHANGED_FILE" <<'DS_CK_CHANGED_EOF'
EOF
  cat "$P/changed.lst"
  printf 'DS_CK_CHANGED_EOF\ncat > "$DS_MANIFEST_FILE" <<'"'"'DS_CK_MANIFEST_EOF'"'"'\n'
  cat "$P/new.man"
  printf 'DS_CK_MANIFEST_EOF\n'
  # shellcheck disable=SC2016  # раскрывается на сервере
  printf '( set -e; cd "$DS_DIR" 2>/dev/null || cd /; ds_%s_remote_check ) 2>&1 | sed "s/^/  [сервер, проверка] /"\necho "@@RC ${PIPESTATUS[0]}"\n' "$DS_TARGET"
}

_ds_plan_target() {
  local t=$1 P="$_DS_W/$1" prev prev_result mode sha now rc cand free nfiles unmig="" cand_adopted=0
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
  nfiles=$(wc -l < "$P/files" | tr -d ' ')
  if [ "$nfiles" -gt "$DS_FILES_LIMIT" ]; then
    _ds_block "$t: в $DS_DIR больше $DS_FILES_LIMIT файлов вне DS_PRESERVE — сверка неполная; добавьте каталоги данных (data/, node_modules/, …) в DS_PRESERVE"
    return 0
  fi
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
    elif [ "$DS_ADOPT_MODE" = replace ]; then
      unmig=replace
      _ds_block "$t: сервер не мигрирован (нет маркера ${DS_MARKER_DIR}) — первая выкатка с заменой файлов (DS_ADOPT_MODE=replace) на $DS_ENV только явно: scripts/deploy.sh $DS_ENV --only $t --adopt (отличающиеся файлы сервера сохранятся в backup-*.tgz)"
    else
      # Отказ — ниже, после сверки: подсказка зависит от расхождений.
      unmig=verify
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
    # Маркер на этом коммите ставился --adopt: сервер тогда побайтно совпадал
    # с ним и работал — ci не требуется (у коммитов до стандарта его нет).
    cand_adopted=$(awk -F'\t' -v c="$cand" '$2 == c && $3 == "adopted" { a = 1 } END { print a + 0 }' "$P/history")
    sha=$cand; mode=rollback
    ds_info "  откат: ${prev:0:9} → ${sha:0:9}"
  fi
  ds_info "  коммит: $(ds_git log -1 --format='%h %ad %s' --date=short "$sha")"
  if [ -n "$prev" ]; then
    ds_info "  на сервере: ${prev:0:9} (результат: ${prev_result:-?})"
    case "$prev_result" in
      ok|adopted) ;;
      pending) ds_warn "$t: прошлая выкатка оборвалась (result=pending) — сверяю файлы; хукам — все изменения с последней успешной выкатки" ;;
      *) ds_warn "$t: прошлая выкатка не завершилась успешно (result=${prev_result:-?}) — хукам передаются все изменения с последней успешной выкатки (DS_PREV_RESULT)" ;;
    esac
    if [ "$prev" = "$sha" ] && [ "$mode" = deploy ]; then
      ds_info "  на сервере уже этот коммит — выкатка повторит шаги pre/post/health"
    fi
  else
    ds_info "  на сервере: маркера нет"
  fi
  if [ "$(cat "$P/git")" = yes ]; then ds_warn "$t: в каталоге цели есть .git (устаревший клон) — убрать при миграции"; fi

  # 3. Нагрузка и манифест.
  _ds_make_payload "$sha" "$P"
  if [ "$_DS_PAYLOAD_OK" != 1 ]; then
    [ "$unmig" != verify ] || _ds_block_unmigrated "$t" ""
    return 0
  fi
  _ds_show_list "НЕ выкатывается (DS_PRESERVE или похоже на секрет)" "$P/excluded.lst"

  # 4. Сравнение.
  cut -c67- "$P/new.man" > "$P/new.paths"
  cut -c67- "$P/oldman" > "$P/old.paths"
  awk -v p="$DS_DIR/" 'index($0, p) == 1 { s = substr($0, length(p) + 1); sub(/: FAILED( open or read)?$/, "", s); print s }' \
    "$P/driftraw" | LC_ALL=C sort -u > "$P/drift0.lst"
  # diff.txt: чем новый коммит отличается от того, что лежит на сервере (MANIFEST).
  if [ -n "$prev" ]; then
    _ds_man_diff "$P/oldman" "$P/new.man" > "$P/diff.txt"
  else
    sed 's/^/A\t/' "$P/new.paths" > "$P/diff.txt"
  fi
  cut -f2- "$P/diff.txt" > "$P/changed.lst"
  # Для хуков (ds_changed): после неуспешной прошлой выкатки — всё, что
  # изменилось с последней успешной (MANIFEST.ok), иначе шаги post/health
  # решат, что «ничего не менялось», и не поднимут остановленное.
  if [ -n "$prev" ] && [ "$prev_result" != ok ] && [ "$prev_result" != adopted ]; then
    if [ "$(cat "$P/okflag" 2>/dev/null)" = yes ]; then
      _ds_man_diff "$P/okman" "$P/new.man" | cut -f2- | LC_ALL=C sort -u - "$P/changed.lst" > "$P/changed.tmp"
    else
      grep '^D' "$P/diff.txt" | cut -f2- | LC_ALL=C sort -u - "$P/new.paths" > "$P/changed.tmp" || true
    fi
    mv -f "$P/changed.tmp" "$P/changed.lst"
  fi
  grep '^D' "$P/diff.txt" | cut -f2- | _ds_not_kept > "$P/prune.lst" || true
  # Хэши на сервере нужны для: дрейфа, новых для маркера файлов, миграции.
  { cat "$P/drift0.lst"; grep '^A' "$P/diff.txt" | cut -f2- || true; } | LC_ALL=C sort -u \
    | LC_ALL=C comm -12 - "$P/files" > "$P/hash.req"
  : > "$P/srvman.rel"
  if [ -s "$P/hash.req" ]; then
    if ! ds_probe "хэши файлов на сервере" "$(_ds_probe_hash_script "$P/hash.req")" > "$P/probe2.out" \
       || ! _ds_split_probe "$P/probe2.out" "$P"; then
      _ds_block "$t: не удалось прочитать хэши файлов на сервере"
      [ "$unmig" != verify ] || _ds_block_unmigrated "$t" ""
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

  # 5. Проверки и отчёт.
  if [ -n "$prev" ] && [ "$mode" != adopt-verify ]; then
    ds_info "  изменения: +$(grep -c '^A' "$P/diff.txt" || true) ~$(grep -c '^M' "$P/diff.txt" || true) -$(wc -l < "$P/prune.lst" | tr -d ' ') файлов"
    if ds_git cat-file -e "$prev^{commit}" 2>/dev/null; then
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
        [ "$unmig" != verify ] || _ds_block_unmigrated "$t" "$P"
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
      _ds_show_list "будут перезаписаны (отличаются; копия — в ${DS_MARKER_DIR}/backup-*.tgz)" "$P/conflict.lst"
      _ds_show_list "чужие файлы на сервере (не трогаются)" "$P/extras.lst" ;;
  esac
  if [ "$mode" != adopt-verify ] && [ -n "$prev" ]; then
    _ds_show_list "чужие файлы на сервере (не трогаются)" "$P/extras.lst"
    [ ! -s "$P/prune.lst" ] || [ "$DS_VERBOSE" = 1 ] || _ds_show_list "будут удалены (убраны из git)" "$P/prune.lst"
  fi
  # Что записывается на сервер: только отличающееся от выкатанного. Остальные
  # файлы не трогаются (их содержимое совпадает — это проверяет дрейф).
  case "$mode" in
    adopt-verify) : > "$P/write.lst" ;;
    adopt-replace) cp "$P/new.paths" "$P/write.lst" ;;
    *)
      if [ -z "$prev" ]; then
        cp "$P/new.paths" "$P/write.lst"
      else
        { grep -E '^(A|M)' "$P/diff.txt" | cut -f2- || true
          LC_ALL=C comm -12 "$P/drift.lst" "$P/new.paths" 2>/dev/null || true
          cat "$P/missing.lst"; } | LC_ALL=C sort -u > "$P/write.lst"
      fi ;;
  esac
  # ci: у коммита, файлы которого пишутся на сервер. --adopt-sha без замены
  # файлов только ставит маркер — ci старого коммита не нужен (логика
  # выкатки — из origin/<ветка>, её ci проверен в ds_main). При --rollback
  # ci головы в ds_main не проверяется — поэтому здесь проверяется всегда,
  # кроме отката на коммит, маркер на котором ставился --adopt.
  if [ "$sha" != "$DS_REEXEC" ] || [ "$mode" = rollback ]; then
    if [ "$mode" = adopt-verify ]; then
      ds_info "  ci у ${sha:0:9} не требуется: только маркер, файлы и сервисы не трогаются"
    elif [ "$mode" = rollback ] && [ "$cand_adopted" = 1 ]; then
      ds_warn "$t: откат на ${sha:0:9} — маркер на нём ставился --adopt (сервер совпадал с ним побайтно): ci у этого коммита не требуется"
      _DS_NOTE+="rollback-to-adopted(ci не требовался)=$t "
    else
      _ds_ci_gate "$sha"
    fi
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
  # Окно выкатки (ещё раз — на сервере, перед шагом pre).
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
  if [ -n "$unmig" ]; then
    ds_info "  без миграции на сервер ничего не записывается и ничего не перезапускается"
  elif [ "$mode" != adopt-verify ]; then
    ds_info "  будет записано на сервер: $(wc -l < "$P/write.lst" | tr -d ' ') файлов (остальные не трогаются)"
    if declare -F "ds_${t}_remote_post" >/dev/null; then
      ds_info "  после распаковки: ds_${t}_remote_post (сборка/перезапуск — см. scripts/deploy.sh)"
    else
      ds_info "  после распаковки: ничего не перезапускается"
    fi
  fi
  # Проектная проверка (только чтение) — и в --dry-run, чтобы отказы вроде
  # «venv не совпадает с requirements.txt» были видны до окна.
  if declare -F "ds_${t}_remote_check" >/dev/null && [ "$mode" != adopt-verify ]; then
    if ! ds_probe "проверка ds_${t}_remote_check" "$(_ds_probe_check_script "$P" "$sha" "$prev" "$prev_result")" > "$P/check.out"; then
      _ds_block "$t: не удалось выполнить проверку ds_${t}_remote_check на сервере"
    else
      grep -v '^@@RC ' "$P/check.out" || true
      rc=$(sed -n 's/^@@RC //p' "$P/check.out" | tail -n 1)
      if [ "$rc" != 0 ]; then
        _ds_block "$t: проектная проверка ds_${t}_remote_check отказала (код ${rc:-?}) — причина выше"
      else
        ds_info "  проверка ds_${t}_remote_check: пройдена"
      fi
    fi
  fi
  printf 'DS_P_SHA=%q\nDS_P_PREV=%q\nDS_P_MODE=%q\nDS_P_PREV_RESULT=%q\n' "$sha" "$prev" "$mode" "$prev_result" > "$P/plan.env"
  return 0
}

# ---------------------------------------------------------------------------
# Выкатка цели: пакет (ctl/ + payload.tar) → ОДНА SSH-сессия → run.sh
# ---------------------------------------------------------------------------
_ds_vars_script() {
  local f v
  declare -p DS_ENV DS_TARGET DS_SHA DS_EXPECT_PREV DS_DIR DS_SUDO DS_CHOWN \
    DS_MARKER_DIR DS_MIN_FREE_MB DS_MODE DS_OPERATOR DS_REMOTE_LOCK \
    DS_PREV_RESULT DS_WINDOW DS_WINDOW_CHECK DS_MSK_OFFSET DS_PC_HEALTH DS_FINAL
  printf 'DS_REPO=%q\nDS_LIB_VERSION=%q\n' "$DS_GH_REPO" "$DS_DEPLOY_LIB_VERSION"
  for v in "${DS_EXPORT[@]}"; do declare -p "$v"; done
  declare -f _ds_glob_re ds_changed _ds_in_window _ds_day_in _ds_day_num
  for f in $(compgen -A function | grep -E "^ds_(${DS_TARGET}_remote_|remote_)" || true); do
    declare -f "$f"
  done
}

_ds_runner_script() {
  cat <<'DS_RUNNER_EOF'
# ds-deploy: исполняется на сервере в одной SSH-сессии, под общим локом.
# Коды выхода: 20 — файлы изменились с момента проверки; 21 — маркер изменился;
# 23 — лок занят; 24 — мало места; 25 — вне окна выкатки; 30 — шаг pre упал
# (файлы не менялись); 31 — шаг post упал; 32 — здоровье не прошло.
set -euo pipefail
S=$1
. "$S/ctl/vars.sh"
SUDO=""; if [ "$DS_SUDO" = 1 ]; then SUDO="sudo -n"; fi
DS_SUDO_CMD=$SUDO
DS_PREV_SHA=$DS_EXPECT_PREV
DS_FIRST_DEPLOY=0; if [ -z "$DS_EXPECT_PREV" ]; then DS_FIRST_DEPLOY=1; fi
DS_CHANGED_FILE="$S/ctl/CHANGED"
DS_PKG_DIR=$S
DS_PAYLOAD="$S/payload.tar"
DS_STATE_FILE="$S/ctl/STATE"
: > "$DS_STATE_FILE"
export DS_SUDO_CMD DS_PREV_SHA DS_PREV_RESULT DS_FIRST_DEPLOY DS_CHANGED_FILE DS_PKG_DIR DS_PAYLOAD DS_STATE_FILE
M=$DS_MARKER_DIR
_lockdir=""
_cleanup() { if [ -n "$_lockdir" ]; then rmdir "$_lockdir" 2>/dev/null || true; fi; rm -rf -- "$S"; }
trap _cleanup EXIT
say() { printf '  [сервер] %s\n' "$*"; }
if [ "$DS_MODE" != finalize ]; then say "журнал на сервере: $S.log (остаётся при сбое или обрыве связи)"; fi
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
# Манифест последней УСПЕШНОЙ выкатки: от него считается CHANGED для хуков,
# если следующая выкатка идёт после неуспешной.
_mark_ok_manifest() { $SUDO cp "$M/MANIFEST" "$M/MANIFEST.ok.new"; $SUDO mv -f "$M/MANIFEST.ok.new" "$M/MANIFEST.ok"; }
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

# Итог после проверки здоровья с ПК (ds_<цель>_health): server-ok → ok | health-failed.
if [ "$DS_MODE" = finalize ]; then
  cur=$($SUDO sed -n 's/^result=//p' "$M/DEPLOYED")
  if [ "$cur" != server-ok ]; then echo "в маркере result=$cur, а ожидался server-ok" >&2; exit 21; fi
  DS_MODE=$($SUDO sed -n 's/^mode=//p' "$M/DEPLOYED")
  $SUDO sed "s/^result=.*/result=$DS_FINAL/" "$M/DEPLOYED" | $SUDO tee "$M/DEPLOYED.new" >/dev/null
  $SUDO mv -f "$M/DEPLOYED.new" "$M/DEPLOYED"
  if [ "$DS_FINAL" = ok ]; then _mark_ok_manifest; fi
  _history "$DS_FINAL"
  say "итог в маркере: $DS_FINAL"
  exit 0
fi

if [ "$DS_MODE" = adopt-verify ]; then
  if ! awk -v p="$DS_DIR/" '{ print substr($0, 1, 64) "  " p substr($0, 67) }' "$S/ctl/MANIFEST" \
       | $SUDO sha256sum -c --quiet - >/dev/null 2>&1; then
    echo "файлы на сервере изменились с момента проверки" >&2
    exit 20
  fi
  $SUDO mkdir -p "$M"
  $SUDO cp "$S/ctl/MANIFEST" "$M/MANIFEST.new"; $SUDO mv -f "$M/MANIFEST.new" "$M/MANIFEST"
  _mark_ok_manifest
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

# Окно выкатки — ещё раз, прямо перед остановками и перезапуском: между
# проверкой на ПК и этим местом могли пройти подтверждение, сборка и ожидание лока.
if [ "$DS_WINDOW_CHECK" = 1 ]; then
  _wrc=0; _ds_in_window "$DS_WINDOW" "$(date -u +%s)" || _wrc=$?
  if [ "$_wrc" != 0 ]; then
    echo "сейчас $(date -u -d "@$(($(date -u +%s) + DS_MSK_OFFSET))" '+%H:%M') МСК — вне окна «$DS_WINDOW»; ничего не менялось" >&2
    exit 25
  fi
fi

set +e; _hook pre; rc=$?; set -e
if [ "$rc" != 0 ]; then
  # ds_<цель>_remote_abort: вернуть то, что pre успел остановить.
  set +e; _hook abort; set -e
  echo "шаг pre упал (код $rc) — файлы не менялись" >&2
  exit 30
fi

$SUDO mkdir -p "$DS_DIR" "$M"
if [ -s "$S/ctl/BACKUP" ]; then
  bk="$M/backup-$(date -u +%Y%m%dT%H%M%SZ).tgz"
  # umask 077: в копии могут быть старые файлы с токенами (например submit.php).
  (umask 077; $SUDO tar -czf "$bk" -C "$DS_DIR" -T "$S/ctl/BACKUP")
  say "копия перезаписываемых файлов (права 600): $bk — удалить после проверки, если в ней секреты"
fi
_write_deployed pending
# Пишутся только файлы из WRITE (отличаются от выкатанных); остальные не
# трогаются вовсе. Распаковка поверх: --overwrite пишет в существующий файл
# (inode сохраняется), поэтому одиночные bind-маунты (Caddyfile, config.toml)
# видят новое содержимое. --touch: время записанных файлов — «сейчас», чтобы
# make/ninja на сервере пересобрали изменённое (и при откате тоже).
# Никаких mv/rename для файлов проекта.
if [ -s "$S/ctl/WRITE" ]; then
  # Бит исполнения: git с Windows часто хранит скрипты как 100644. Если файл на
  # сервере был исполняемым, а в пакете — нет, режим восстанавливается.
  _abs "$S/ctl/WRITE" | tr '\n' '\0' | $SUDO xargs -0 -r stat -c '%a %n' -- 2>/dev/null \
    | awk '{ m = $1; o = substr(m, length(m) - 2, 1); if (o % 2 == 1) print }' > "$S/ctl/EXEC_BEFORE" || true
  tr '\n' '\0' < "$S/ctl/WRITE" > "$S/ctl/WRITE0"
  $SUDO tar -x --overwrite --no-same-owner --touch --no-wildcards -f "$S/payload.tar" -C "$DS_DIR" --null -T "$S/ctl/WRITE0"
  while read -r _m _f; do
    [ -n "$_f" ] || continue
    _c=$($SUDO stat -c '%a' -- "$_f" 2>/dev/null) || continue
    if [ $(( ${_c: -3:1} % 2 )) = 0 ]; then
      $SUDO chmod "$_m" -- "$_f"
      say "бит исполнения восстановлен (в git файл без +x — git update-index --chmod=+x): ${_f#"$DS_DIR"/}"
    fi
  done < "$S/ctl/EXEC_BEFORE"
fi
say "записано файлов: $(wc -l < "$S/ctl/WRITE" | tr -d ' ')"
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
if [ "$DS_PC_HEALTH" = 1 ]; then
  # Итог ok ставится только после проверки с ПК (отдельный короткий вызов).
  _write_deployed server-ok
  _history server-ok
  say "на сервере готово: $DS_SHA — жду проверку здоровья с ПК"
else
  _mark_ok_manifest
  _write_deployed ok
  _history ok
  say "готово: $DS_SHA"
fi
DS_RUNNER_EOF
}

# Отправить пакет на сервер: ЕДИНСТВЕННЫЙ путь изменений — через ds_run.
_ds_send_pkg() {  # <каталог пакета> <описание>
  local P=$1 rc
  _ds_runner_script > "$P/pkg/ctl/run.sh"
  _ds_vars_script > "$P/pkg/ctl/vars.sh"
  (cd "$P/pkg" && tar -cf "$P/package.tar" ctl payload.tar)
  set +e
  ds_run "$2" _ds_transport_apply "$P/package.tar"
  rc=$?
  set -e
  _DS_APPLY_RC=$rc
  return 0
}

_ds_apply_target() {  # <цель>; код — в _DS_APPLY_RC
  local t=$1 P="$_DS_W/$1" desc
  _ds_load_target "$t"
  # shellcheck disable=SC1091
  . "$P/plan.env"
  DS_SHA=$DS_P_SHA; DS_EXPECT_PREV=$DS_P_PREV; DS_MODE=$DS_P_MODE; DS_PREV_RESULT=$DS_P_PREV_RESULT
  DS_FINAL=""; DS_WINDOW_CHECK=0; DS_PC_HEALTH=0
  if [ -z "$DS_IGNORE_WINDOW" ] && [ "$DS_MODE" != adopt-verify ]; then DS_WINDOW_CHECK=1; fi
  if declare -F "ds_${t}_health" >/dev/null && [ "$DS_MODE" != adopt-verify ]; then DS_PC_HEALTH=1; fi
  rm -rf "$P/pkg"; mkdir -p "$P/pkg/ctl"
  cp "$P/new.man" "$P/pkg/ctl/MANIFEST"
  cp "$P/new.paths" "$P/pkg/ctl/PATHS"
  cp "$P/write.lst" "$P/pkg/ctl/WRITE"
  cp "$P/prune.lst" "$P/pkg/ctl/PRUNE"
  cp "$P/changed.lst" "$P/pkg/ctl/CHANGED"
  cp "$P/drift0.lst" "$P/pkg/ctl/DRIFT0"
  # Копия отличающихся файлов: при --overwrite-drift и всегда при adopt-replace
  # (первая запись статики поверх того, что лежало на сервере до стандарта).
  if [ -n "$DS_OVERWRITE_DRIFT" ] || [ "$DS_MODE" = adopt-replace ]; then
    cp "$P/backup.lst" "$P/pkg/ctl/BACKUP"
  else
    : > "$P/pkg/ctl/BACKUP"
  fi
  if [ -f "$P/payload.tar" ]; then cp "$P/payload.tar" "$P/pkg/payload.tar"; else tar -cf "$P/pkg/payload.tar" -T /dev/null; fi
  if [ "$DS_HOST" = local ]; then desc="$DS_MODE ${DS_SHA:0:9} → $DS_DIR"; else desc="$DS_MODE ${DS_SHA:0:9} → $DS_USER@$DS_HOST:$DS_DIR"; fi
  _ds_send_pkg "$P" "$desc"
}

# Итог после проверки здоровья с ПК: маркер server-ok → ok | health-failed.
_ds_finalize_target() {  # <цель> <ok|health-failed>; код — в _DS_APPLY_RC
  local t=$1 P="$_DS_W/$1.final"
  _ds_load_target "$t"
  DS_EXPECT_PREV=$DS_SHA; DS_MODE=finalize; DS_FINAL=$2; DS_WINDOW_CHECK=0; DS_PC_HEALTH=0
  rm -rf "$P/pkg"; mkdir -p "$P/pkg/ctl"
  tar -cf "$P/pkg/payload.tar" -T /dev/null
  _ds_send_pkg "$P" "итог в маркере: $2 (${DS_SHA:0:9})"
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
  flags+=${_DS_NOTE:-}
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
  _DS_W=""; _DS_LOCAL_LOCK=""; DS_PREV_RESULT=""; DS_FINAL=""; DS_WINDOW_CHECK=0; DS_PC_HEALTH=0; _DS_NOTE=""
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

  # ci у коммита с логикой выкатки (и с файлами, если это не --adopt-sha и не
  # --rollback — там коммит файлов проверяется в плане цели). При --rollback
  # ci головы ветки не требуется: откат не должен зависеть от сломанной головы.
  if [ "$DS_ROLLBACK" = 0 ]; then _ds_ci_gate "$DS_REEXEC"; fi
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
    printf 'Выкатить на ПРОД? Для подтверждения введите имя репозитория (%s) в течение 5 минут: ' "$DS_REPO_NAME"
    ok=""
    read -r -t 300 ok || true
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
        if [ "$DS_MODE" = adopt-verify ]; then
          _ds_journal "$t" "$DS_SHA" "adopted"
          ds_info "✓ $t: маркер поставлен на ${DS_SHA:0:9} (файлы и сервисы не трогались)"
          continue
        fi
        if [ "$DS_PC_HEALTH" = 1 ]; then
          set +e; (set -e; "ds_${t}_health"); rc=$?; set -e
          if [ "$rc" != 0 ]; then
            ds_warn "$t: проверка здоровья с ПК (ds_${t}_health) не прошла"
            _ds_finalize_target "$t" health-failed
            [ "$_DS_APPLY_RC" = 0 ] || ds_warn "$t: не удалось записать итог в маркер (там result=server-ok)"
            _ds_journal "$t" "$DS_SHA" "health-failed(pc)"; code=5; failed="$t"; break
          fi
          _ds_finalize_target "$t" ok
          if [ "$_DS_APPLY_RC" != 0 ]; then
            ds_warn "$t: код выложен и здоров, но итог ok не записан в маркер (там result=server-ok) — повторите выкатку"
            _ds_journal "$t" "$DS_SHA" "finalize-failed($_DS_APPLY_RC)"; code=4; failed="$t"; break
          fi
        fi
        _ds_journal "$t" "$DS_SHA" "ok"
        ds_info "✓ $t: выкачено ${DS_SHA:0:9}" ;;
      20|21|23|24|25|30)
        _ds_journal "$t" "$DS_SHA" "refused-remote($rc)"
        ds_warn "$t: сервер отказал (код $rc) — файлы не менялись"; code=3; failed="$t"; break ;;
      32)
        _ds_journal "$t" "$DS_SHA" "health-failed"
        ds_warn "$t: код выложен, но проверка здоровья не прошла"; code=5; failed="$t"; break ;;
      *)
        _ds_journal "$t" "$DS_SHA" "failed($rc)"
        ds_warn "$t: сбой во время выкатки (код $rc) — состояние может быть частичным"
        if [ "$rc" = 255 ]; then
          ds_warn "$t: код 255 — похоже, оборвалась связь SSH. Выкатка на сервере могла дойти до конца: журнал — /tmp/ds-deploy.*.log на сервере (путь напечатан выше), итог — в ${DS_MARKER_DIR}/DEPLOYED (его покажет --dry-run). Повторять только после того, как увидите итог."
        fi
        code=4; failed="$t"; break ;;
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
