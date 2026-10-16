#!/usr/bin/env bash
# =============================================================================
# alt_rate_mirrors.sh — аналог rate-mirrors для ALT Linux
#
# Тестирует зеркала репозиториев ALT Linux на скорость и свежесть,
# определяет ветку дистрибутива (Sisyphus / p10 / p11 / p12 ...) и заменяет
# адреса зеркал в /etc/apt/sources.list.d на самые быстрые и актуальные.
#
# --- Как работает (обзор для ревью) ---
# 1. detect_system(): определяет, что система — ALT Linux, и узнаёт ветку
#    (sisyphus | p10 | p11 | ...) через rpm-макрос %_priority_distbranch —
#    тот же, которым пользуется сам apt; fallback — /etc/altrelease.
# 2. parse_config(): читает /etc/apt/sources.list.d/*.list, берёт строки
#    "rpm [label] <url> <relpath> <comps>", у которых relpath ведёт в ALT
#    (Sisyphus/... или pNN/branch/...). Меняется ТОЛЬКО url: пути, метки и
#    компоненты (classic, gostcrypto) сохраняются как есть, чтобы не сломать
#    репозиторий после применения.
# 3. test_one_candidate(): для каждого зеркала (хост x протокол) проверяет
#    полноту секций (arch/multilib/noarch), свежесть индекса (Last-Modified)
#    и реальную скорость скачивания pkglist.classic.xz (метод apt-check).
# 4. parse_results() -> compose_new_config() -> apply_config(): ранжирует
#    зеркала, пишет новый конфиг (с бэкапом) и запускает apt-get update.
# Безопасность: контроль «чужой ветки» (verify_branch_and_arch) не даст
# применить к системе зеркало другой платформы (например, Sisyphus на p11).
#
# Автор: als-creator
# Лицензия: GPL-3.0-or-later (см. LICENSE)
# Домашняя страница: https://github.com/als-creator/alt_rate_mirrors
#
# Запуск без установки (из интернета):
#   curl -fsSL https://raw.githubusercontent.com/als-creator/alt_rate_mirrors/main/alt_rate_mirrors.sh \
#     -o /tmp/alt_rate_mirrors.sh && bash /tmp/alt_rate_mirrors.sh
#
# На ALT Linux обычно нет sudo — скрипт сам повышает права через su,
# либо использует sudo, если он установлен.
# =============================================================================

# set -uo pipefail — без -e сознательно: сетевые тесты сами обрабатывают
# отказы curl (код ответа отличен от 200, пустой ответ и т.п.), а жёсткий
# выход при первой же ошибке лишил бы нас диагностики. pipefail нужен,
# чтобы конвейеры (printf/awk/sed/sort) не маскировали сбои своих элементов.
set -uo pipefail

# Единая локаль — чтобы printf/awk/sort работали числами с точкой
# независимо от локали пользователя (ru_RU даёт запятую).
export LC_ALL=C

VERSION="1.0.0"
SCRIPT_NAME="alt_rate_mirrors.sh"

# ----------------------------- значения по умолчанию ------------------------
# Все параметры можно задать заранее переменными окружения (TOP_MIRRORS=2,
# MAX_TIME=10 ...), что удобно для автоматизации и тестов. CLI-опции,
# разобранные ниже, перекрывают окружение. Приоритет:
#   значение по умолчанию < переменная окружения < опция командной строки.
TOP_MIRRORS="${TOP_MIRRORS:-3}"           # сколько лучших зеркал писать в конфиг
MAX_TIME="${MAX_TIME:-15}"                # сек, лимит на тест скорости одного зеркала
MAX_AGE_HOURS="${MAX_AGE_HOURS:-72}"      # свежесть зеркала (часы), старше — мимо
PARALLEL="${PARALLEL:-6}"                 # параллельных скоростных тестов
PROTOCOL="auto"                           # auto | http | https
ALLOW_STALE=0                             # не отбрасывать старые зеркала
DRY_RUN=0
FORCE=0                                   # пропустить проверку, что мы на ALT
VERBOSE=0
NO_UPDATE=0
MIRRORS_FILE=""
SOURCES_LIST_DIR="${SOURCES_LIST_DIR:-/etc/apt/sources.list.d}"
# Ветка и архитектура задаются переменными ALT_BRANCH (sisyphus|p10|p11|...)
# или опциями --branch/--arch (CLI перекрывает env); аналогично ALT_ARCH/--arch.
# На ALT без определений берутся из системы; на других дистрибутивах
# (режим --dry-run) ветка по умолчанию — sisyphus.

