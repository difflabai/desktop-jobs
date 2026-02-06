#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  ada — a dead-simple service manager for desktop jobs                      ║
# ║  No dependencies beyond bash (4+), jq, and standard unix tools.            ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Usage: ada <command> [args]
# Run `ada help` for details.

set -uo pipefail
# NOTE: We intentionally do NOT use `set -e` because the supervisor loop and
# many status checks must tolerate non-zero exits gracefully.

readonly ADA_VERSION="1.0.0"

# ── Paths ─────────────────────────────────────────────────────────────────────
readonly ADA_HOME="${HOME}/.ada"
readonly ADA_PIDS="${ADA_HOME}/pids"
readonly ADA_LOGS="${ADA_HOME}/logs"
readonly ADA_STATE="${ADA_HOME}/state"
readonly ADA_LOCK="${ADA_HOME}/watch.lock"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SERVICES_JSON="${SCRIPT_DIR}/services.json"

readonly MAX_LOG_BYTES=$((2 * 1024 * 1024))   # 2 MB per service log
readonly CRASH_LOOP_THRESHOLD=5                 # restarts within window
readonly CRASH_LOOP_WINDOW=120                  # seconds
readonly STOP_GRACE=5                           # seconds before SIGKILL
readonly WATCH_INTERVAL=10                      # supervisor poll interval

# ── Colors & Glyphs ──────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    readonly RST=$'\033[0m'
    readonly BOLD=$'\033[1m'
    readonly DIM=$'\033[2m'
    readonly RED=$'\033[31m'
    readonly GREEN=$'\033[32m'
    readonly YELLOW=$'\033[33m'
    readonly BLUE=$'\033[34m'
    readonly CYAN=$'\033[36m'
    readonly WHITE=$'\033[37m'
    readonly BG_RED=$'\033[41m'
    readonly BG_GREEN=$'\033[42m'
else
    readonly RST='' BOLD='' DIM='' RED='' GREEN='' YELLOW='' BLUE='' CYAN='' WHITE='' BG_RED='' BG_GREEN=''
fi

# ── Init directories ─────────────────────────────────────────────────────────
mkdir -p "${ADA_PIDS}" "${ADA_LOGS}" "${ADA_STATE}"

# ── Helpers ───────────────────────────────────────────────────────────────────
die()  { printf '%b\n' "${RED}${BOLD}error:${RST} $*" >&2; exit 1; }
info() { printf '%b\n' "${CYAN}▸${RST} $*"; }
warn() { printf '%b\n' "${YELLOW}▸${RST} $*"; }
ok()   { printf '%b\n' "${GREEN}✓${RST} $*"; }

expand_tilde() { printf '%s' "${1/#\~/$HOME}"; }

# ── JSON helpers ──────────────────────────────────────────────────────────────
require_config() {
    [[ -f "${SERVICES_JSON}" ]] || die "config not found: ${SERVICES_JSON}"
    jq empty "${SERVICES_JSON}" 2>/dev/null || die "invalid JSON in ${SERVICES_JSON}"
}

service_names() {
    jq -r '.[].name' "${SERVICES_JSON}" 2>/dev/null
}

enabled_names() {
    jq -r '.[] | select(.enabled == true) | .name' "${SERVICES_JSON}" 2>/dev/null
}

service_exists() {
    jq -e --arg n "$1" '.[] | select(.name == $n)' "${SERVICES_JSON}" >/dev/null 2>&1
}

service_field() {
    jq -r --arg n "$1" --arg f "$2" \
        '.[] | select(.name == $n) | .[$f] // empty' "${SERVICES_JSON}" 2>/dev/null
}

# Atomic write to services.json (write to temp, then mv)
write_services() {
    local tmp="${SERVICES_JSON}.tmp.$$"
    if printf '%s\n' "$1" | jq '.' > "${tmp}" 2>/dev/null; then
        mv -f "${tmp}" "${SERVICES_JSON}"
    else
        rm -f "${tmp}"
        die "failed to write services.json — JSON was invalid"
    fi
}

# ── PID / process helpers ────────────────────────────────────────────────────
pid_file()   { printf '%s' "${ADA_PIDS}/${1}.pid"; }
log_file()   { printf '%s' "${ADA_LOGS}/${1}.log"; }
state_file() { printf '%s' "${ADA_STATE}/${1}.json"; }

read_pid() {
    local pf
    pf="$(pid_file "$1")"
    [[ -f "${pf}" ]] && cat "${pf}" 2>/dev/null || printf ''
}

