#!/bin/bash
# shellcheck disable=SC2015,SC2236,SC2206,SC2004
#
# Checks if SSL Certificate on https server is valid.
# ===================================================
#
# Use this script to automate HTTPS SSL Certificate monitoring. 
# It curl's remote server on 443 port and then checks remote 
# SSL Certificate expiration date. You can use it with Zabbix, 
# Nagios/Icinga or other.
#
# GitHub repository: 
# https://github.com/pavelkim/check_certificates
#
# Community support:
# https://github.com/pavelkim/check_certificates/issues
#
# Copyright 2022, Pavel Kim - All Rights Reserved
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

set -o pipefail

VERSION="1.9.1"
TODAY_TIMESTAMP="$(date "+%s")"

[[ -z "${SOURCE_ONLY_MODE}" ]] && SOURCE_ONLY_MODE=0

# shellcheck source=/dev/null
[[ -f ".config" ]] && source .config || :

usage() {

    cat << EOF
SSL Certificate checker
Version: ${VERSION}

Usage: $0 [-h] [-v] [-s] [-l] [-n] [-A n] [-G] -i input_filename -d domain_name -b backend_name

   -b, --backend-name       Domain list backend name (pastebin, gcs, etc.)
   -i, --input-filename     Path to the list of domains to check
   -d, --domain             Domain name to check
   -s, --sensor-mode        Exit with non-zero if there was something to print out
   -l, --only-alerting      Show only alerting domains (expiring soon and erroneous)
   -n, --only-names         Show only domain names instead of the full table
   -A, --alert-limit        Set threshold of upcoming expiration alert to n days
   -G, --generate-metrics   Generates a Prometheus metrics file to be served by nginx
   -v, --verbose            Enable debug output
   -h, --help               Show help

EOF

}

timestamp() {
    date "+%F %T"
}

error() {

        [[ ! -z "${1}" ]] && msg="ERROR: ${1}" || msg="ERROR!"
        [[ ! -z "${2}" ]] && rc="${2}" || rc=1

        echo "[$(timestamp)] ${BASH_SOURCE[1]}: line ${BASH_LINENO[0]}: ${FUNCNAME[1]}: ${msg}" >&2
        exit "${rc}"
}

info() {

    local msg="$1"
    local self_level=3
    local self_level_name="info"

    if [[ "${self_level}" -le "${GLOBAL_LOGLEVEL}" ]]; then 
        echo "[$(timestamp)] [${self_level_name}] [${FUNCNAME[1]}] $msg" >&2
        return 0
    fi
}

warning() {

    local msg="$1"
    local self_level=2
    local self_level_name="warning"

    if [[ "${self_level}" -le "${GLOBAL_LOGLEVEL}" ]]; then 
        echo "[$(timestamp)] [${self_level_name}] [${FUNCNAME[1]}] $msg" >&2
        return 0
    fi
}

date_to_epoch() {

    #
    # Converts a date string returned by OpenSSL to a Unix timestamp integer
    #

    local date_from

    [[ ! -z "$1" ]] && date_from="$1" || return 2

    case "$OSTYPE" in
        linux*)  date -d "${date_from}" "+%s" ;;
        darwin*) date -j -f "%b %d %T %Y %Z" "${date_from}" "+%s" ;;
    esac
}


epoch_to_date() {

    #
    # Converts a Unix timestamp integer to a date of a format passed as the second parameter
    #

    local date_epoch
    local date_format

    [[ ! -z "$1" ]] && date_epoch="$1" || return 2
    [[ ! -z "$2" ]] && date_format="$2" || date_format="+%F %T"

    case "$OSTYPE" in
        linux*)  date -d "@${date_epoch}" "${date_format}" ;;
        darwin*) date -j -f "%s" "${date_epoch}" "${date_format}" ;;
    esac
}