# ----------------------------- вывод ---------------------------------------
msg()  { printf '%s\n' "$*"; }
info() { printf '[.] %s\n' "$*"; }
ok()   { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
err()  { printf '[x] %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
    cat <<EOF
$SCRIPT_NAME v$VERSION — выбор самых быстрых и свежих зеркал ALT Linux

Использование:
  $SCRIPT_NAME [опции]

Опции:
  -n, --dry-run          только протестировать и показать результат, ничего не писать
                         (работает на любом дистрибутиве — без root и без --force)
  -t, --top N            сколько лучших зеркал записать (по умолчанию $TOP_MIRRORS)
      --max-time N       лимит теста скорости одного зеркала, секунд (по умолчанию $MAX_TIME)
      --max-age-hours N  отбрасывать зеркала, у которых индекс старше N часов (по умолчанию $MAX_AGE_HOURS)
      --allow-stale      не отбрасывать старые зеркала (они попадут в конец списка)
      --protocol P       auto | http | https (по умолчанию auto: https, если поддерживается)
      --parallel N       сколько тестов запускать параллельно (по умолчанию $PARALLEL)
      --branch B         ветка для теста: sisyphus, p10, p11, ... (иначе определяется автоматически)
      --arch A           архитектура: x86_64, aarch64, ... (иначе определяется автоматически)
  -f, --force            не проверять, что система действительно ALT Linux
      --no-update        не запускать apt-get update после применения зеркал
  -v, --verbose          подробный вывод
  -h, --help             эта справка

Примеры:
  $SCRIPT_NAME --dry-run                    # протестировать и показать список
  $SCRIPT_NAME --dry-run --branch p11       # проверить зеркала p11 с любого дистра
  $SCRIPT_NAME --top 2                      # применить два лучших зеркала
  $SCRIPT_NAME --protocol https             # тестировать только HTTPS

Режим --dry-run ничего не пишет в систему, поэтому работает на любом
дистрибутиве (Arch, Debian, Ubuntu, Fedora, ...) — это просто проверка
скорости и доступности зеркал ALT. Для ЗАПИСИ конфигурации нужен ALT Linux:
если вы не root — скрипт сам повысит права через su (по умолчанию
в ALT нет sudo) или через sudo.
EOF
}

# ----------------------------- разбор аргументов ----------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        -n|--dry-run)          DRY_RUN=1;;
        -t|--top)              shift; TOP_MIRRORS="$1";;
        --top=*)               TOP_MIRRORS="${1#*=}";;
        --max-time)            shift; MAX_TIME="$1";;
        --max-time=*)          MAX_TIME="${1#*=}";;
        --max-age-hours)       shift; MAX_AGE_HOURS="$1";;
        --max-age-hours=*)     MAX_AGE_HOURS="${1#*=}";;
        --allow-stale)         ALLOW_STALE=1;;
        --protocol)            shift; PROTOCOL="$1";;
        --protocol=*)          PROTOCOL="${1#*=}";;
        --parallel)            shift; PARALLEL="$1";;
        --parallel=*)          PARALLEL="${1#*=}";;
        --mirrors-file)        shift; MIRRORS_FILE="$1";;
        --mirrors-file=*)      MIRRORS_FILE="${1#*=}";;
        --branch)              shift; ALT_BRANCH="$1";;
        --branch=*)            ALT_BRANCH="${1#*=}";;
        --arch)                shift; ALT_ARCH="$1";;
        --arch=*)              ALT_ARCH="${1#*=}";;
        -f|--force)            FORCE=1;;
        --no-update)           NO_UPDATE=1;;
        -v|--verbose)          VERBOSE=1;;
        -h|--help)             usage; exit 0;;
        *)
            err "Неизвестная опция: $1"
            usage; exit 2;;
    esac
    shift
done

# ----------------------------- зависимости ----------------------------------
for cmd in curl awk sed date mktemp; do
    command -v "$cmd" >/dev/null 2>&1 || die "Не найден обязательный инструмент: $cmd"
done

# ----------------------------- список зеркал --------------------------------
# Формат строки:  host|директория дистрибутива|комментарий
# Список собран из вики https://www.altlinux.org/Зеркала, из списка зеркал
# apt-check (петр-ахламов/apt-check-qt) и из alt-mirror-switcher (shad).
# Каждый хост проверяется и по http, и по https (см. --protocol).
# Актуальность списка проверена 2026-09-19 (bash check_mirrors.sh):
# все хосты отвечают и свежи; mirror.mephi.ru работает только по http.
DEFAULT_MIRRORS=(
    "ftp.altlinux.org|/pub/distributions/ALTLinux|Официальное зеркало ALT Linux Team (Москва)"
    "mirror.yandex.ru|/altlinux|Яндекс"
    "mirror.datacenter.by|/pub/ALTLinux|Белтелеком (Минск, Беларусь)"
    "distrib-coffee.ipsl.jussieu.fr|/pub/linux/altlinux|IPSL (Париж, Франция)"
    "mirror.truenetwork.ru|/altlinux|TrueNetwork"
    "mirror.cs.msu.ru|/alt|МГУ им. Ломоносова"
    "mirror.eterfund.ru|/mirror.yandex.ru/altlinux|EterFund (зеркало Яндекс)"
    "mirror.mephi.ru|/ALTLinux|НИЯУ МИФИ (только http)"
    "download.basealt.ru|/pub/distributions/ALTLinux|Базальт СПО"
    "download.etersoft.ru|/pub/ALTLinux|Etersoft"
)

# Заполняет MIRROR_HOSTS[]/MIRROR_DISTDIR[]/MIRROR_COMMENT[] из файла
# (--mirrors-file) или из встроенного DEFAULT_MIRRORS. Строки вида
# "host|директория|комментарий"; пустые строки и строки, начинающиеся
# с '#', пропускаются. distdir — директория дистрибутива на зеркале,
# к которой пристыковываются relpath из конфига.
load_mirrors() {
    local n=0
    if [ -n "${MIRRORS_FILE}" ]; then
        [ -r "${MIRRORS_FILE}" ] || die "Не могу прочитать файл зеркал: ${MIRRORS_FILE}"
        n=0
        while IFS='|' read -r host distdir comment; do
            [ -z "$host" ] && continue
            case "$host" in \#*) continue;; esac
            MIRROR_HOSTS[$n]="$host"
            MIRROR_DISTDIR[$n]="$distdir"
            MIRROR_COMMENT[$n]="${comment:-}"
            n=$((n+1))
        done < "${MIRRORS_FILE}"
        [ "$n" -gt 0 ] || die "Файл зеркал ${MIRRORS_FILE} пуст"
    else
        for entry in "${DEFAULT_MIRRORS[@]}"; do
            IFS='|' read -r host distdir comment <<< "$entry"
            MIRROR_HOSTS[$n]="$host"
            MIRROR_DISTDIR[$n]="$distdir"
            MIRROR_COMMENT[$n]="${comment:-}"
            n=$((n+1))
        done
    fi
    MIRROR_COUNT="$n"
}