is_running() {
    local pid
    pid="$(read_pid "$1")"
    [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null
}

# ── Log rotation ─────────────────────────────────────────────────────────────
rotate_log() {
    local lf
    lf="$(log_file "$1")"
    [[ -f "${lf}" ]] || return 0
    local sz
    sz=$(stat -c%s "${lf}" 2>/dev/null || stat -f%z "${lf}" 2>/dev/null || echo 0)
    if (( sz > MAX_LOG_BYTES )); then
        local keep=$(( MAX_LOG_BYTES * 3 / 4 ))
        tail -c "${keep}" "${lf}" > "${lf}.rotate.$$" 2>/dev/null && \
            mv -f "${lf}.rotate.$$" "${lf}" || \
            rm -f "${lf}.rotate.$$"
    fi
}

# ── State management ─────────────────────────────────────────────────────────
init_state() {
    local sf
    sf="$(state_file "$1")"
    [[ -f "${sf}" ]] && return 0
    cat > "${sf}" <<'STATEEOF'
{"restart_count":0,"restart_times":[],"crash_loop":false,"started_at":null}
STATEEOF
}

get_state() {
    init_state "$1"
    cat "$(state_file "$1")"
}

set_state() {
    local sf
    sf="$(state_file "$1")"
    local tmp="${sf}.tmp.$$"
    if printf '%s\n' "$2" | jq '.' > "${tmp}" 2>/dev/null; then
        mv -f "${tmp}" "${sf}"
    else
        rm -f "${tmp}"
    fi
}

record_restart() {
    local name="$1"
    local now
    now=$(date +%s)
    local state cutoff
    state="$(get_state "${name}")"
    cutoff=$(( now - CRASH_LOOP_WINDOW ))

    state=$(printf '%s' "${state}" | jq --argjson now "${now}" --argjson cutoff "${cutoff}" '
        .restart_times = ([.restart_times[] | select(. > $cutoff)] + [$now]) |
        .restart_count = (.restart_count + 1)
    ')

    local recent
    recent=$(printf '%s' "${state}" | jq '[.restart_times[]] | length')

    if (( recent > CRASH_LOOP_THRESHOLD )); then
        state=$(printf '%s' "${state}" | jq '.crash_loop = true')
    fi

    set_state "${name}" "${state}"
}

clear_crash_loop() {
    local state
    state="$(get_state "$1")"
    state=$(printf '%s' "${state}" | jq '.crash_loop = false | .restart_times = [] | .restart_count = 0')
    set_state "$1" "${state}"
}

is_crash_loop() {
    [[ "$(get_state "$1" | jq -r '.crash_loop')" == "true" ]]
}

get_restart_count() {
    get_state "$1" | jq -r '.restart_count'
}

get_started_at() {
    get_state "$1" | jq -r '.started_at // empty'
}

set_started_at() {
    local now
    now=$(date +%s)
    local state
    state="$(get_state "$1")"
    state=$(printf '%s' "${state}" | jq --argjson t "${now}" '.started_at = $t')
    set_state "$1" "${state}"
}

clear_started_at() {
    local state
    state="$(get_state "$1")"
    state=$(printf '%s' "${state}" | jq '.started_at = null')
    set_state "$1" "${state}"
}

# ── Core: start ──────────────────────────────────────────────────────────────
do_start() {
    local name="$1"
    service_exists "${name}" || die "unknown service: ${name}"

    if is_running "${name}"; then
        info "${name} already running ${DIM}(PID $(read_pid "${name}"))${RST}"
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

    # Build full command with optional env_file sourcing
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

    # Timestamp the start in the log
    printf '\n[%s] === ada starting %s ===\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${name}" >> "${lf}"

    # Launch in a new session so it survives terminal close.
    # setsid gives the child its own process group for clean stop.
    setsid bash -c "cd $(printf '%q' "${dir}") && exec bash -c $(printf '%q' "${full_cmd}")" \
        >> "${lf}" 2>&1 &
    local pid=$!
    disown "${pid}" 2>/dev/null || true

    printf '%s' "${pid}" > "$(pid_file "${name}")"
    set_started_at "${name}"

    # Give it a moment to fail fast
    sleep 0.5
    if kill -0 "${pid}" 2>/dev/null; then
        ok "${name} started ${DIM}(PID ${pid})${RST}"
    else
        warn "${name} exited immediately — check: ${BOLD}ada logs ${name}${RST}"
        rm -f "$(pid_file "${name}")"
        clear_started_at "${name}"
        return 1
    fi
}

# ── Core: stop ───────────────────────────────────────────────────────────────
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

    info "stopping ${name} ${DIM}(PID ${pid})${RST}..."

    # Try to kill the whole process group (catches child processes)
    local pgid
    pgid=$(ps -o pgid= -p "${pid}" 2>/dev/null | tr -d ' ')

    # Graceful SIGTERM
    if [[ -n "${pgid}" ]] && [[ "${pgid}" != "0" ]] && [[ "${pgid}" != "1" ]]; then
        kill -TERM -"${pgid}" 2>/dev/null || kill -TERM "${pid}" 2>/dev/null || true
    else
        kill -TERM "${pid}" 2>/dev/null || true
    fi

    # Wait for graceful shutdown
    local waited=0
    while (( waited < STOP_GRACE )); do
        kill -0 "${pid}" 2>/dev/null || break
        sleep 1
        (( waited++ )) || true
    done

    # Escalate to SIGKILL if still alive
    if kill -0 "${pid}" 2>/dev/null; then
        warn "PID ${pid} did not exit — sending SIGKILL"
        if [[ -n "${pgid}" ]] && [[ "${pgid}" != "0" ]] && [[ "${pgid}" != "1" ]]; then
            kill -KILL -"${pgid}" 2>/dev/null || true
        fi
        kill -KILL "${pid}" 2>/dev/null || true
        sleep 0.5
    fi

    # Log the stop
    local lf
    lf="$(log_file "${name}")"
    printf '[%s] === ada stopped %s ===\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${name}" >> "${lf}" 2>/dev/null

    rm -f "$(pid_file "${name}")"
    clear_started_at "${name}"
    ok "${name} stopped"
}

# ── Core: restart ────────────────────────────────────────────────────────────
do_restart() {
    local name="$1"
    service_exists "${name}" || die "unknown service: ${name}"
    clear_crash_loop "${name}"
    do_stop "${name}"
    do_start "${name}"
}

# ── Status ────────────────────────────────────────────────────────────────────
human_duration() {
    local secs="$1"
    if (( secs < 0 )); then
        printf '-'
    elif (( secs < 60 )); then
        printf '%ds' "${secs}"
    elif (( secs < 3600 )); then
        printf '%dm %ds' $(( secs / 60 )) $(( secs % 60 ))
    elif (( secs < 86400 )); then
        printf '%dh %dm' $(( secs / 3600 )) $(( (secs % 3600) / 60 ))
    else
        printf '%dd %dh' $(( secs / 86400 )) $(( (secs % 86400) / 3600 ))
    fi
}

last_log_line() {
    local lf
    lf="$(log_file "$1")"
    [[ -f "${lf}" ]] || return 0
    # Skip ada's own markers and blank lines to get actual service output
    local line
    line=$(tail -20 "${lf}" 2>/dev/null | grep -v '=== ada ' | grep -v '^$' | tail -1 | head -c 60)
    printf '%s' "${line}"
}

do_status() {
    require_config
    local now
    now=$(date +%s)

    local names
    names="$(service_names)"

    if [[ -z "${names}" ]]; then
        printf '\n  %bno services configured%b\n\n' "${DIM}" "${RST}"
        return
    fi

    local total=0 running=0 stopped=0 crashed=0

    printf '\n'
    printf '  %b%-18s  %-7s  %-12s  %-10s  %-4s  %s%b\n' \
        "${BOLD}" "SERVICE" "PID" "STATE" "UPTIME" "↻" "LAST OUTPUT" "${RST}"
    printf '  %b%.18s  %.7s  %.12s  %.10s  %.4s  %.40s%b\n' \
        "${DIM}" \
        "──────────────────" "───────" "────────────" "──────────" "────" \
        "────────────────────────────────────────" "${RST}"

    while IFS= read -r name; do
        [[ -z "${name}" ]] && continue
        (( total++ )) || true

        local pid state state_color uptime_str restarts last_line enabled line_color

        enabled="$(service_field "${name}" enabled)"
        pid="$(read_pid "${name}")"
        restarts="$(get_restart_count "${name}")"
        last_line="$(last_log_line "${name}")"

        if (( ${#last_line} > 40 )); then
            last_line="${last_line:0:37}..."
        fi

        line_color=""

        if is_crash_loop "${name}"; then
            state="CRASH-LOOP"
            state_color="${BG_RED}${WHITE}${BOLD}"
            line_color="${RED}"
            pid="-"
            uptime_str="-"
            (( crashed++ )) || true
        elif [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
            state="● running"
            state_color="${GREEN}"
            (( running++ )) || true
            local started_at
            started_at="$(get_started_at "${name}")"
            if [[ -n "${started_at}" ]] && [[ "${started_at}" != "null" ]]; then
                uptime_str="$(human_duration $(( now - started_at )))"
            else
                uptime_str="?"
            fi
        else
            pid="-"
            uptime_str="-"
            rm -f "$(pid_file "${name}")" 2>/dev/null
            if [[ "${enabled}" == "true" ]]; then
                state="○ stopped"
                state_color="${YELLOW}"
                (( stopped++ )) || true
            else
                state="○ disabled"
                state_color="${DIM}"
                (( stopped++ )) || true
            fi
        fi

        local restart_color=""
        if (( restarts > CRASH_LOOP_THRESHOLD )); then
            restart_color="${RED}"
        elif (( restarts > 0 )); then
            restart_color="${YELLOW}"
        fi

        printf '  %b%-18s%b  %b%-7s%b  %b%-12s%b  %-10s  %b%-4s%b  %b%s%b\n' \
            "${line_color}" "${name}" "${RST}" \
            "${DIM}" "${pid}" "${RST}" \
            "${state_color}" "${state}" "${RST}" \
            "${uptime_str}" \
            "${restart_color}" "${restarts}" "${RST}" \
            "${DIM}" "${last_line}" "${RST}"

    done <<< "${names}"

    printf '\n  '
    if (( running > 0 )); then
        printf '%b%d running%b' "${GREEN}" "${running}" "${RST}"
    fi
    if (( stopped > 0 )); then
        (( running > 0 )) && printf '  '
        printf '%b%d stopped%b' "${YELLOW}" "${stopped}" "${RST}"
    fi
    if (( crashed > 0 )); then
        printf '  %b%d crash-looped%b' "${RED}" "${crashed}" "${RST}"
    fi
    printf '  %b(%d total)%b\n' "${DIM}" "${total}" "${RST}"

    if [[ -f "${ADA_LOCK}" ]]; then
        local watch_pid
        watch_pid="$(cat "${ADA_LOCK}" 2>/dev/null)"
        if [[ -n "${watch_pid}" ]] && kill -0 "${watch_pid}" 2>/dev/null; then
            printf '  %b◉ supervisor active%b %b(PID %s)%b\n' \
                "${GREEN}" "${RST}" "${DIM}" "${watch_pid}" "${RST}"
        else
            printf '  %b◌ supervisor not running%b %b(stale lock)%b\n' \
                "${YELLOW}" "${RST}" "${DIM}" "${RST}"
            rm -f "${ADA_LOCK}"
        fi
    else
        printf '  %b◌ supervisor not running%b\n' "${DIM}" "${RST}"
    fi
    printf '\n'
}

# ── Logs ──────────────────────────────────────────────────────────────────────
do_logs() {
    local name="$1"
    shift
    service_exists "${name}" || die "unknown service: ${name}"

    local lf
    lf="$(log_file "${name}")"

    [[ -f "${lf}" ]] || die "no log file for ${name} yet — has it been started?"

    local lines=""
    local follow=true

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n)
                [[ $# -ge 2 ]] || die "-n requires a number"
                lines="$2"
                follow=false
                shift 2
                ;;
            -f)     follow=true;  shift ;;
            --tail) follow=false; shift ;;
            *)      die "unknown option: $1 (try: ada logs <name> [-n N] [-f])" ;;
        esac
    done

    if [[ -n "${lines}" ]]; then
        tail -n "${lines}" "${lf}"
    elif ${follow}; then
        info "tailing ${name} logs... ${DIM}(Ctrl+C to stop)${RST}"
        tail -f "${lf}"
    else
        tail -n 50 "${lf}"
    fi
}

# ── Add / Remove ──────────────────────────────────────────────────────────────
do_add() {
    local name="$1" cmd="$2" dir="$3"
    local env_file="${4:-}"

    require_config
    service_exists "${name}" && die "service '${name}' already exists"

    [[ "${name}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || \
        die "invalid service name: '${name}' (use alphanumeric, hyphens, dots, underscores)"

    local new_entry
    if [[ -n "${env_file}" ]]; then
        new_entry=$(jq -n \
            --arg n "${name}" --arg c "${cmd}" --arg d "${dir}" --arg e "${env_file}" \
            '{name:$n, cmd:$c, dir:$d, env_file:$e, enabled:true}')
    else
        new_entry=$(jq -n \
            --arg n "${name}" --arg c "${cmd}" --arg d "${dir}" \
            '{name:$n, cmd:$c, dir:$d, env_file:null, enabled:true}')
    fi

    local updated
    updated=$(jq --argjson entry "${new_entry}" '. + [$entry]' "${SERVICES_JSON}")
    write_services "${updated}"

    ok "added service: ${name}"
}

do_remove() {
    local name="$1"
    require_config
    service_exists "${name}" || die "unknown service: ${name}"

    if is_running "${name}"; then
        info "stopping ${name} first..."
        do_stop "${name}"
    fi

    local updated
    updated=$(jq --arg n "${name}" '[.[] | select(.name != $n)]' "${SERVICES_JSON}")
    write_services "${updated}"

    rm -f "$(pid_file "${name}")" "$(state_file "${name}")"
    ok "removed service: ${name}"
}

# ── Enable / Disable ─────────────────────────────────────────────────────────
do_enable() {
    local name="$1"
    require_config
    service_exists "${name}" || die "unknown service: ${name}"
    local updated
    updated=$(jq --arg n "${name}" \
        '[.[] | if .name == $n then .enabled = true else . end]' "${SERVICES_JSON}")
    write_services "${updated}"
    ok "enabled: ${name}"
}

do_disable() {
    local name="$1"
    require_config
    service_exists "${name}" || die "unknown service: ${name}"

    if is_running "${name}"; then
        info "stopping ${name} first..."
        do_stop "${name}"
    fi

    local updated
    updated=$(jq --arg n "${name}" \
        '[.[] | if .name == $n then .enabled = false else . end]' "${SERVICES_JSON}")
    write_services "${updated}"
    ok "disabled: ${name}"
}

# ── Watch (supervisor) ────────────────────────────────────────────────────────
watch_log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "${ADA_LOGS}/supervisor.log"
}

do_watch() {
    # Prevent double supervisors
    if [[ -f "${ADA_LOCK}" ]]; then
        local existing_pid
        existing_pid="$(cat "${ADA_LOCK}" 2>/dev/null)"
        if [[ -n "${existing_pid}" ]] && kill -0 "${existing_pid}" 2>/dev/null; then
            die "supervisor already running (PID ${existing_pid}). Kill it or remove ${ADA_LOCK}"
        fi
        rm -f "${ADA_LOCK}"
    fi

    printf '%s' $$ > "${ADA_LOCK}"

    trap 'rm -f "${ADA_LOCK}"; watch_log "supervisor stopped (PID $$)"; exit 0' INT TERM
    trap 'rm -f "${ADA_LOCK}"' EXIT

    ok "supervisor started ${DIM}(PID $$, polling every ${WATCH_INTERVAL}s)${RST}"
    watch_log "supervisor started (PID $$)"

    while true; do
        if [[ ! -f "${SERVICES_JSON}" ]]; then
            sleep "${WATCH_INTERVAL}"
            continue
        fi

        local names
        names="$(enabled_names 2>/dev/null)" || true

        if [[ -n "${names}" ]]; then
            while IFS= read -r name; do
                [[ -z "${name}" ]] && continue

                if is_crash_loop "${name}"; then
                    continue
                fi

                if ! is_running "${name}"; then
                    local had_pid=false
                    [[ -f "$(pid_file "${name}")" ]] && had_pid=true

                    local started_at
                    started_at="$(get_started_at "${name}")"
                    local was_started=false
                    [[ -n "${started_at}" ]] && [[ "${started_at}" != "null" ]] && was_started=true

                    if ${had_pid} || ${was_started}; then
                        watch_log "detected ${name} is down — restarting"
                        record_restart "${name}"

                        if is_crash_loop "${name}"; then
                            watch_log "CRASH-LOOP: ${name} (>${CRASH_LOOP_THRESHOLD} restarts in ${CRASH_LOOP_WINDOW}s)"
                            local lf
                            lf="$(log_file "${name}")"
                            if [[ -f "${lf}" ]]; then
                                watch_log "last log: $(tail -1 "${lf}" 2>/dev/null)"
                            fi
                            warn "${name} entered ${RED}CRASH-LOOP${RST} — giving up"
                            continue
                        fi

                        do_start "${name}" 2>/dev/null || {
                            watch_log "failed to restart ${name}"
                        }
                    fi
                fi
            done <<< "${names}"
        fi

        # Rotate logs periodically
        local all_names
        all_names="$(service_names 2>/dev/null)" || true
        if [[ -n "${all_names}" ]]; then
            while IFS= read -r name; do
                [[ -z "${name}" ]] && continue
                rotate_log "${name}"
            done <<< "${all_names}"
        fi

        sleep "${WATCH_INTERVAL}"
    done
}

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
    cat <<USAGEEOF

  ${BOLD}ada${RST} v${ADA_VERSION} — service manager for desktop jobs

  ${BOLD}COMMANDS${RST}
    ${GREEN}ada status${RST}                   Show status of all services
    ${GREEN}ada start${RST} <name|all>          Start a service (or all enabled)
    ${GREEN}ada stop${RST} <name|all>           Stop a service (or all)
    ${GREEN}ada restart${RST} <name|all>        Restart a service (or all)
    ${GREEN}ada logs${RST} <name> [-n N] [-f]   Tail logs (-f) or last N lines
    ${GREEN}ada add${RST} <name> <cmd> <dir> [env_file]
                                 Add a new service
    ${GREEN}ada remove${RST} <name>             Remove a service (stops first)
    ${GREEN}ada enable${RST} <name>             Enable a service
    ${GREEN}ada disable${RST} <name>            Disable a service
    ${GREEN}ada watch${RST}                     Start supervisor loop (foreground)

  ${BOLD}EXAMPLES${RST}
    ada start all                Start all enabled services
    ada logs ace-step -n 100     Last 100 lines of ace-step log
    nohup ada watch &            Run supervisor in background
    ada add my-api "node app.js" ~/projects/my-api ~/env.vars

  ${BOLD}FILES${RST}
    ${DIM}~/.ada/logs/<name>.log${RST}       Per-service log output
    ${DIM}~/.ada/pids/<name>.pid${RST}       PID tracking files
    ${DIM}~/.ada/state/<name>.json${RST}     Restart counters & state
    ${DIM}~/.ada/logs/supervisor.log${RST}   Supervisor activity log

USAGEEOF
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
resolve_targets() {
    local target="$1"
    local cmd_context="${2:-start}"
    if [[ "${target}" == "all" ]]; then
        if [[ "${cmd_context}" == "start" ]]; then
            enabled_names
        else
            service_names
        fi
    else
        printf '%s\n' "${target}"
    fi
}

cmd="${1:-}"
[[ -z "${cmd}" ]] && { usage; exit 0; }
shift

case "${cmd}" in
    status|st|s)
        do_status
        ;;

    start)
        require_config
        [[ $# -lt 1 ]] && die "usage: ada start <name|all>"
        targets="$(resolve_targets "$1" "start")"
        [[ -z "${targets}" ]] && die "no enabled services to start"
        while IFS= read -r name; do
            [[ -z "${name}" ]] && continue
            do_start "${name}"
        done <<< "${targets}"
        ;;

    stop)
        require_config
        [[ $# -lt 1 ]] && die "usage: ada stop <name|all>"
        targets="$(resolve_targets "$1" "stop")"
        while IFS= read -r name; do
            [[ -z "${name}" ]] && continue
            do_stop "${name}"
        done <<< "${targets}"
        ;;

    restart)
        require_config
        [[ $# -lt 1 ]] && die "usage: ada restart <name|all>"
        targets="$(resolve_targets "$1" "restart")"
        while IFS= read -r name; do
            [[ -z "${name}" ]] && continue
            do_restart "${name}"
        done <<< "${targets}"
        ;;

    logs|log|l)
        require_config
        [[ $# -lt 1 ]] && die "usage: ada logs <name> [-n N]"
        do_logs "$@"
        ;;

    add)
        require_config
        [[ $# -lt 3 ]] && die "usage: ada add <name> <cmd> <dir> [env_file]"
        do_add "$@"
        ;;

    remove|rm)
        require_config
        [[ $# -lt 1 ]] && die "usage: ada remove <name>"
        do_remove "$1"
        ;;

    enable)
        require_config
        [[ $# -lt 1 ]] && die "usage: ada enable <name>"
        do_enable "$1"
        ;;

    disable)
        require_config
        [[ $# -lt 1 ]] && die "usage: ada disable <name>"
        do_disable "$1"
        ;;

    watch|w)
        require_config
        do_watch
        ;;

    version|--version|-v)
        printf 'ada v%s\n' "${ADA_VERSION}"
        ;;

    help|--help|-h)
        usage
        ;;

    *)
        die "unknown command: ${cmd}  (try: ada help)"
        ;;
esac