backend_read_pastebin() {

    [[ -z "${PASTEBIN_USERKEY}" ]] && error "PASTEBIN_USERKEY not set!"
    [[ -z "${PASTEBIN_DEVKEY}" ]] && error "PASTEBIN_DEVKEY not set!"
    [[ -z "${PASTEBIN_PASTEID}" ]] && error "PASTEBIN_PASTEID not set!"

    local pastebin_api_endpoint
    local pastebin_api_payload
    local pastebin_dataset_filter
    local result_filename

    [[ ! -z "$1" ]] && result_filename="$1" || error "Result file not set!"

    pastebin_api_endpoint="https://pastebin.com/api/api_raw.php"
    pastebin_api_payload="api_option=show_paste&api_user_key=${PASTEBIN_USERKEY}&api_dev_key=${PASTEBIN_DEVKEY}&api_paste_key=${PASTEBIN_PASTEID}"
    pastebin_dataset_filter=".check_ssl[]"

    curl -X POST -s "${pastebin_api_endpoint}" --data "${pastebin_api_payload}" | jq -r "${pastebin_dataset_filter}" > "${result_filename}"

}

generate_prometheus_metrics() {

    [[ -z "${PROMETHEUS_EXPORT_FILENAME}" ]] && error "PROMETHEUS_EXPORT_FILENAME not set!"
    [[ -z "${TODAY_TIMESTAMP}" ]] && error "TODAY_TIMESTAMP not set!"

    local metrics_name='check_certificates_expiration'
    local full_result
    local full_result_item
    local full_result_item_parts
    local metrics_item
    local metrics_labels

    [[ ! -z "$*" ]] && full_result=( "$@" ) || error "Formatted result list not set!"

    info "Exporting Prometheus metrics into file '${PROMETHEUS_EXPORT_FILENAME}'"

    info "Writing Prometheus metrics header (overwriting)"
    echo "# HELP check_certificates_expiration Days until HTTPs SSL certificate expires" > "${PROMETHEUS_EXPORT_FILENAME}"
    echo "# TYPE check_certificates_expiration gauge" >> "${PROMETHEUS_EXPORT_FILENAME}"

    for full_result_item in "${full_result[@]}"; do
        full_result_item_parts=( ${full_result_item} )
        # shellcheck disable=SC2004
        metrics_labels="domain=\"${full_result_item_parts[0]}\",outcome=\"${full_result_item_parts[3]}\""
        metrics_item="${metrics_name}{${metrics_labels}} $(( (${full_result_item_parts[2]} - ${TODAY_TIMESTAMP}) / 86400 ))"
        info "Writing metrics item '${metrics_item}'"
        echo "${metrics_item}" >> "${PROMETHEUS_EXPORT_FILENAME}"
    done

    info "Finished Prometheus metrics export"

}

backend_read() {

    local backend_name
    local result_filename
    local backend_read_function

    [[ ! -z "$1" ]] && backend_name="$1" || error "Backend name not set!"
    [[ ! -z "$2" ]] && result_filename="$2" || error "Result file not set!"

    backend_read_function="backend_read_${backend_name}"
    
    eval "${backend_read_function}" "${result_filename}" > "${result_filename}"

}

check_https_certificate_dates() {

    #
    # Probes remote host for HTTPS, retreives expiration dates and returns them in Unix timestamp format
    #

    local remote_hostname
    local retries
    local current_retry
    local result
    local final_result
    local dates=( )

    [[ ! -z "$1" ]] && remote_hostname="$1" || error "Remote hostname not set!"
    [[ ! -z "$2" ]] && retries="$2" || retries=1
    [[ ! -z "$3" ]] && current_retry="$3" || current_retry=1

    if [[ "${retries}" -gt 1 ]] && [[ "${current_retry}" -le "${retries}" ]]; then
        info "Retry #${current_retry} of ${retries} (Not implemented yet)"
        current_retry=$(( current_retry + 1 ))
        return 1
    fi

    info "Starting https ssl certificate validation for ${remote_hostname}"
    result="$( echo | openssl s_client -servername "${remote_hostname}" -connect "${remote_hostname}:443" 2>/dev/null | openssl x509 -noout -dates 2>/dev/null | cut -d"=" -f2  )"
    RC=$?
    
    if [[ "${RC}" != "0" ]]; then

        warning "Can't process openssl output for ${remote_hostname}"
        final_result="${remote_hostname} ${TODAY_TIMESTAMP} ${TODAY_TIMESTAMP} error"

    else

        # shellcheck disable=SC2162
        while read line; do
            dates+=( "${line}" )
        done <<< "${result}"
    
        info "${remote_hostname} Not before ${dates[0]}"
        info "${remote_hostname} Not after ${dates[1]}"
        
        final_result="${remote_hostname} $(date_to_epoch "${dates[0]}") $(date_to_epoch "${dates[1]}") ok"
    fi
    
    echo "${final_result}"
    return "${RC}"
}