# ----------------------------- определение системы --------------------------
# Возвращает: ALT_OK=1 и BRANCH, ARCH, ALT_NAME
detect_system() {
    ALT_OK=0
    BRANCH=""
    ARCH=""
    ALT_NAME=""

    # 1. Это ALT Linux?
    [ -f /etc/altrelease ] && ALT_OK=1
    if [ -f /etc/os-release ]; then
        local id
        id=$(awk -F= '/^ID=/{gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null)
        [ "$id" = "altlinux" ] && ALT_OK=1
    fi
    if [ -f /etc/altrelease ]; then
        ALT_NAME=$(cat /etc/altrelease)
    elif [ -f /etc/os-release ]; then
        ALT_NAME=$(awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null)
    fi

    # 2. Ветка: _priority_distbranch — канонический макрос, которым пользуется сам apt
    if [ -n "${ALT_BRANCH:-}" ]; then
        BRANCH="$ALT_BRANCH"
    elif command -v rpm >/dev/null 2>&1; then
        BRANCH=$(rpm --eval "%_priority_distbranch" 2>/dev/null)
        case "$BRANCH" in
            "%"_*) BRANCH="";;
        esac
    fi
    if [ -z "$BRANCH" ] && [ -r /etc/altrelease ]; then
        local rel
        rel=$(cat /etc/altrelease)
        case "$rel" in
            *[Ss]isyphus*) BRANCH="sisyphus";;
            *p[0-9]*) BRANCH=$(printf '%s\n' "$rel" | sed -n 's/.*\(p[0-9][0-9]\).*/\1/p' | head -n1);;
        esac
    fi
    # Страховка на случай, если ветку не удалось определить (нет rpm и нет
    # /etc/altrelease): считаем Sisyphus — это «rolling по умолчанию». Если
    # на системе есть конфиг, реальная ветка всё равно уточняется по путям
    # из него (verify_branch_and_arch), так что ошибка здесь не критична.
    [ -z "$BRANCH" ] && BRANCH="sisyphus"

    # 3. Архитектура
    if [ -n "${ALT_ARCH:-}" ]; then
        ARCH="$ALT_ARCH"
    elif command -v rpm >/dev/null 2>&1; then
        ARCH=$(rpm --eval "%_arch" 2>/dev/null)
        case "$ARCH" in
            "%"_*) ARCH="";;
        esac
    fi
    [ -z "$ARCH" ] && ARCH=$(uname -m 2>/dev/null || echo x86_64)

    # Проверка «это ALT» нужна только при ЗАПИСИ конфигурации: в режиме
    # --dry-run ничего не пишется, поэтому тест зеркал разрешён с любого
    # дистрибутива (ветка/архитектура берутся из определения или --branch/--arch).
    if [ "$ALT_OK" != "1" ] && [ "$FORCE" != "1" ] && [ "$DRY_RUN" != "1" ]; then
        die "Похоже, это не ALT Linux (не найден /etc/altrelease и ID=altlinux в /etc/os-release). Для проверки зеркал без записи запустите с --dry-run; для принудительного применения — с --force."
    fi
}

# Возвращает ветку из рел-пути: "Sisyphus/x86_64" -> sisyphus, "p11/branch/x86_64" -> p11
branch_from_relpath() {
    case "$1" in
        [Ss]isyphus*) echo "sisyphus";;
        [pP][0-9]*) printf '%s\n' "$1" | sed -n 's/^\([pP][0-9][0-9]\).*/\1/p' | tr 'A-Z' 'a-z';;
        *) echo "";;
    esac
}

# Совпадает ли токен архитектуры из пути с архитектурой системы
arch_matches() {
    [ "$1" = "noarch" ] && return 1
    [ "$1" = "$ARCH" ] && return 0
    case "$ARCH:$1" in
        x86_64:x86_64-i586|x86_64:i586) return 0;;
    esac
    return 1
}

# Контроль «чужой версии»: ветка и архитектура в путях конфига
# должны соответствовать реальной системе. Иначе зеркало другой ветки
# (например, Sisyphus на p11) можно было бы применить и поломать обновления.
verify_branch_and_arch() {
    local b seen_branch="" seen_arch=0 ci
    for ((ci=0; ci<CFG_LINES; ci++)); do
        local rp="${CFG_RELPATH[$ci]}"
        b=$(branch_from_relpath "$rp")
        if [ -n "$b" ]; then
            case " $seen_branch " in
                *" $b "*) ;;
                *) seen_branch="$seen_branch $b";;
            esac
        fi
        local tok
        tok=$(printf '%s\n' "$rp" | awk -F/ '{print $NF}')
        if [ "$tok" != "noarch" ] && arch_matches "$tok"; then
            seen_arch=1
        fi
    done
    local count=0
    for b in $seen_branch; do count=$((count+1)); done
    if [ "$count" -ge 1 ] && [ "$FORCE" != "1" ]; then
        for b in $seen_branch; do
            if [ "$b" != "$BRANCH" ]; then
                die "ВНИМАНИЕ: пути в конфигурации ($SOURCES_LIST_DIR) относятся к ветке «$seen_branch», а система — «$BRANCH» ($ALT_NAME). Зеркала другой ветки применять нельзя — будут поломаны обновления. Проверьте /etc/altrelease и файлы *.list. Если уверены — запустите с --force."
            fi
        done
    elif [ "$count" -gt 1 ]; then
        warn "В конфигурации смешано несколько веток: $seen_branch — проверяем все пути как есть."
    fi
    if [ "$seen_arch" != "1" ] && [ "$FORCE" != "1" ]; then
        die "Ни одна секция в конфигурации не соответствует архитектуре системы ($ARCH). Проверьте файлы *.list. Если уверены — запустите с --force."
    fi
}

