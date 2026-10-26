#!/bin/bash
#

. "$(dirname -- "${BASH_SOURCE[0]}")/healthchecklib.sh" || exit 2

# the core dumps of the current system run, what kept them from being looked
# up, and which parts of the journal could not be searched
coredumps=
coredump_errors=
coredump_skipped=

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
    local up now since sinces out rc=0

    # at first find out time span we want to have core dumps for as we inly want
    # to consider those that happened during this system run
    now=$(date +%s)
    up=$(set -- $(cat /proc/uptime); echo ${1%.*})
    sinces=$((now - up))
    since="$(date -d '@'"$sinces" +"%Y-%m-%d %H:%M:%S")"

    # both streams can share a variable: core dumps are only ever printed when
    # coredumpctl succeeds, and the diagnostics are sorted out right below
    out=$(coredumpctl -q --since "$since" 2>&1) || rc=$?

    # a journal file systemd had to skip is not a failed lookup - the other
    # files were searched - but it does leave a blind spot, so keep it apart
    # from both the findings and the real errors
    coredump_skipped=$(grep -F 'ignoring file.' <<<"$out")
    out=$(grep -vF 'ignoring file.' <<<"$out")

    coredump_errors=
    coredumps=

    if [ $rc -eq 0 ]; then
        coredumps="$out"
        return 0
    fi

    [ -z "$out" ] || { coredump_errors="$out"; return 2; }

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
    elif [ -n "${coredump_skipped}" ]; then
        # the searchable part of the journal held no core dump, but the skipped
        # part may have, so there is evidence neither way
        error "core dumps could only be looked up in part of the journal: ${coredump_skipped}"
        rating=1
    fi

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
    [ -z "${coredump_skipped}" ] || echo "${coredump_skipped}"

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
