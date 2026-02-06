#!/usr/bin/env bash
# ada — a dead-simple service manager for desktop jobs
# No dependencies beyond bash, jq, and standard unix tools.
set -euo pipefail

# ── Paths ────────────────────────────────────────────────────────────────────
ADA_HOME="${HOME}/.ada"
ADA_PIDS="${ADA_HOME}/pids"
ADA_LOGS="${ADA_HOME}/logs"
ADA_STATE="${ADA_HOME}/state"
ADA_LOCK="${ADA_HOME}/watch.lock"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICES_JSON="${SCRIPT_DIR}/services.json"

MAX_LOG_BYTES=$((2 * 1024 * 1024))  # 2 MB per service
CRASH_LOOP_THRESHOLD=5
CRASH_LOOP_WINDOW=120  # seconds
STOP_GRACE=5           # seconds before SIGKILL

# ── Colors & Glyphs ─────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RST='\033[0m'
    BOLD='\033[1m'
    RED='\033[31m'
    GREEN='\033[32m'
    YELLOW='\033[33m'
    CYAN='\033[36m'
    DIM='\033[2m'
else
    RST='' BOLD='' RED='' GREEN='' YELLOW='' CYAN='' DIM=''
fi

# ── Init ─────────────────────────────────────────────────────────────────────
mkdir -p "${ADA_PIDS}" "${ADA_LOGS}" "${ADA_STATE}"

# ── Helpers ──────────────────────────────────────────────────────────────────
die()  { echo -e "${RED}error:${RST} $*" >&2; exit 1; }
info() { echo -e "${CYAN}▸${RST} $*"; }
warn() { echo -e "${YELLOW}▸${RST} $*"; }

expand_tilde() { echo "${1/#\~/$HOME}"; }

service_names() {
    jq -r '.[].name' "${SERVICES_JSON}"
}

enabled_names() {
    jq -r '.[] | select(.enabled == true) | .name' "${SERVICES_JSON}"
}

service_exists() {
    jq -e --arg n "$1" '.[] | select(.name == $n)' "${SERVICES_JSON}" >/dev/null 2>&1
}

service_field() {
    jq -r --arg n "$1" --arg f "$2" '.[] | select(.name == $n) | .[$f] // empty' "${SERVICES_JSON}"
}

pid_file()   { echo "${ADA_PIDS}/${1}.pid"; }
log_file()   { echo "${ADA_LOGS}/${1}.log"; }
state_file() { echo "${ADA_STATE}/${1}.json"; }

read_pid() {
    local pf
    pf="$(pid_file "$1")"
    [[ -f "${pf}" ]] && cat "${pf}" || echo ""
}

