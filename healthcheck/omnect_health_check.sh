#!/bin/bash

HEALTHCHECK_DIR=/usr/lib/omnect/healthcheck

. ${HEALTHCHECK_DIR}/healthchecklib.sh

CFGFILE=omnect_health_checks.json
CFGFILEDIR=/etc/omnect/health_check
CFGFILEPATH="${CFGFILEDIR}/${CFGFILE}"

# the configured entries, read once: a second read could see a file that was
# replaced in between, and rate a run by entries the checks never saw
entries=()

# reads every configured entry into a line of its own, with its attributes
# joined by the unit separator
#
# NOTE:
#   the unit separator joins the attributes because IFS collapses consecutive
#   tabs or blanks, which would make an entry without a "type" attribute look
#   like one that has it
#
# NOTE:
#   an entry is framed by a line, so a line break a JSON string carries is
#   replaced by a blank: it would otherwise end the entry early and turn the
#   remainder of the attribute into an entry of its own
#
# NOTE:
#   the line breaks are replaced without a regular expression, because omnect
#   OS builds jq without oniguruma and the regex builtins are not available
#   there
#
# NOTE:
#   jq's exit status decides here: on a malformed config file it prints the
#   entries it could read before giving up, and checking only those would rate
#   a device whose remaining checks never ran
function read_entries() {
    local cfgfile="$1" rawentries

    rawentries=$(jq -r 'def flat: tostring | split("\n") | join(" ") | split("\r") | join(" "); .[] | [ (."type" // "" | flat), (."name" // "" | flat), (."extra-args" // "" | flat) ] | join("\u001f")' "$cfgfile") \
	|| return 2

    [ "$rawentries" ] && mapfile -t entries <<<"$rawentries"

    return 0
}

# reports every name the caller asked for that none of the entries carries,
# one name per line; returns 1 when it found any
function verify_check_names() {
    local check entry type name known=()

    # nothing to verify
    [ $# -gt 0 ] || return 0

    for entry in "${entries[@]}"; do
	IFS=$'\037' read -r type name _ <<<"$entry"
	[ -z "$type" ] || known+=("$type")
	[ -z "$name" ] || known+=("$name")
    done

    local unknown_checks=()
    for check; do
	in_list "$check" "${known[@]}" || unknown_checks+=("$check")
    done

    # one name per line, so a name containing a blank stays one name
    [ ${#unknown_checks[@]} -gt 0 ] || return 0
    printf '%s\n' "${unknown_checks[@]}"

    return 1
}

function do__cmd() {
    local cmd="$1"
    local output_when="$2" # 0 = never, 1 = failed only, 2 = all
    local cfgfile="$3"
    shift 3
    local selected_checks=("$@")
    local nchecked nchecks check i name type extra_args
    local output retval entry

    nchecked=0
    nchecks=${#entries[@]}
    [ $nchecks -gt 0 ] \
	|| warn "no checks defined in config file \"$cfgfile\""

    i=0
    for entry in "${entries[@]}"; do
        i=$((i + 1))

        IFS=$'\037' read -r type name extra_args <<<"$entry"
        : ${name:=$type}

        # an entry nobody asked for must not rate this run, no matter whether
        # it could be run at all; an entry without a type may still carry the
        # name it was selected by
        if [ ${#selected_checks[@]} -gt 0 ] \
           && ! in_list "$name" "${selected_checks[@]}" \
           && ! in_list "$type" "${selected_checks[@]}"; then
            continue
        fi

        # an entry that cannot name the check it stands for is still the entry
        # that rates this run, so it is named by what it has
        [ "$type" ] \
            || { error "entry $i in \"$cfgfile\" is missing \"type\" attribute"; print_rating 2 "${name:-entry $i}" "${cfgfile##*/}"; do_rate 2; nchecked=$((nchecked + 1)); continue; }

        check="${HEALTHCHECK_DIR}/omnect_health__${type}.sh"
        if [ ! -x "$check" ]; then
            local rate=2
            error "check \"$check\" for type \"$type\" (entry $i in \"$cfgfile\") cannot be called"
            print_rating $rate ${type} "${check##*/}"
            do_rate $rate
            nchecked=$((nchecked + 1))
            continue
        fi

        output=$($check $cmd $extra_args)
        retval=$?

        if [ $output_when = 2 -o $output_when = 1 -a $retval != 0 ]; then
            echo "$output"
        fi

	# a check that rates this run has to be named where the rating is
	# read: the dispatcher stands in whenever the check left nothing but
	# its exit status behind, so a check of its own cannot reopen this gap
	if [ "$retval" -gt 2 ]; then
	    print_rating 2 "$name" "${check##*/}"
	elif [ "$retval" -ne 0 -a -z "$output" ]; then
	    print_rating "$retval" "$name" "${check##*/}"
	fi
	do_rate $retval "${check##*/}"
        nchecked=$((nchecked + 1))

    done

    # a device nothing was checked on is not healthy, it is unknown
    [ $nchecked -gt 0 ] \
	|| { error "no check was run, health of this device is unknown"; do_rate 1; }
}

function do_checks() {
    local cfgfile="$1"
    shift

    do__cmd check 2 "$cfgfile" "$@"
}

function do_get_infos() {
    local cfgfile="$1"
    shift

    do__cmd get-infos 1 "$cfgfile" "$@"
}

# let's set "check" as default command and allow parameter-less invocation
command="${1:-check}"
[ "$1" ] && shift
check_command_arg "$command"

[ -r "${CFGFILEPATH}" ] || { fatal "configuration file \"${CFGFILEPATH}\" not found"; exit 1; }

if read_entries "${CFGFILEPATH}"; then
    # the arguments following the command are optional and name the checks to
    # be run
    if unknown=$(verify_check_names "$@"); then
	case "$command" in
	    check)
		do_checks "${CFGFILEPATH}" "$@"
		;;
	    get-infos)
		do_get_infos "${CFGFILEPATH}" "$@"
		;;
	esac
    else
	mapfile -t unknown_checks <<<"$unknown"
	printf -v unknown_list '%s, ' "${unknown_checks[@]}"
	error "unknown check name(s) [${unknown_list%, }]"
	exit 1
    fi
else
    # the entries this run was to be made of are unknown, so there is nothing
    # left to run - but the run still has to be rated where the caller reads
    # the rating, and the cause named next to it
    error "config file \"${CFGFILEPATH}\" could not be read"
    print_rating 2 "${CFGFILE}" "${ME}"
    do_rate 2
fi

get_overall_rating
ret=$?

[ "$command" = check ] && echo -e "\nOVERALL: $(print_rating)"

exit $ret
