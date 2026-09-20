#!/usr/bin/env bash
# Проверка активности зеркал из списка (mirrors.txt).
# Для каждого хоста пробует http:// и https:// по пути, известному
# из файла, и ищет живые разделы репозитория (Sisyphus и платформы
# p10/p11/p12) — HEAD/GET на {base}/<ветка>/<arch>/base/pkglist.classic.xz.
# Зеркало считается живым, если отвечает хотя бы по одному протоколу.
#
# Это «статическая» верификация списка перед публикацией/правкой. Сам
# alt_rate_mirrors.sh при каждом запуске проверяет свежесть с порогом
# 72 часа; здесь порог мягче (по умолчанию 7 дней) — задача отсеять
# именно мёртвые зеркала, а не временные задержки синхронизации.
#
# Использование:
#   bash check_mirrors.sh                # проверить весь mirrors.txt
#   bash check_mirrors.sh --max-days 14  # считать мёртвыми зеркала старше N дней
#   bash check_mirrors.sh --mirrors-file my.txt
#
# Код выхода: 0 — все зеркала живы и свежи, 1 — есть проблемы.
set -u

MIRRORS_FILE="mirrors.txt"
MAX_DAYS=7
while [ $# -gt 0 ]; do
    case "$1" in
        --mirrors-file) MIRRORS_FILE="$2"; shift 2;;
        --max-days) MAX_DAYS="$2"; shift 2;;
        *) echo "Неизвестная опция: $1" >&2; exit 2;;
    esac
done

[ -f "$MIRRORS_FILE" ] || { echo "Файл $MIRRORS_FILE не найден" >&2; exit 2; }

# Какие ветки искать на зеркале. Важно: Sisyphus лежит в Sisyphus/<arch>,
# а платформы — в pN/branch/<arch> (вложенность РАЗНАЯ). Пути собраны
# из формата apt, и именно в этом виде зеркало должно отдать pkglist,
# чтобы его мог использовать alt_rate_mirrors.sh.
BRANCH_RELPATH[0]="Sisyphus/x86_64"
BRANCH_RELPATH[1]="p10/branch/x86_64"
BRANCH_RELPATH[2]="p11/branch/x86_64"
BRANCH_RELPATH[3]="p12/branch/x86_64"

# Проверка одного URL. Сначала HEAD — он самый дешёвый; если сервер не
# поддерживает HEAD (405/403 и т.п.), пробуем range-GET (0-0), чтобы не
# качать файл целиком. Last-Modified отдельным HEAD-запросом нужен для
# оценки свежести индекса (см. --max-days).
# $1 url -> "CODE|LAST_MODIFIED"
probe() {
    local code lm
    code=$(curl -sI -m 15 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null)
    if [ "$code" != "200" ] && [ "$code" != "206" ]; then
        code=$(curl -s -m 15 -r 0-0 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null)
    fi
    lm=$(curl -sI -m 15 "$1" 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1)=="last-modified"{print $2}')
    printf '%s|%s' "$code" "$lm"
}

# $1=LM -> возраст в днях или "" (не распарсилось/нет)
age_days() {
    local sec
    [ -z "$1" ] || [ "$1" = "(нет)" ] && { echo ""; return; }
    sec=$(date -d "$1" +%s 2>/dev/null) || { echo ""; return; }
    echo $(( ($(date +%s) - sec) / 86400 ))
}

echo "Проверка зеркал из $MIRRORS_FILE (порог свежести: $MAX_DAYS дн.)"
echo "----------------------------------------------------------------------"

# Логика: хост считается живым, если найдена хотя бы ОДНА живая схема
# (http ИЛИ https). Пробуем обе: свежая схема попадает в alive_schemes,
# старая — в stale_schemes. Если не набралось ни одного живого протокола,
# хост проблемный (полностью мёртв или остались только старые разделы) —
# такие попадают в счётчик problems и на выходе дают код 1.
problems=0
while IFS='|' read -r host dir comment; do
    [ -z "$host" ] && continue
    case "$host" in \#*) continue;; esac
    alive_schemes=""
    stale_schemes=""
    for scheme in https http; do
        found=0
        branch_names=""
        lm="(нет)"
        for br in "${BRANCH_RELPATH[@]}"; do
            url="$scheme://$host$dir/$br/base/pkglist.classic.xz"
            res=$(probe "$url")
            code="${res%%|*}"
            if [ "$code" = "200" ] || [ "$code" = "206" ]; then
                found=1
                this_lm="${res#*|}"
                [ "$this_lm" != "(нет)" ] && lm="$this_lm"
                branch_names="$branch_names ${br%%/*}"
            fi
        done
        if [ "$found" = "1" ]; then
            age=$(age_days "$lm")
            if [ -n "$age" ] && [ "$age" -gt "$MAX_DAYS" ]; then
                printf '%-30s %-5s ЖИВ (ветки:%s), но СТАРЫЙ: %s (%s дн.)\n' \
                    "$host" "$scheme" "$branch_names" "${lm:-?}" "$age"
                stale_schemes="$stale_schemes $scheme"
            else
                printf '%-30s %-5s ЖИВ (ветки:%s), свежий, Last-Modified %s\n' \
                    "$host" "$scheme" "$branch_names" "${lm:-?}"
                alive_schemes="$alive_schemes $scheme"
            fi
        else
            printf '%-30s %-5s недоступен (%s://%s%s)\n' "$host" "$scheme" "$scheme" "$host" "$dir"
        fi
    done
    if [ -z "$alive_schemes" ] && [ -z "$stale_schemes" ]; then
        printf '>>> %-28s НЕ работает ни по одному протоколу — кандидат на удаление\n' "$host"
        problems=$((problems+1))
    elif [ -n "$stale_schemes" ] && [ -z "$alive_schemes" ]; then
        printf '>>> %-28s отвечает, но все разделы старые (>%s дн.)\n' "$host" "$MAX_DAYS"
        problems=$((problems+1))
    fi
done < "$MIRRORS_FILE"

echo "----------------------------------------------------------------------"
if [ "$problems" -eq 0 ]; then
    echo "Все зеркала доступны и свежи."
    exit 0
else
    echo "Проблем: $problems (зеркала не отвечают либо несвежи) — проверьте список."
    exit 1
fi