# ----------------------------- работа с конфигом ----------------------------
# Формат строки ALT:  rpm [label] <url> <relpath> <компоненты...>
# Например: rpm [alt] http://mirror.yandex.ru/altlinux p11/branch/x86_64 classic

# Разрешаем менять url только у «своих» секций ALT (Sisyphus/... и
# pNN/branch/...). Локальные источники (rpm file://...), не-ALT строки
# и прочие протоколы не трогаем — их адреса не должны перезаписываться.
is_managed_relpath() { # $1 = рел-путь
    case "$1" in
        Sisyphus/*|[pP][0-9]*/*|[pP][0-9]*) return 0;;
        *) return 1;;
    esac
}

parse_config() {
    # Внешние (глобальные) массивы:
    #   CFG_FILE_PER_LINE[] CFG_LINE_TEXT[] CFG_MANAGED[] CFG_LABEL[] CFG_RELPATH[] CFG_COMPS[]
    #   SRC_FILES[] (реальные файлы, содержащие управляемые строки)
    #
    # Формат строки: "rpm [метка] <url> <relpath> <comps...>". Метка может
    # отсутствовать ("rpm http://... relpath comps") — тогда подставляется
    # "[alt]". <comps> — всё, что идёт после relpath (classic, gostcrypto
    # и т.п.); они сохраняются без изменений, чтобы при записи не потерять
    # модификаторы репозитория. Итог: заменяется только URL, остальное —
    # байт в байт из исходной строки.
    CFG_LINES=0
    SRC_FILES_COUNT=0
    local file
    for file in "$SOURCES_LIST_DIR"/*.list; do
        [ -f "$file" ] || continue
        local src_lines=0
        while IFS= read -r line || [ -n "$line" ]; do
            local tokens label url relpath comps
            read -r -a tokens <<< "$line"
            [ ${#tokens[@]} -ge 1 ] || continue
            [ "${tokens[0]}" = "rpm" ] || continue
            # пропускаем локальные источники (file://) и не поддерживаемые протоколы
            case "${tokens[1]}" in
                \[*\]) label="${tokens[1]}"; url="${tokens[2]:-}";;
                *)     label="[alt]";      url="${tokens[1]:-}";;
            esac
            case "$url" in
                http://*|https://*) ;;
                *) continue;;
            esac
            if [ "${tokens[1]}" = "$label" ]; then
                relpath="${tokens[3]:-}"
            else
                relpath="${tokens[2]:-}"
            fi
            if is_managed_relpath "$relpath"; then
                # комповы — всё, что после relpath
                local comps_str=""
                local i start=0
                # находим индекс relpath
                for i in "${!tokens[@]}"; do
                    [ "${tokens[$i]}" = "$relpath" ] && { start=$((i+1)); break; }
                done
                while [ "$start" -lt "${#tokens[@]}" ]; do
                    comps_str="${comps_str} ${tokens[$start]}"
                    start=$((start+1))
                done
                CFG_FILE_PER_LINE[$CFG_LINES]="$file"
                CFG_LINE_TEXT[$CFG_LINES]="$line"
                CFG_MANAGED[$CFG_LINES]=1
                CFG_LABEL[$CFG_LINES]="$label"
                CFG_RELPATH[$CFG_LINES]="$relpath"
                CFG_COMPS[$CFG_LINES]="${comps_str# }"
                CFG_LINES=$((CFG_LINES+1))
                src_lines=1
            fi
        done < "$file"
        # SRC_FILES пополняется только файлами, где были управляемые строки:
        # именно их мы пересоздаём в compose_new_config, остальные *.list
        # остаются как есть.
        if [ "$src_lines" = "1" ]; then
            SRC_FILES[$SRC_FILES_COUNT]="$file"
            SRC_FILES_COUNT=$((SRC_FILES_COUNT+1))
        fi
    done
}

# Если в конфиге нет ни одной управляемой строки — строим стандартный набор
# путей под обнаруженные ветку и архитектуру.
# Фолбэк для систем с пустым/отсутствующим конфигом: строим стандартный
# набор секций под обнаруженные ветку/архитектуру (те же пути, что выдаёт
# apt при «чистой» установке). Секцию x86_64-i586 добавляем только на
# x86_64 — это legacy multilib-набор для 32-битных пакетов, на других
# архитектурах его нет.
build_default_relpaths() {
    local relpaths=""
    if [ "$BRANCH" = "sisyphus" ]; then
        relpaths="$relpaths Sisyphus/$ARCH"
        case "$ARCH" in
            x86_64) relpaths="$relpaths Sisyphus/x86_64-i586";;
        esac
        relpaths="$relpaths Sisyphus/noarch"
    else
        relpaths="$relpaths $BRANCH/branch/$ARCH"
        case "$ARCH" in
            x86_64) relpaths="$relpaths $BRANCH/branch/x86_64-i586";;
        esac
        relpaths="$relpaths $BRANCH/branch/noarch"
    fi
    DEFAULT_RELPATHS=( $relpaths )
}

# ----------------------------- сетевое тестирование -------------------------
# Скачивает ОДИН байт файла (-r 0-0) вместо целого: так проверяется
# наличие файла и его заголовки (Last-Modified, Content-Length) без
# закачки ~29 МБ. Серверы, не поддерживающие range, вернут ошибку —
# её обработкой занимается вызывающий код.
# probe_url_url код 200 = хорошо; возвращает 0 если доступен
http_fetch_one() { # $1=url  $2=время ожидания  $3=out_file  $4=headers_file
    curl -L -sS --max-time "$2" -o "$3" -D "$4" -r 0-0 "$1" 2>/dev/null
    return $?
}

# Полный тест одного кандидата (хост x протокол). Три фазы:
#   1) полнота — на зеркале должны лежать ВСЕ секции конфига
#      ({base}/<relpath>/base/pkglist.classic.xz, relpath напр. p11/branch/x86_64);
#      отсутствие любой секции = зеркало неполное -> кандидат выбрасывается;
#   2) свежесть — по Last-Modified индекса (старше MAX_AGE_HOURS = stale);
#   3) скорость — реальная закачка того же pkglist.classic.xz (именно его
#      качает apt-get при обновлении), speed = size_download / time_total
#      (метод apt-check: тестируем то, что действительно будем качать).
# Результат пишется в файл $RESULT_DIR/$id.txt: кандидаты тестируются
# параллельно (см. main), а фоновые процессы в bash не делят массивы —
# файлы здесь единственный надёжный канал обмена результатами.
test_one_candidate() {
    # $1 = id кандидата; результаты пишем в $RESULT_DIR/$1.txt
    local id="$1"
    local scheme="${CAND_SCHEME[$id]:-}"
    local host="${CAND_HOST[$id]:-}"
    local distdir="${CAND_DISTDIR[$id]:-}"
    local base="${scheme}://${host}${distdir}"
    local out="$RESULT_DIR/$id.txt"
    local main_relpath="${FIRST_RELPATH}"
    local html="" lm="" code="" bytes="" secs="" conn="" speed="" age_h="" stale=0 complete=0 ok=0
    local reason=""

    # --- проверка доступности всех секций (архитектура, multilib, noarch) ---
    local rp
    for rp in "${TEST_RELPATHS[@]}"; do
        local tmpf tmpd
        tmpf=$(mktemp); tmpd=$(mktemp)
        code=$(curl -L -sS --max-time "$((MAX_TIME>12?MAX_TIME:12))" -o /dev/null -D "$tmpd" -r 0-0 -w "%{http_code}" "${base}/${rp}/base/pkglist.classic.xz" 2>/dev/null)
        # если HEAD/диапазон не поддерживаются — пробуем обычный GET заголовками
        if [ "$code" != "200" ] && [ "$code" != "206" ]; then
            code=$(curl -L -sS --max-time "$((MAX_TIME>12?MAX_TIME:12))" -o "$tmpf" -D "$tmpd" -w "%{http_code}" "${base}/${rp}/base/pkglist.classic.xz" 2>/dev/null)
        fi
        if [ "$code" != "200" ] && [ "$code" != "206" ]; then
            reason="нет секции ${rp} (HTTP ${code})"
            rm -f "$tmpf" "$tmpd"
            write_result "$out" "$id" "$base" "$scheme" "$host" "$reason" 0 0 0 0 "$complete" 0
            return 0
        fi
        # время модификации индекса для проверки свежести (по первой секции)
        if [ -z "$lm" ]; then
            lm=$(awk 'BEGIN{IGNORECASE=1} /^last-modified:/{sub(/^[^:]*:[[:space:]]*/,""); print; exit}' "$tmpd")
        fi
        rm -f "$tmpf" "$tmpd"
    done
    complete=1

    # --- свежесть ---
    if [ -n "$lm" ]; then
        local lm_secs now_secs
        lm_secs=$(date -d "$lm" +%s 2>/dev/null || echo "")
        now_secs=$(date +%s)
        if [ -n "$lm_secs" ]; then
            age_h=$(( (now_secs - lm_secs) / 3600 ))
            if [ "$age_h" -gt "$MAX_AGE_HOURS" ]; then stale=1; fi
        fi
    fi

    # --- замер скорости: качаем индекс pkglist, но не дольше MAX_TIME ---
    local f
    f=$(mktemp)
    local out_data
    out_data=$(curl -L -sS --max-time "$MAX_TIME" -o /dev/null -w "code=%{http_code} bytes=%{size_download} secs=%{time_total} conn=%{time_connect}" "${base}/${main_relpath}/base/pkglist.classic.xz" 2>/dev/null)
    code=$(printf '%s\n' "$out_data" | sed -n 's/.*code=\([0-9]*\).*/\1/p')
    bytes=$(printf '%s\n' "$out_data" | sed -n 's/.*bytes=\([0-9]*\).*/\1/p')
    secs=$(printf '%s\n' "$out_data"  | sed -n 's/.*secs=\([0-9.]*\).*/\1/p')
    conn=$(printf '%s\n' "$out_data"  | sed -n 's/.*conn=\([0-9.]*\).*/\1/p')
    rm -f "$f"

    if [ "$code" != "200" ] && [ "$code" != "206" ]; then
        reason="ошибка при замере скорости (HTTP ${code})"
        write_result "$out" "$id" "$base" "$scheme" "$host" "$reason" 0 0 0 0 "$complete" 0
        return 0
    fi
    if [ "${bytes:-0}" = "0" ]; then
        reason="не удалось скачать данные для замера"
        write_result "$out" "$id" "$base" "$scheme" "$host" "$reason" 0 0 0 0 "$complete" 0
        return 0
    fi
    secs=$(awk -v s="$secs" 'BEGIN{if(s<=0)s=0.001; print s}')
    speed=$(awk -v b="$bytes" -v s="$secs" 'BEGIN{printf "%.2f", b/1048576/s}')
    ok=1
    write_result "$out" "$id" "$base" "$scheme" "$host" "" 1 "$speed" "$conn" "$bytes" "$complete" "$stale"
}