_required_cli_parameter() {

    local parameter_name
    local parameter_description

    [[ ! -z "${1}" ]] && parameter_name="${1}" || error "Parameter 'name' not set." 
    [[ ! -z "${2}" ]] && parameter_description="${2}" || parameter_description=""

    if [[ -z "${!parameter_name}" ]]; then
        error "Required parameter: ${parameter_description:-$parameter_name}"
    else
        return 0
    fi

}

main() {

    local CLI_BACKEND_NAME
    local CLI_INPUT_FILENAME
    local CLI_INPUT_DOMAIN
    local CLI_ONLY_ALERTING
    local CLI_ALERT_LIMIT
    local CLI_ONLY_NAMES
    local CLI_SENSOR_MODE
    local CLI_GENERATE_METRICS
    local CLI_RETRIES
    local CLI_VERBOSE

    local full_result=( )
    local formatted_result=( )
    local sorted_result=( )
    local input_filename
    local formatted_result_item

    while [[ "$#" -gt 0 ]]; do 
        case "${1}" in
            -b|--backend-name)
                [[ -z "${CLI_BACKEND_NAME}" ]] && CLI_BACKEND_NAME="${2}" || error "Argument already set: -b"; shift; shift;;

            -i|--input-filename)
                [[ -z "${CLI_INPUT_FILENAME}" ]] && CLI_INPUT_FILENAME="${2}" || error "Argument already set: -i"; shift; shift;;

            -d|--domain)
                [[ -z "${CLI_INPUT_DOMAIN}" ]] && CLI_INPUT_DOMAIN="${2}" || error "Argument already set: -d"; shift; shift;;

            -s|--sensor-mode)
                [[ -z "${CLI_SENSOR_MODE}" ]] && CLI_SENSOR_MODE=1 || error "Parameter already set: -s"; shift;;

            -l|--only-alerting)
                [[ -z "${CLI_ONLY_ALERTING}" ]] && CLI_ONLY_ALERTING=1 || error "Parameter already set: -l"; shift;;

            -n|--only-names)
                [[ -z "${CLI_ONLY_NAMES}" ]] && CLI_ONLY_NAMES=1 || error "Parameter already set: -n"; shift;;

            -A|--alert-limit)
                [[ -z "${CLI_ALERT_LIMIT}" ]] && CLI_ALERT_LIMIT="${2}" || error "Argument already set: -A"; shift; shift;;

            -G|--generate-metrics)
                [[ -z "${CLI_GENERATE_METRICS}" ]] && CLI_GENERATE_METRICS="1" || error "Parameter already set: -G"; shift;;

            -R|--retries)
                [[ -z "${CLI_RETRIES}" ]] && CLI_RETRIES="${2}" || error "Argument already set: -R"; shift; shift;;

            -v|--verbose)
                [[ -z "${CLI_VERBOSE}" ]] && CLI_VERBOSE=1 || error "Parameter already set: -v"; shift;;

            -h|--help) usage; exit 0;;
            
            *) error "Unknown parameter passed: '${1}'"; shift; shift;;
        esac; 
    done

    [[ "${CLI_VERBOSE}" == "1" ]] && GLOBAL_LOGLEVEL=7 || GLOBAL_LOGLEVEL=0
    [[ -z "${CLI_ALERT_LIMIT}" ]] && CLI_ALERT_LIMIT=7

    if [[ -z "${CLI_INPUT_FILENAME}" ]] && [[ -z "${CLI_INPUT_DOMAIN}" ]] && [[ -z "${CLI_BACKEND_NAME}" ]]; then
        error "Error! Specify one of these: input file, domain, domain backend"
    elif [[ ! -z "${CLI_INPUT_FILENAME}" ]] && [[ ! -z "${CLI_INPUT_DOMAIN}" ]]; then
        error "Error! Only one parameter is allowed: input file or domain"
    fi

    if [[ "${CLI_GENERATE_METRICS}" == "1" ]] && [[ -z "${PROMETHEUS_EXPORT_FILENAME}" ]]; then
        error "Error! PROMETHEUS_EXPORT_FILENAME is not set"
    elif [[ "${CLI_GENERATE_METRICS}" == "1" ]] && [[ ! -z "${PROMETHEUS_EXPORT_FILENAME}" ]]; then
        if ! touch "${PROMETHEUS_EXPORT_FILENAME}"; then
            error "Can't create Prometheus metrics file '${PROMETHEUS_EXPORT_FILENAME}'"
        else
            info "Prometheus metrics file touched: '${PROMETHEUS_EXPORT_FILENAME}'"
        fi
    else
        info "Prometheus metrics generation not requested"
    fi

    if [[ ! -z "${CLI_INPUT_FILENAME}" ]]; then
        [[ -f "${CLI_INPUT_FILENAME}" ]] || error "Can't open input file: '${CLI_INPUT_FILENAME}'"
        input_filename="${CLI_INPUT_FILENAME}"

    elif [[ ! -z "${CLI_INPUT_DOMAIN}" ]]; then
        input_filename="$(mktemp)"
        echo "${CLI_INPUT_DOMAIN}" > "${input_filename}"

    elif [[ ! -z "${CLI_BACKEND_NAME}" ]]; then
        input_filename="$(mktemp)"
        backend_read "${CLI_BACKEND_NAME}" "${input_filename}"
    fi

    

    while IFS= read -r remote_hostname; do 

        [[ -z "${remote_hostname}" ]] && continue

        info "Processing '${remote_hostname}'"
        current_result=$( check_https_certificate_dates "${remote_hostname}" )
        rc="$?"
        
        if [[ "${rc}" != "0" ]]; then
            warning "Labeling '${remote_hostname}' as failed to get validated"
            full_result+=( "${current_result}" )
        else
            info "Adding item into full_result: '${current_result}'" 
            full_result+=( "${current_result}" )
        fi

        info "Finished processing '${remote_hostname}'"

    done < "${input_filename}"

    if [[ "${#full_result[@]}" -eq "0" ]]; then
        warning "Couldn't process anything from '${input_filename}'"
    else
        info "Processed '${#full_result[@]}' items from '${input_filename}'"
    fi

    if [[ "${CLI_GENERATE_METRICS}" == "1" ]]; then
        info "Generating Prometheus metrics"
        generate_prometheus_metrics "${full_result[@]}"
    fi

    for result_item in "${full_result[@]}"; do
        
        result_item_parts=( ${result_item} )
        info "Result item split into ${#result_item_parts[@]} parts: ${result_item_parts[*]}"

        if [[ "${CLI_ONLY_ALERTING}" == "1" ]]; then
            if [[ "$(( (result_item_parts[2] - TODAY_TIMESTAMP) / 86400 ))" -gt "${CLI_ALERT_LIMIT}" ]]; then
                info "Certificate on ${result_item_parts[0]} expiring later than alert limit (${CLI_ALERT_LIMIT} day(s))."
                continue
            fi
        fi

        if [[ "${result_item_parts[3]}" == "ok" ]]; then
            formatted_result_item="${result_item_parts[0]} $(epoch_to_date "${result_item_parts[1]}" "+%F %T") $(epoch_to_date "${result_item_parts[2]}" "+%F %T") $(( (result_item_parts[2] - TODAY_TIMESTAMP) / 86400 )) ok"

        elif [[ "${result_item_parts[3]}" == "error" ]]; then
            formatted_result_item="${result_item_parts[0]} error error error error error error"
        else
            warning "Couldn't identify status for ${result_item_parts[0]}: '${result_item_parts[3]}'"
        fi

        info "Rendering a formatted result item: '${formatted_result_item}'"
        formatted_result+=( "${formatted_result_item}" )
    done

    # shellcheck disable=SC2162
    while read formatted_item; do
        sorted_result+=( "${formatted_item}" )
    done <<< "$( IFS=$'\n' ; echo "${formatted_result[*]}" | sort -n -k6)"

    if [[ "${CLI_ONLY_NAMES}" == "1" ]]; then
        (IFS=$'\n'; echo "${sorted_result[*]}" | awk '{ print $1 }')
    else
        (IFS=$'\n'; echo "${sorted_result[*]}" | column -t -s$'\t')
    fi

    if [[ "${CLI_SENSOR_MODE}" == "1" ]] && [[ "${#formatted_result[@]}" -gt 0 ]]; then
        exit 1
    fi

}

if [[ "${SOURCE_ONLY_MODE}" == "0" ]]; then
    main "${@}"
fi
