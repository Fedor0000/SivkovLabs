#!/usr/bin/env bash
# Запуск: ./lab2.sh [секунды]   (по умолчанию 10)
set -euo pipefail

DURATION=${1:-10}        # окно наблюдения, сек
STEP=${STEP:-0.05}       # период опроса ps, сек
DIR=$(mktemp -d)         # временные файлы прогона
trap 'rm -rf "$DIR"' EXIT
: > "$DIR/bpf"; : > "$DIR/bpf.err"

# Часть 1. Отсекаем ядерные потоки: на Debian 13 ps печатает их БЕЗ скобок,
# поэтому главный признак - родитель kthreadd (PID 2); скобки - для других систем.
user_pids() {
    ps -eo pid=,ppid=,comm= | awk '$1 != 2 && $2 != 2 && $3 !~ /^\[/ { print $1 }'
}

poll_ps() {
    user_pids | sort -u > "$DIR/base"                 # кто уже был в начале
    local end=$((SECONDS + DURATION))
    while (( SECONDS < end )); do                     # цикл опроса (polling)
        user_pids >> "$DIR/seen"
        sleep "$STEP"
    done
    sort -u "$DIR/seen" | comm -13 "$DIR/base" - | wc -l   # новые PID за окно
}

sudo -v                                              # кешируем пароль sudo

poll_ps > "$DIR/ps" &                                # Часть 1 фоном
PS_PID=$!

if command -v bpftrace > /dev/null; then
    # Часть 2. Однострочник: события ядра sched_process_fork (рождение задачи,
    # т.е. fork/clone) и sched_process_exec (успешный execve).
    sudo bpftrace -e "tracepoint:sched:sched_process_fork { @birth = count(); } tracepoint:sched:sched_process_exec { @exec = count(); } interval:s:$DURATION { exit(); }" \
        > "$DIR/bpf" 2> "$DIR/bpf.err" &
    BPF_PID=$!
else
    echo "ВНИМАНИЕ: bpftrace не установлен, Часть 2 пропущена"
fi

wait "$PS_PID" || true
[ -n "${BPF_PID:-}" ] && wait "$BPF_PID" || true

ps_seen=$(tr -dc '0-9' < "$DIR/ps")
birth=$(awk '/@birth/ { print $NF }' "$DIR/bpf" "$DIR/bpf.err" | tail -1)
execs=$(awk '/@exec/ { print $NF }' "$DIR/bpf" "$DIR/bpf.err" | tail -1)

echo "Окно наблюдения:           ${DURATION}s"
echo "ps увидел новых процессов: ${ps_seen:-0}"
echo "bpftrace: событий fork/clone: ${birth:-0}"
echo "bpftrace: событий execve:     ${execs:-0}"
if [ -n "${birth:-}" ] && (( birth > ps_seen )); then
    awk -v b="$birth" -v p="$ps_seen" 'BEGIN { printf "ps пропустил ~%d процессов (%.1f%% от рождений)\n", b - p, (b - p) * 100 / b }'
fi