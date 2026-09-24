#!/usr/bin/env bash
# scripts/deploy.sh — у проекта delta-conference нет деплоя (стандарт Delta Securities).
# Файл нужен для единообразия: `scripts/deploy.sh prod` везде даёт понятный ответ.
# Когда у проекта появится сервер — заменить на templates/deploy.sh и описать в DEPLOY.md.
set -euo pipefail
DS_GH_REPO="Delta-Securities/delta-conference"
# shellcheck source=scripts/lib/ds-deploy.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/ds-deploy.sh"

ds_config() {
  # Боевой адрес не найден (delta-conference.netlify.app — чужой сайт).
  # Когда владелец определит хостинг — заменить на templates/deploy.sh
  # (статика out/ из архива коммита: ds_<цель>_build + DS_BUILD_OUT=out).
  DS_NO_DEPLOY="цель деплоя не определена — где прод и нужен ли он, решает владелец (см. DEPLOY.md). До решения ничего не выкладывать"
}

ds_main "$@"
