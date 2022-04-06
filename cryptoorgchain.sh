#!/bin/bash

SCRIPT_PATH=$(dirname "$0")

source ${SCRIPT_PATH}/env.sh
source ${SCRIPT_PATH}/base.sh

get_delegators() {
    # use Yummy's APIs for loading Cryto.org chain delegators

    limit=500

    if [ -z "$1" ]; then
        echo "Fetching initial data from api.yummy.capital ... "
    else
        param="&key=$1"
        echo "Fetching with key $1 ... "
    fi

    out="${TMP}/delegators.json"
    if ! curl -s "https://api.yummy.capital/v2/validators/${VALIDATOR}/delegators?limit=${limit}${param}" > "${out}"; then
        echo "Error fetching delegators!"
        exit 1
    fi

    F="${TMP}/delegators.txt"
    if ! jq -r ".delegators[].account" "${out}" >> "${F}"; then
        echo "Error parsing ${TMP}/delegators.txt! Dumping:"
        cat "${out}"
        exit 1
    fi

    next=$(jq -r ".pagination.nextKey // empty" "${out}")
    if [ -n "$next" ]; then
        get_delegators "${next}"
    else
        echo "Load complete. Moving ${F} ..."
        mv -f "${F}" "${DELEGATORS}"
    fi
}

# process_delegations() {
#    # TODO: more frequent restaking for high delegations
#}

main