write_result() {
    local out="$1" id="$2" base="$3" scheme="$4" host="$5" reason="$6" ok="$7" \
          speed="$8" conn="$9" bytes="${10}" complete="${11}" stale="${12}"
    {
        printf 'id=%s\n' "$id"
        printf 'url=%s\n' "$base"
        printf 'scheme=%s\n' "$scheme"
        printf 'host=%s\n' "$host"
        printf 'ok=%s\n' "$ok"
        printf 'complete=%s\n' "$complete"
        printf 'stale=%s\n' "$stale"
        printf 'speed=%s\n' "$speed"
        printf 'conn=%s\n' "$conn"
        printf 'bytes=%s\n' "$bytes"
        printf 'reason=%s\n' "$reason"
    } > "$out"
}

# Читает файлы результатов ($RESULT_DIR/*.txt) и строит рейтинг:
#   1) оставляет только кандидатов с ok=1 и complete=1 (полные зеркала);
#      если не --allow-stale, дополнительно отбрасывает stale=1;
#   2) дедупликация по ХОСТУ: у каждого хоста остаётся один вариант —
#      с большей скоростью; при равной скорости предпочитается https;
#   3) сортировка по скорости (убывание), при равенстве — по time_connect.
# Выход: отсортированный список RANK_*2[] — это и есть топ для конфига.
parse_results() {
    # результат в глобальных массивах RANK_*
    RANK_COUNT=0
    local f id
    for f in "$RESULT_DIR"/*.txt; do
        [ -f "$f" ] || continue
        local ok_val host url speed conn stale complete_age
        ok_val=$(awk -F= '/^ok=/{print $2}' "$f")
        [ "$ok_val" = "1" ] || continue
        complete=$(awk -F= '/^complete=/{print $2}' "$f")
        [ "$complete" = "1" ] || continue
        stale=$(awk -F= '/^stale=/{print $2}' "$f")
        if [ "$stale" = "1" ] && [ "$ALLOW_STALE" != "1" ]; then continue; fi
        host=$(awk -F= '/^host=/{print $2}' "$f")
        url=$(awk -F= '/^url=/{print $2}' "$f")
        speed=$(awk -F= '/^speed=/{print $2}' "$f")
        conn=$(awk -F= '/^conn=/{print $2}' "$f")
        # оставляем лучший вариант (по скорости) для каждого ХОСТА;
        # при равной скорости предпочитаем https
        local key="$host"
        local found=0 i
        for i in "${!RANK_KEY[@]}"; do
            if [ "${RANK_KEY[$i]}" = "$key" ]; then
                found=1
                local prev_speed="${RANK_SPEED[$i]}"
                local prev_url="${RANK_URL[$i]}"
                local better=0
                if awk -v a="$speed" -v b="$prev_speed" 'BEGIN{if(a>b) exit 0; exit 1}'; then
                    better=1
                elif awk -v a="$speed" -v b="$prev_speed" 'BEGIN{if(a==b) exit 0; exit 1}'; then
                    case "$url" in
                        https://*) case "$prev_url" in http://*) better=1;; esac;;
                    esac
                fi
                if [ "$better" = "1" ]; then
                    RANK_URL[$i]="$url"; RANK_HOST[$i]="$host"
                    RANK_SPEED[$i]="$speed"; RANK_CONN[$i]="$conn"; RANK_STALE[$i]="$stale"
                fi
                break
            fi
        done
        if [ "$found" = "0" ]; then
            RANK_KEY[$RANK_COUNT]="$key"
            RANK_URL[$RANK_COUNT]="$url"
            RANK_HOST[$RANK_COUNT]="$host"
            RANK_SPEED[$RANK_COUNT]="$speed"
            RANK_CONN[$RANK_COUNT]="$conn"
            RANK_STALE[$RANK_COUNT]="$stale"
            RANK_COUNT=$((RANK_COUNT+1))
        fi
    done
    # сортировка по скорости (убывание), при равенстве — по времени соединения
    # используем внешний sort над сгенерированной таблицей
    local tbl="$RESULT_DIR/rank.tbl"
    : > "$tbl"
    local i
    for ((i=0; i<RANK_COUNT; i++)); do
        LC_ALL=C printf '%.2f\t%.3f\t%s\t%s\n' "${RANK_SPEED[$i]}" "${RANK_CONN[$i]}" "${RANK_URL[$i]}" "${RANK_HOST[$i]}" >> "$tbl"
    done
    sort -t $'\t' -k1,1nr -k2,2n "$tbl" > "$tbl.sorted"
    RANK_COUNT=0
    while IFS=$'\t' read -r sp co url host; do
        [ -n "$host" ] || continue
        RANK_URL2[$RANK_COUNT]="$url"
        RANK_HOST2[$RANK_COUNT]="$host"
        RANK_SPEED2[$RANK_COUNT]="$sp"
        RANK_CONN2[$RANK_COUNT]="$co"
        RANK_COUNT=$((RANK_COUNT+1))
    done < "$tbl.sorted"
}

# ----------------------------- генерация конфига ----------------------------
# Собирает новые *.list в $OUT_DIR. Структура файла:
#   1) служебный заголовок (ветка/архитектура, дата создания);
#   2) все НЕ управляемые строки оригинала — сохраняются один в один
#      (локальные file://-секции, чужие репозитории, комментарии и т.п.);
#   3) управляемые секции, повторённые под КАЖДОЕ из TOP_MIRRORS лучших
#      зеркал: url подставляется в исходный шаблон строки, relpath и
#      компоненты не меняются.
compose_new_config() {
    # пишет новые файлы в $OUT_DIR/<базовое имя>.list
    # HEADER записывается в начало каждого изменяемого файла
    local f
    for f in "${SRC_FILES[@]}"; do
        local base_fn
        base_fn=$(basename "$f")
        local out_file="$OUT_DIR/$base_fn"
        : > "$out_file"
        printf '%s\n' "# Файл перегенерирован $SCRIPT_NAME v$VERSION $(date '+%Y-%m-%d %H:%M:%S')" >> "$out_file"
        printf '%s\n' "# Ветка: $BRANCH, архитектура: $ARCH ($ALT_NAME)" >> "$out_file"
        printf '%s\n' "# Зеркала выбраны по скорости и свежести индексов." >> "$out_file"
        printf '%s\n' >> "$out_file"
        # сначала исходные НЕ управляемые строки файла
        if [ -f "$f" ]; then
            while IFS= read -r line || [ -n "$line" ]; do
                m=0
                for idx2 in "${!CFG_FILE_PER_LINE[@]}"; do
                    if [ "${CFG_FILE_PER_LINE[$idx2]}" = "$f" ] && [ "${CFG_LINE_TEXT[$idx2]}" = "$line" ]; then
                        m=1; break
                    fi
                done
                [ "$m" = "1" ] && continue
                printf '%s\n' "$line" >> "$out_file"
            done < "$f"
        fi
        printf '%s\n' >> "$out_file"
        # теперь управляемые секции под каждый выбранный зеркальный URL
        local mi
        for ((mi=0; mi<TOP_MIRRORS; mi++)); do
            local url="${RANK_URL2[$mi]:-}"
            [ -n "$url" ] || break
            printf '%s\n' "# --- ${RANK_HOST2[$mi]} (${RANK_SPEED2[$mi]} МБ/с) ---" >> "$out_file"
            local ci
            for ((ci=0; ci<CFG_LINES; ci++)); do
                [ "${CFG_FILE_PER_LINE[$ci]}" = "$f" ] || continue
                printf 'rpm %s %s %s %s\n' "${CFG_LABEL[$ci]}" "$url" "${CFG_RELPATH[$ci]}" "${CFG_COMPS[$ci]}" >> "$out_file"
            done
        done
    done
}

# ----------------------------- применение -----------------------------------
# Выполнение команды с правами root. Порядок: уже root -> sudo (если
# установлен) -> su - root. В ALT по умолчанию нет sudo, поэтому su —
# основной путь повышения прав; sudo предпочтительнее там, где он есть.
elevate() { # $@ = команда (строка)
    if [ "$(id -u)" = "0" ]; then
        eval "$1"
        return $?
    fi
    if command -v sudo >/dev/null 2>&1; then
        sudo sh -c "$1"
        return $?
    fi
    if command -v su >/dev/null 2>&1; then
        su - root -c "$1"
        return $?
    fi
    return 1
}

# Применение конфигурации: сначала бэкап всего каталога (с пометкой даты),
# затем установка новых файлов. Вся операция — ОДНА root-команда (elevate),
# чтобы: а) не плодить диалоги пароля; б) бэкап и запись шли в рамках
# одного su/sudo-сеанса — если команда упадёт, файлы не изменятся.
apply_config() {
    local stamp backup_dir
    stamp=$(date '+%Y%m%d-%H%M%S')
    backup_dir="${SOURCES_LIST_DIR}.bak-$stamp"
    local cmd=""
    cmd+="cp -a '${SOURCES_LIST_DIR}' '${backup_dir}' && "
    local f base_fn
    for f in "$OUT_DIR"/*.list; do
        [ -f "$f" ] || continue
        base_fn=$(basename "$f")
        cmd+="install -m 644 '${f}' '${SOURCES_LIST_DIR}/${base_fn}' && "
    done
    cmd="${cmd% && }"
    if ! elevate "$cmd"; then
        err "Не удалось записать конфигурацию (требуются права root)."
        err "Бэкап НЕ создан, файлы не изменены."
        return 1
    fi
    BACKUP_DIR="$backup_dir"
    return 0
}

# ----------------------------- main -----------------------------------------
detect_system
# На не-ALT системе в режиме теста предупреждаем: ветка по умолчанию
# sisyphus, для другой — укажите --branch.
if [ "$ALT_OK" != "1" ] && [ "$DRY_RUN" = "1" ]; then
    warn "Система не определена как ALT Linux — режим проверки (--dry-run), конфигурация не изменится. Тестируемая ветка: $BRANCH (--branch задаёт другую)."
fi
[ "$VERBOSE" = "1" ] && info "ALT: $ALT_NAME | ветка: $BRANCH | arch: $ARCH"

load_mirrors
info "Зеркал в списке: $MIRROR_COUNT"

# --- читаем текущую конфигурацию ---
parse_config
if [ "$CFG_LINES" -eq 0 ]; then
    warn "Управляемых строк (rpm https?://...) в $SOURCES_LIST_DIR/*.list не найдено."
    warn "Будут использованы стандартные пути для ветки $BRANCH (архитектура $ARCH)."
    build_default_relpaths
    FIRST_RELPATH="${DEFAULT_RELPATHS[0]}"
    TEST_RELPATHS=( "${DEFAULT_RELPATHS[@]}" )
    # эмулируем один исходный файл
    SRC_FILES_COUNT=1
    SRC_FILES[0]="$SOURCES_LIST_DIR/alt.list"
    CFG_LINES=0
    for rp in "${DEFAULT_RELPATHS[@]}"; do
        CFG_FILE_PER_LINE[$CFG_LINES]="${SRC_FILES[0]}"
        CFG_LINE_TEXT[$CFG_LINES]="rpm [alt] <URL> ${rp} classic"
        CFG_MANAGED[$CFG_LINES]=1
        CFG_LABEL[$CFG_LINES]="[alt]"
        CFG_RELPATH[$CFG_LINES]="$rp"
        CFG_COMPS[$CFG_LINES]="classic"
        CFG_LINES=$((CFG_LINES+1))
    done
else
    FIRST_RELPATH="${CFG_RELPATH[0]}"
    # контроль соответствия ветки/архитектуры системы и конфига
    verify_branch_and_arch
    # уникальные рел-пути для проверки полноты
    TEST_RELPATHS=()
    for ((ci=0; ci<CFG_LINES; ci++)); do
        rp="${CFG_RELPATH[$ci]}"; seen=0
        for i2 in "${!TEST_RELPATHS[@]}"; do
            [ "${TEST_RELPATHS[$i2]}" = "$rp" ] && seen=1
        done
        [ "$seen" = "0" ] && TEST_RELPATHS+=("$rp")
    done
fi

info "Проверяемые секции: ${TEST_RELPATHS[*]}"

# --- строим список кандидатов (по хосту и протоколу) ---
# Один хост даёт два кандидата (http и https) — при --protocol auto
# пробуется оба, а дедупликация в parse_results оставит у хоста только
# лучший вариант (по скорости, при равенстве — https).
CAND_COUNT=0
for ((hi=0; hi<MIRROR_COUNT; hi++)); do
    for pi in http https; do
        case "$PROTOCOL" in
            http)  [ "$pi" = "https" ] && continue;;
            https) [ "$pi" = "http" ] && continue;;
        esac
        CAND_SCHEME[$CAND_COUNT]="$pi"
        CAND_HOST[$CAND_COUNT]="${MIRROR_HOSTS[$hi]}"
        CAND_DISTDIR[$CAND_COUNT]="${MIRROR_DISTDIR[$hi]}"
        CAND_COUNT=$((CAND_COUNT+1))
    done
done
info "Кандидатов: $CAND_COUNT (тестируем со скоростью до $MAX_TIME с каждым, парал. $PARALLEL)"

RESULT_DIR="$(mktemp -d /tmp/alt_rate_mirrors.XXXXXX)"
trap 'rm -rf "$RESULT_DIR" "$OUT_DIR"' EXIT
# OUT_DIR создаётся отдельно — в нём лежат новые файлы конфигурации (для dry-run показать / применить)
OUT_DIR="$(mktemp -d /tmp/alt_rate_mirrors_out.XXXXXX)"

# Параллельный запуск тестов с батчингом: каждые PARALLEL процессов ждём
# (wait), чтобы не перегружать сеть и систему сверх лимита. Каждый тест
# пишет результат в свой файл, поэтому параллельность безопасна — общих
# массивов между фоновыми процессами нет.
for ((cid=0; cid<CAND_COUNT; cid++)); do
    test_one_candidate "$cid" &
    if [ $(( (cid+1) % PARALLEL )) -eq 0 ]; then wait; fi
done
wait

parse_results
if [ "$RANK_COUNT" -eq 0 ]; then
    die "Не удалось протестировать ни одного зеркала. Конфигурация не изменена."
fi

info "=== Рейтинг зеркал ==="
for ((ri=0; ri<RANK_COUNT; ri++)); do
    LC_ALL=C printf '   %2d. %-10s %6.2f МБ/с  %s\n' $((ri+1)) "${RANK_HOST2[$ri]}" "${RANK_SPEED2[$ri]}" "${RANK_URL2[$ri]}"
done

compose_new_config

if [ "$DRY_RUN" = "1" ]; then
    info "=== Сухой прогон. Конфигурация НЕ изменена. Новый конфиг: ==="
    for f in "$OUT_DIR"/*.list; do
        [ -f "$f" ] || continue
        echo "--- $f ---"
        cat "$f"
    done
    ok "Готово (dry-run). Чтобы применить: запустите без --dry-run."
    exit 0
fi

if ! apply_config; then
    die "Не удалось применить конфигурацию."
fi
ok "Зеркала записаны. Бэкап: $BACKUP_DIR"

if [ "$NO_UPDATE" != "1" ]; then
    info "Обновляю список пакетов (apt-get update)..."
    if elevate "apt-get update"; then
        ok "apt-get update выполнен успешно."
    else
        warn "apt-get update завершился с ошибкой — проверьте выбранные зеркала вручную."
    fi
fi

ok "Готово. Используемые зеркала записаны в $SOURCES_LIST_DIR."
exit 0