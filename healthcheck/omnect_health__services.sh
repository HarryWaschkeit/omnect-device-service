#!/bin/sh
#
# Purpose of this script is to analyze service log files and rate their
# content, and hence the status of the respective service, as running normal,
# bearing warnings or failing at all.
#
# As it is completely service specific which entries lead wo what rating this
# kind of information needs to be passed along with the service log files to
# be processed.
#
# An additional requirement is to have multiple files with specifications of
# log entry

. healthchecklib.sh

: ${CFGDIR:=/etc/omnect/health_check}
: ${CFGFILE:=omnect_service_log_analysis.json}
CFGFILEPATH="${CFGDIR}/${CFGFILE}"

: ${LOGDIR:=/run/omnect_health_log}
: ${ANALYSISDIR:=/run/omnect_health_log}

function do_check() {
    local jquery nentries service hasratings rating servicelog

    nentries=$(jq '.services | length' "$CFGFILEPATH")
    [ "$check_services" ] || check_services=$(jq -r '[ .services[].service ] | join(" ")' "$CFGFILEPATH")
    for ((n=0; n < nentries; n++)); do
	rating=0

	service=$(jq -r ".services[$n].service" "$CFGFILEPATH")
	[ "$(echo $check_services | grep -w "$service")" ] || continue

	servicelog="$LOGDIR/${service}.exit-log"
	if [ ! -r "$servicelog" ]; then
	    print_rating $rating "$service" "$ME"
	    continue
	fi

	hasratings=$(jq ".services[$n] | has(\".ratings\")" "$CFGFILEPATH")
	if $hasratings; then
	    jquery=$(jq '.services[] | if (has("ratings")) then .ratings else empty end | map("(.infos[] | select(" + .condition + ")) += { \"rating\": \"" + .rating + "\"}") | join(" | ") ' ${CFGFILEPATH})
	else
	    jquery=$(jq 'if (has("default-ratings")) then ."default-ratings" else empty end | map("(.infos[] | select(" + .condition + ")) += { \"rating\": \"" + .rating + "\"}") | join(" | ") | . + " | (.infos[] | select(has(\"rating\") | not)) += { \"rating\": \"red\" }"' ${CFGFILEPATH})
	fi

	# re-rate in case of ...
	#   a) new entries, or
	#   b) newer configuration file which might change the (overall)
	#      outcome
	# NOTE:
	#   (re-)rating will normally happen after generation of new entries
	#   initiated by omnect_service_log.sh via systemd StopPost hook
	if [    ! -r "${servicelog}.rated" \
	     -o "$CFGFILEPATH" -nt "${servicelog}" \
	     -o "${servicelog}" -nt "${servicelog}.rated" \
	   ]; then
	    eval jq $jquery "$servicelog" > "${servicelog}.rated"
	    mv "${servicelog}.rated" "$servicelog"
	    # create empty anew to remember when we last rated all entries
	    : > "${servicelog}.rated"
	fi

	if [ $(jq '.infos | map(select(.rating == "red")) | length' "${servicelog}") -gt 0 ]; then
	    rating=2
	elif [ $rating -lt 1 -a $(jq '.infos | map(select(.rating == "yellow")) | length' "${servicelog}") -gt 0 ]; then
	    rating=1
	fi
	print_rating $rating "$service" "$ME"
	do_rate "$rating"
    done
    return $overall_rating
}

function do_get_infos() {
    local nentries service rating servicelog

    nentries=$(jq '.services | length' "$CFGFILEPATH")
    [ "$check_services" ] || check_services=$(jq -r '[ .services[].service ] | join(" ")' "$CFGFILEPATH")
    for ((n=0; n < nentries; n++)); do
	rating=0

	service=$(jq -r ".services[$n].service" "$CFGFILEPATH")
	[ "$(echo $check_services | grep -w "$service")" ] || continue

	servicelog="$LOGDIR/${service}.exit-log"
	if [ ! -r "$servicelog" ]; then
	    print_info_header "${ME}(${service})" "$rating"
	    continue
	fi

	if [ $(jq '.infos | map(select(.rating == "red")) | length' "${servicelog}") -gt 0 ]; then
	    rating=2
	elif [ $rating -lt 1 -a $(jq '.infos | map(select(.rating == "yellow")) | length' "${servicelog}") -gt 0 ]; then
	    rating=1
	fi
	do_rate "$rating"
	print_info_header "${ME}(${service})" "$rating"
	if [ "$rating" != 0 -a -r /var/run/omnect_health_log/${service}.exit-info ]; then
		cat /var/run/omnect_health_log/${service}.exit-info
	fi
    done
    get_overall_rating
}

if [ ! -r "$CFGFILEPATH" ]; then
    warn "no configuration file (${CFGFILEPATH}) found, don't know what to do."
    exit 0
fi

command="${1:-check}"
[ "$1" ] && shift
check_command_arg "$command"

# allow to select tests via command line
check_services="$*"

# first argument must be either "check" or "get-infos"
case "$command" in
    check)
	do_check "$@"
	overall_rating=$?
	;;
    get-infos)
	do_get_infos "$@"
	overall_rating=$?
	;;
esac

# print_rating "" "omnect_service_log_analyze" "$ME"

exit $overall_rating