is_running() {
    local pid
    pid="$(read_pid "$1")"
    [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null
}

rotate_log() {
    local lf
    lf="$(log_file "$1")"
    if [[ -f "${lf}" ]]; then
        local sz
        sz=$(stat -c%s "${lf}" 2>/dev/null || echo 0)
        if (( sz > MAX_LOG_BYTES )); then
            tail -c "${MAX_LOG_BYTES}" "${lf}" > "${lf}.tmp"
            mv "${lf}.tmp" "${lf}"
        fi
    fi
}

# ── State management ─────────────────────────────────────────────────────────
init_state() {
    local sf
    sf="$(state_file "$1")"
    if [[ ! -f "${sf}" ]]; then
        echo '{"restart_count":0,"restart_times":[],"crash_loop":false,"started_at":null}' | jq '.' > "${sf}"
    fi
}

get_state() {
    local sf
    sf="$(state_file "$1")"
    init_state "$1"
    cat "${sf}"
}

set_state() {
    local sf
    sf="$(state_file "$1")"
    echo "$2" | jq '.' > "${sf}"
}

record_restart() {
    local name="$1"
    local now
    now=$(date +%s)
    local state
    state="$(get_state "${name}")"

    local cutoff=$(( now - CRASH_LOOP_WINDOW ))
    # Add this restart timestamp, prune old ones
    state=$(echo "${state}" | jq --argjson now "${now}" --argjson cutoff "${cutoff}" '
        .restart_times = ([.restart_times[] | select(. > $cutoff)] + [$now]) |
        .restart_count = (.restart_count + 1)
    ')

    local recent
    recent=$(echo "${state}" | jq --argjson cutoff "${cutoff}" '
        [.restart_times[] | select(. > $cutoff)] | length
    ')

    if (( recent > CRASH_LOOP_THRESHOLD )); then
        state=$(echo "${state}" | jq '.crash_loop = true')
    fi

    set_state "${name}" "${state}"
}

clear_crash_loop() {
    local name="$1"
    local state
    state="$(get_state "${name}")"
    state=$(echo "${state}" | jq '.crash_loop = false | .restart_times = [] | .restart_count = 0')
    set_state "${name}" "${state}"
}

is_crash_loop() {
    local state
    state="$(get_state "$1")"
    [[ "$(echo "${state}" | jq -r '.crash_loop')" == "true" ]]
}

get_restart_count() {
    local state
    state="$(get_state "$1")"
    echo "${state}" | jq -r '.restart_count'
}

get_started_at() {
    local state
    state="$(get_state "$1")"
    echo "${state}" | jq -r '.started_at // empty'
}

set_started_at() {
    local name="$1"
    local now
    now=$(date +%s)
    local state
    state="$(get_state "${name}")"
    state=$(echo "${state}" | jq --argjson t "${now}" '.started_at = $t')
    set_state "${name}" "${state}"
}

clear_started_at() {
    local name="$1"
    local state
    state="$(get_state "${name}")"
    state=$(echo "${state}" | jq '.started_at = null')
    set_state "${name}" "${state}"
}

# ── Core: start / stop ──────────────────────────────────────────────────────
do_start() {
    local name="$1"
    service_exists "${name}" || die "unknown service: ${name}"

    if is_running "${name}"; then
        info "${name} is already running (PID $(read_pid "${name}"))"
        return 0
    fi

    local cmd dir env_file
    cmd="$(service_field "${name}" cmd)"
    dir="$(expand_tilde "$(service_field "${name}" dir)")"
    env_file="$(service_field "${name}" env_file)"

    [[ -d "${dir}" ]] || die "working directory does not exist: ${dir}"

    local lf
    lf="$(log_file "${name}")"
    rotate_log "${name}"

    # Build the command with optional env_file sourcing
    local full_cmd=""
    if [[ -n "${env_file}" ]]; then
        env_file="$(expand_tilde "${env_file}")"
        if [[ -f "${env_file}" ]]; then
            full_cmd="set -a; source '${env_file}'; set +a; "
        else
            warn "env_file not found: ${env_file} — starting without it"
        fi
    fi
    full_cmd+="${cmd}"

    # Launch in background with nohup-like behavior
    cd "${dir}"
    bash -c "${full_cmd}" >> "${lf}" 2>&1 &
    local pid=$!
    cd - >/dev/null

    echo "${pid}" > "$(pid_file "${name}")"
    set_started_at "${name}"

    # Verify it actually started (small grace period)
    sleep 0.3
    if kill -0 "${pid}" 2>/dev/null; then
        info "${name} started (PID ${pid})"
    else
        warn "${name} exited immediately — check: ada logs ${name}"
        rm -f "$(pid_file "${name}")"
        clear_started_at "${name}"
        return 1
    fi
}

do_stop() {
    local name="$1"
    service_exists "${name}" || die "unknown service: ${name}"

    local pid
    pid="$(read_pid "${name}")"

    if [[ -z "${pid}" ]] || ! kill -0 "${pid}" 2>/dev/null; then
        info "${name} is not running"
        rm -f "$(pid_file "${name}")"
        clear_started_at "${name}"
        return 0
    fi

    info "stopping ${name} (PID ${pid})..."

    # Graceful SIGTERM, then escalate
    kill -TERM "${pid}" 2>/dev/null || true

    local waited=0
    while (( waited < STOP_GRACE )); do
        if ! kill -0 "${pid}" 2>/dev/null; then
            break
        fi
        sleep 1
        waited=$(( waited + 1 ))
    done

    if kill -0 "${pid}" 2>/dev/null; then
        warn "PID ${pid} did not exit — sending SIGKILL"
        kill -KILL "${pid}" 2>/dev/null || true
        sleep 0.5
    fi

    rm -f "$(pid_file "${name}")"
    clear_started_at "${name}"
    info "${name} stopped"
}

do_restart() {
    local name="$1"
    service_exists "${name}" || die "unknown service: ${name}"
    clear_crash_loop "${name}"
    do_stop "${name}"
    do_start "${name}"
}

# ── Status ───────────────────────────────────────────────────────────────────
human_duration() {
    local secs="$1"
    if (( secs < 60 )); then
        echo "${secs}s"
    elif (( secs < 3600 )); then
        echo "$(( secs / 60 ))m $(( secs % 60 ))s"
    elif (( secs < 86400 )); then
        echo "$(( secs / 3600 ))h $(( (secs % 3600) / 60 ))m"
    else
        echo "$(( secs / 86400 ))d $(( (secs % 86400) / 3600 ))h"
    fi
}

last_log_line() {
    local lf
    lf="$(log_file "$1")"
    if [[ -f "${lf}" ]]; then
        local line
        # Strip ANSI escape codes for clean display
        line="$(tail -1 "${lf}" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | head -c 80)"
        echo "${line}"
    fi
}

# Repeat a character N times
repeat_char() {
    local ch="$1" count="$2"
    local i
    for (( i=0; i<count; i++ )); do
        printf '%s' "${ch}"
    done
}

do_status() {
    local now
    now=$(date +%s)

    # Column widths (content area, not including padding)
    local w_name=20 w_pid=8 w_state=12 w_up=10 w_rst=8 w_log=42

    # Build horizontal rules
    local rule_name rule_pid rule_state rule_up rule_rst rule_log
    rule_name="$(repeat_char '─' $((w_name + 2)))"
    rule_pid="$(repeat_char '─' $((w_pid + 2)))"
    rule_state="$(repeat_char '─' $((w_state + 2)))"
    rule_up="$(repeat_char '─' $((w_up + 2)))"
    rule_rst="$(repeat_char '─' $((w_rst + 2)))"
    rule_log="$(repeat_char '─' $((w_log + 2)))"

    printf "\n"
    # Top border
    printf "  ┌%s┬%s┬%s┬%s┬%s┬%s┐\n" \
        "${rule_name}" "${rule_pid}" "${rule_state}" "${rule_up}" "${rule_rst}" "${rule_log}"

    # Header row
    printf "  │ ${BOLD}%-${w_name}s${RST} │ ${BOLD}%-${w_pid}s${RST} │ ${BOLD}%-${w_state}s${RST} │ ${BOLD}%-${w_up}s${RST} │ ${BOLD}%-${w_rst}s${RST} │ ${BOLD}%-${w_log}s${RST} │\n" \
        "SERVICE" "PID" "STATE" "UPTIME" "RESTARTS" "LAST LOG"

    # Header separator
    printf "  ├%s┼%s┼%s┼%s┼%s┼%s┤\n" \
        "${rule_name}" "${rule_pid}" "${rule_state}" "${rule_up}" "${rule_rst}" "${rule_log}"

    local names
    names="$(service_names)"
    if [[ -z "${names}" ]]; then
        printf "  │ ${DIM}%-$(( w_name + w_pid + w_state + w_up + w_rst + w_log + 12 ))s${RST}│\n" "(no services configured)"
        printf "  └%s┴%s┴%s┴%s┴%s┴%s┘\n" \
            "${rule_name}" "${rule_pid}" "${rule_state}" "${rule_up}" "${rule_rst}" "${rule_log}"
        printf "\n"
        return
    fi

    while IFS= read -r name; do
        local pid state state_color uptime_str restarts last_line enabled line_color

        enabled="$(service_field "${name}" enabled)"
        pid="$(read_pid "${name}")"
        restarts="$(get_restart_count "${name}")"
        last_line="$(last_log_line "${name}")"
        line_color=""

        # Truncate last_line to fit column
        if (( ${#last_line} > w_log )); then
            last_line="${last_line:0:$(( w_log - 3 ))}..."
        fi

        if is_crash_loop "${name}"; then
            state="CRASH-LOOP"
            state_color="${RED}${BOLD}"
            line_color="${RED}"
            pid="-"
            uptime_str="-"
        elif [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
            state="running"
            state_color="${GREEN}"
            local started_at
            started_at="$(get_started_at "${name}")"
            if [[ -n "${started_at}" ]]; then
                uptime_str="$(human_duration $(( now - started_at )))"
            else
                uptime_str="?"
            fi
        else
            pid="-"
            if [[ "${enabled}" == "true" ]]; then
                state="stopped"
                state_color="${YELLOW}"
            else
                state="disabled"
                state_color="${DIM}"
            fi
            uptime_str="-"
            # Clean stale pid file
            rm -f "$(pid_file "${name}")" 2>/dev/null
        fi

        printf "  │ ${line_color}%-${w_name}s${RST} │ ${line_color}%-${w_pid}s${RST} │ ${state_color}%-${w_state}s${RST} │ ${line_color}%-${w_up}s${RST} │ ${line_color}%-${w_rst}s${RST} │ ${DIM}%-${w_log}s${RST} │\n" \
            "${name}" "${pid}" "${state}" "${uptime_str}" "${restarts}" "${last_line}"

    done <<< "${names}"

    # Bottom border
    printf "  └%s┴%s┴%s┴%s┴%s┴%s┘\n" \
        "${rule_name}" "${rule_pid}" "${rule_state}" "${rule_up}" "${rule_rst}" "${rule_log}"

    printf "\n"

    # Watch status
    if [[ -f "${ADA_LOCK}" ]]; then
        local watch_pid
        watch_pid="$(cat "${ADA_LOCK}" 2>/dev/null)"
        if [[ -n "${watch_pid}" ]] && kill -0 "${watch_pid}" 2>/dev/null; then
            printf "  ${GREEN}◉${RST} ${DIM}supervisor running (PID ${watch_pid})${RST}\n"
        else
            printf "  ${YELLOW}◌${RST} ${DIM}supervisor not running (stale lock)${RST}\n"
            rm -f "${ADA_LOCK}"
        fi
    else
        printf "  ${YELLOW}◌${RST} ${DIM}supervisor not running${RST}\n"
    fi
    printf "\n"
}

# ── Logs ─────────────────────────────────────────────────────────────────────
do_logs() {
    local name="$1"
    shift
    service_exists "${name}" || die "unknown service: ${name}"

    local lf
    lf="$(log_file "${name}")"

    if [[ ! -f "${lf}" ]]; then
        die "no log file for ${name} yet"
    fi

    local lines=""
    local follow=true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n) lines="$2"; follow=false; shift 2 ;;
            -f) follow=true; shift ;;
            *)  die "unknown option: $1" ;;
        esac
    done

    if [[ -n "${lines}" ]]; then
        tail -n "${lines}" "${lf}"
    else
        if $follow; then
            tail -f "${lf}"
        else
            tail -n 50 "${lf}"
        fi
    fi
}

# ── Add / Remove ─────────────────────────────────────────────────────────────
do_add() {
    local name="$1" cmd="$2" dir="$3"
    local env_file="${4:-}"

    if service_exists "${name}"; then
        die "service '${name}' already exists"
    fi

    local new_entry
    if [[ -n "${env_file}" ]]; then
        new_entry=$(jq -n --arg n "${name}" --arg c "${cmd}" --arg d "${dir}" --arg e "${env_file}" \
            '{name:$n, cmd:$c, dir:$d, env_file:$e, enabled:true}')
    else
        new_entry=$(jq -n --arg n "${name}" --arg c "${cmd}" --arg d "${dir}" \
            '{name:$n, cmd:$c, dir:$d, env_file:null, enabled:true}')
    fi

    local updated
    updated=$(jq --argjson entry "${new_entry}" '. + [$entry]' "${SERVICES_JSON}")
    echo "${updated}" > "${SERVICES_JSON}"

    info "added service: ${name}"
}

do_remove() {
    local name="$1"
    service_exists "${name}" || die "unknown service: ${name}"

    if is_running "${name}"; then
        info "stopping ${name} first..."
        do_stop "${name}"
    fi

    local updated
    updated=$(jq --arg n "${name}" '[.[] | select(.name != $n)]' "${SERVICES_JSON}")
    echo "${updated}" > "${SERVICES_JSON}"

    # Cleanup state files
    rm -f "$(pid_file "${name}")" "$(state_file "${name}")"
    info "removed service: ${name}"
}

# ── Watch (supervisor) ───────────────────────────────────────────────────────
do_watch() {
    # Prevent double supervisors
    if [[ -f "${ADA_LOCK}" ]]; then
        local existing_pid
        existing_pid="$(cat "${ADA_LOCK}" 2>/dev/null)"
        if [[ -n "${existing_pid}" ]] && kill -0 "${existing_pid}" 2>/dev/null; then
            die "supervisor already running (PID ${existing_pid}). Stop it first or remove ${ADA_LOCK}"
        fi
        rm -f "${ADA_LOCK}"
    fi

    echo $$ > "${ADA_LOCK}"

    # Cleanup lock on exit
    trap 'rm -f "${ADA_LOCK}"; exit' INT TERM EXIT

    info "supervisor started (PID $$)"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] supervisor started (PID $$)" >> "${ADA_LOGS}/watch.log"

    while true; do
        # Re-read services.json each loop so new services are picked up
        if [[ ! -f "${SERVICES_JSON}" ]]; then
            sleep 10
            continue
        fi

        local names
        names="$(enabled_names 2>/dev/null)" || true

        if [[ -n "${names}" ]]; then
            while IFS= read -r name; do
                # Skip crash-looped services
                if is_crash_loop "${name}"; then
                    continue
                fi

                if ! is_running "${name}"; then
                    local had_pid_file=false
                    [[ -f "$(pid_file "${name}")" ]] && had_pid_file=true

                    warn "service '${name}' is not running — restarting..."
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] auto-restarting ${name}" >> "${ADA_LOGS}/watch.log"

                    record_restart "${name}"

                    if is_crash_loop "${name}"; then
                        echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ${name} entered crash-loop — giving up${RST}" >&2
                        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${name} entered CRASH-LOOP (>${CRASH_LOOP_THRESHOLD} restarts in ${CRASH_LOOP_WINDOW}s)" >> "${ADA_LOGS}/watch.log"
                        local lf
                        lf="$(log_file "${name}")"
                        if [[ -f "${lf}" ]]; then
                            echo "[$(date '+%Y-%m-%d %H:%M:%S')] last log: $(tail -1 "${lf}")" >> "${ADA_LOGS}/watch.log"
                        fi
                        continue
                    fi

                    do_start "${name}" 2>/dev/null || true
                fi
            done <<< "${names}"
        fi

        sleep 10
    done
}

# ── Enable / Disable ────────────────────────────────────────────────────────
do_enable() {
    local name="$1"
    service_exists "${name}" || die "unknown service: ${name}"
    local updated
    updated=$(jq --arg n "${name}" '[.[] | if .name == $n then .enabled = true else . end]' "${SERVICES_JSON}")
    echo "${updated}" > "${SERVICES_JSON}"
    info "enabled: ${name}"
}

do_disable() {
    local name="$1"
    service_exists "${name}" || die "unknown service: ${name}"
    local updated
    updated=$(jq --arg n "${name}" '[.[] | if .name == $n then .enabled = false else . end]' "${SERVICES_JSON}")
    echo "${updated}" > "${SERVICES_JSON}"
    info "disabled: ${name}"
}

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
    cat <<'USAGE'

  ada — service manager for desktop jobs

  USAGE
    ada status                 Show status of all services
    ada start <name|all>       Start a service (or all enabled)
    ada stop <name|all>        Stop a service (or all)
    ada restart <name|all>     Restart a service (or all)
    ada logs <name> [-n N]     Tail logs (or last N lines)
    ada add <name> <cmd> <dir> [env_file]
                               Add a new service
    ada remove <name>          Remove a service (stops it first)
    ada enable <name>          Enable a service
    ada disable <name>         Disable a service
    ada watch                  Start the supervisor loop
    ada help                   Show this help

USAGE
}

# ── Dispatch ─────────────────────────────────────────────────────────────────
cmd="${1:-status}"
shift || true

case "${cmd}" in
    status|st)
        do_status
        ;;

    start)
        [[ $# -lt 1 ]] && die "usage: ada start <name|all>"
        if [[ "$1" == "all" ]]; then
            while IFS= read -r name; do
                do_start "${name}"
            done <<< "$(enabled_names)"
        else
            do_start "$1"
        fi
        ;;

    stop)
        [[ $# -lt 1 ]] && die "usage: ada stop <name|all>"
        if [[ "$1" == "all" ]]; then
            while IFS= read -r name; do
                if is_running "${name}"; then
                    do_stop "${name}"
                fi
            done <<< "$(service_names)"
        else
            do_stop "$1"
        fi
        ;;

    restart)
        [[ $# -lt 1 ]] && die "usage: ada restart <name|all>"
        if [[ "$1" == "all" ]]; then
            while IFS= read -r name; do
                do_restart "${name}"
            done <<< "$(enabled_names)"
        else
            do_restart "$1"
        fi
        ;;

    logs|log)
        [[ $# -lt 1 ]] && die "usage: ada logs <name> [-n N]"
        do_logs "$@"
        ;;

    add)
        [[ $# -lt 3 ]] && die "usage: ada add <name> <cmd> <dir> [env_file]"
        do_add "$@"
        ;;

    remove|rm)
        [[ $# -lt 1 ]] && die "usage: ada remove <name>"
        do_remove "$1"
        ;;

    enable)
        [[ $# -lt 1 ]] && die "usage: ada enable <name>"
        do_enable "$1"
        ;;

    disable)
        [[ $# -lt 1 ]] && die "usage: ada disable <name>"
        do_disable "$1"
        ;;

    watch)
        do_watch
        ;;

    help|--help|-h)
        usage
        ;;

    *)
        die "unknown command: ${cmd}  (try: ada help)"
        ;;
esac
