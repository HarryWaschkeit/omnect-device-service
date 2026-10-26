#!/bin/bash
#

. "$(dirname -- "${BASH_SOURCE[0]}")/healthchecklib.sh" || exit 2

# the core dumps of the current system run, and what kept them from being
# looked up
coredumps=
coredump_errors=

# puts the core dumps of the current system run into "coredumps"; returns 0
# when it could look for them, and 2 when it could not
#
# NOTE:
#   coredumpctl exits non-zero both when it found nothing and when it could
#   not run at all, so its exit status alone cannot tell a system without core
#   dumps from a check that never looked. "-q" silences the message about an
#   empty result, which leaves its diagnostics as the only difference between
#   the two.
function find_coredumps() {
    local up now since sinces errorfile rc=0

    # at first find out time span we want to have core dumps for as we inly want
    # to consider those that happened during this system run
    now=$(date +%s)
    up=$(set -- $(cat /proc/uptime); echo ${1%.*})
    sinces=$((now - up))
    since="$(date -d '@'"$sinces" +"%Y-%m-%d %H:%M:%S")"

    errorfile=$(mktemp) \
        || { coredump_errors="no temporary file to collect the lookup errors in"; return 2; }

    coredumps=$(coredumpctl -q --since "$since" 2>"$errorfile") || rc=$?
    coredump_errors=$(cat "$errorfile")
    rm -f "$errorfile"

    [ $rc -eq 0 -o -z "$coredump_errors" ] || return 2

    coredump_errors=
    return 0
}

# rates the core dumps of the current system run and returns that rating
function rate_coredumps() {
    local rating=0

    if ! find_coredumps; then
        error "core dumps could not be looked up: ${coredump_errors}"
        rating=2
    elif [ -n "${coredumps}" ]; then
        rating=2
    fi

    do_rate ${rating}

    return ${rating}
}

function do_check() {
    local rating=0

    rate_coredumps || rating=$?

    print_rating ${rating} "coredumps" "$ME"

    return ${rating}
}

function do_get_infos() {
    local rating=0

    rate_coredumps || rating=$?

    print_info_header "${ME}" "${rating}"
    [ -z "${coredumps}" ] || echo "${coredumps}"
    [ -z "${coredump_errors}" ] || echo "${coredump_errors}"

    return ${rating}
}

command="${1:-check}"
[ "$1" ] && shift
check_command_arg "$command"

# first argument must be either "check" or "get-infos"
case "$command" in
    check)
        do_check "$@"
        retval=$?
        ;;
    get-infos)
        do_get_infos "$@"
        retval=$?
        ;;
esac

exit $retval
