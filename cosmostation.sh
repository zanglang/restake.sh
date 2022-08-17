#!/bin/bash
#
# This is a sample script that foregoes fetching delegators and instead uses an undocumented
# Cosmostation API to retrieve all seen grants on the bot's account page, significantly
# reducing run time by 10x.
#
# !!! This could break without warning!

# shellcheck disable=SC1090,SC2086
SCRIPT_PATH=$(dirname "$0")
source ${SCRIPT_PATH}/env.sh
source ${SCRIPT_PATH}/base.sh

get_delegators() {
    # dummy data
    echo "Nothing to see here" > "${DELEGATORS}"
}

fetch() {
    # load all grant transactions from Cosmostation

    from=${1:-0}
    echo "Fetching transactions from Cosmostation with from=${from} ..."

    if ! curl -s "https://api-cryptocom.cosmostation.io/v1/account/new_txs/${BOT}?limit=50&from=${from}" \
            -H 'Referer: https://www.mintscan.io/' > "${TMP}/txs"; then
        echo "Error fetching data from Cosmostation!"
        exit 1
    fi

    tmp="${TMP}/grants.${from}"
    if ! jq -r ".[].data.tx.body.messages[] | select(.\"@type\"==\"/cosmos.authz.v1beta1.MsgGrant\" and .grantee==\"${BOT}\")" "${TMP}/txs" > "${tmp}"; then
        echo "Could not parse JSON! Dumping:"
        cat "${TMP}/txs"
        exit 1
    fi

    if [ -s "$tmp" ]; then
        # get last event id from results and fetch next page
        id=$(jq -r '.[-1].header.id' "${TMP}/txs")
        if [ "$id" -ge "0" ]; then
            fetch "$id"
        fi
    fi
}

get_granters() {
    fetch

    # done fetching, now verify granters one by one. We can't use Cosmostation's
    # data here as seen grants may be stale, expired, or revoked.
    jq -r '.granter' "${TMP}"/grants.* | sort -u |\
        parallel \
            --jobs "${PARALLEL:-50}" \
            --joblog joblog \
            --retries 1 \
            --progress --bar --eta \
            load_granters

    find "${TMP}" -type f -name "*.granted" ! -empty -exec basename {} \; | cut -d. -f1 > "${GRANTERS}"
}

main

