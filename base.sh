#!/bin/bash

####

# shellcheck disable=SC2064,SC2155
if [ -z ${TMP+x} ]; then
    export TMP=$(mktemp -d)
    trap "{ rm -rf $TMP; }" EXIT
fi

# shellcheck disable=SC2155
export SCRIPT_PATH=$(dirname "$0")
export GRANTERS="${TMP}/granters.txt"
export GRANTS="${TMP}/grants.txt"

# check debug mode
if [[ "$-" == *x* ]]; then
    export DEBUG=1
fi

sanity_checks() {
    if [ ! -d "${TMP}" ]; then
        mkdir "${TMP}"
    elif [ "${DEBUG:-0}" != "1" ]; then
        2>/dev/null rm -f "${TMP}"/*
    fi

    echo "{}" > "${TMP}/test"

    # shellcheck disable=SC2046
    if ! command -v jq >/dev/null; then
        echo "jq is not found in PATH!"
        exit 1
    elif ! command -v parallel >/dev/null; then
        echo "GNU parallel is not found in PATH!"
        exit 1
    elif [ -z ${VALIDATOR+x} ] || [ -z ${BOT+x} ]; then
        echo "Environment variables are not configured yet?"
        exit 1
    elif ! ${BIN} keys show -a "${KEY}" > "${TMP}/address"; then
        echo "Keyring is not correctly configured?"
        exit 1
    elif [ "$(cat "${TMP}"/address)" != "${BOT}" ]; then
        echo "Keyring address does not match bot wallet (${BOT})?"
        exit 1
    elif ! jq . "${TMP}/test" >/dev/null; then
        # https://stackoverflow.com/questions/58128001/could-not-open-file-lol-json-permission-denied-using-jq
        echo "jq wasn't able to load a test JSON. Make sure you're not using the Snap version of jq."
        exit 1
    elif [ $(jq -rn '1000000000000000000 | floor | tostring') != "1000000000000000000" ]; then
        echo "Current version of jq does not support big integers! Upgrade or switch to gojq."
        exit 1
    elif ! ${BIN} q authz --help | grep -q "grants-by-grantee"; then
        echo "This script now requires grants-by-grantee support!"
        exit 1
    fi
}

get_grants() {
    limit=100

    param=
    offset=${1:-0}
    if [ "${offset}" != "0" ]; then
        param="--offset ${offset}"
    fi
    if [ -n "$RPC" ]; then
        param="${param} --node ${RPC}"
    fi

    tmp="$TMP/${BOT}.${offset}"
    F="${TMP}/grants.txt"
    echo "Fetching granters with offset ${offset} ..."

    # shellcheck disable=SC2086
    if ! ${BIN} q authz grants-by-grantee "$BOT" --limit "${limit}" --output json ${param} > "${tmp}"; then
        echo "Error querying granters!"
        exit 1
    fi

    if ! jq -r ".grants[] | select(((.authorization.\"@type\"==\"/cosmos.staking.v1beta1.StakeAuthorization\" and (.authorization.allow_list.address[] | contains(\"$VALIDATOR\"))) or (.authorization.\"@type\"==\"/cosmos.authz.v1beta1.GenericAuthorization\" and .authorization.msg==\"/cosmos.staking.v1beta1.MsgDelegate\")) and (.expiration | fromdateiso8601) > now)" "${tmp}" >> "${F}"
    then
        echo "Error parsing ${tmp}! Dumping:"
        cat "${tmp}"
        exit 1
    fi

    next=$(jq -r ".pagination.next_key // empty" "${tmp}")
    if [ -n "$next" ] ; then
        # recurse
        offset=$((offset+limit))
        get_grants "${offset}"
    else
        # done fetching all grants, 
        jq -r ".granter" "$F" | sort > "$GRANTERS"
    fi
}

load_delegations() {
    # calculate delegatable pending rewards. Called by parallel

    if [ "${DEBUG:-0}" = "1" ]; then
        set -x
    fi

    tmp="$TMP/$1"
    if ! ${BIN} q staking delegation "$1" "${VALIDATOR}" -o json > "${tmp}.stake"; then
        echo "Failed to fetch delegation for $1"
        return
    fi
    stake=$(jq -r '.delegation.shares as $s | ($s != null and $s != "" and ($s | tonumber > 0))' "${tmp}.stake")
    if [ "$stake" != "true" ]; then
        return
    fi

    if ! ${BIN} q distribution rewards "$1" "${VALIDATOR}" -o json > "${tmp}.rewards"; then
        echo "Failed to fetch rewards for $1"
        return
    fi
    rewards=$(jq -r ".rewards[] | select(.denom==\"${DENOM}\") | .amount | tonumber | floor" "${tmp}.rewards")

    # check authz allowances remaining
    allowance=$(jq -r -s "map(select(.granter == \"$1\") | .authorization.max_tokens | select(. != null).amount | tonumber) | add" "${GRANTS}" 2>/dev/null)
    if [ "$allowance" = "0" ]; then
        echo "No authorizations with allowances remaining for $1."
        return
    elif [ "$allowance" != "null" ]; then
        if [ "$(jq -n "${allowance} > 0")" = "true" ]; then
            rewards=$(jq -r -n "[$allowance, $rewards] | min")
        fi
    fi

    if [ "$(jq -n "${rewards} >= ${THRESHOLD}")" = "false" ]; then
        echo "$1 rewards ${rewards} too low, skipping."
        return
    fi

    # generate claim-and-restake tx

    ${BIN} tx staking delegate "${VALIDATOR}" "${rewards}${DENOM}" --from "$1" --gas "${GAS_LIMIT:-200000}" --generate-only > "${tmp}.delegate"

    if ! jq -s '(map(.body.messages) | flatten) as $msgs | .[0].body.messages |= $msgs | .[0]' "${tmp}.delegate" |\
        ${BIN} tx authz exec - --from "$BOT" --generate-only > "${tmp}.exec"; then
        echo "Failed to generate exec transaction!"
        return
    fi
}

process_delegations() {
    # check individual delegations and generate claim-and-restake txs

    parallel -a "${GRANTERS}" \
        --jobs "${PARALLEL:-50}" \
        --joblog joblog \
        --retries 1 \
        --progress --bar --eta \
        load_delegations
}

generate_transactions_batch() {
    # concatenate transactions in batches and calculate fees. Called by parallel

    if [ "${DEBUG:-0}" = "1" ]; then
        set -x
    fi

    if ! jq -s "(map(.body.messages) | flatten) as \$msgs | .[0].body.messages |= \$msgs | .[0].body.memo = \"${MEMO}\" | (.[0].body.messages | length) as \$len | .[0].auth_info.fee.gas_limit = (\$len * ${GAS_LIMIT:-200000} | tostring) | .[0].auth_info.fee.amount = [{\"denom\":\"${DENOM}\", \"amount\":(\$len * ${GAS_LIMIT:-200000} * ${GAS_PRICE} | floor | tostring)}] | .[0]" "${@}" > "${TMP}/batch.${PARALLEL_SEQ}.json"; then
        echo "Failed to generate transaction!"
        exit 1
    fi
}

generate_transactions() {
    # find generated tx jsons in batches and merge into 1 large tx

    find "${TMP}" -type f -name "*.exec" |\
        parallel \
            -N "${BATCH:-50}" \
            generate_transactions_batch

    count=$(find "${TMP}" -type f -name "batch.*.json" | wc -l)
    echo "${count} batches generated."

    if [ "$count" -eq 0 ]; then
        echo "Nothing to do, exiting now."
        exit 0
    fi
}

sign_and_send() {
    # send all batched transactions

    if [ "${DRY_RUN:-0}" = "1" ]; then
        echo "Dry-run enabled, not broadcasting transactions."
        return
    fi
    param=
    if [ -n "$RPC" ]; then
        param="${param} --node ${RPC}"
    fi

    batch=0
    for tx in "${TMP}"/batch.*.json; do
        count=$(grep -c MsgDelegate "${tx}")
        echo "Batch $(( ++batch )) = $count txs"

        # sign and submit transaction
        # shellcheck disable=SC2086
        2>&1 ${BIN} tx sign "${tx}" --from "${BOT}" --chain-id "${CHAIN}" --output-document "${tx}.signed" ${param}
        # shellcheck disable=SC2086
        2>&1 ${BIN} tx broadcast "${tx}.signed" --broadcast-mode "${BROADCAST_MODE:-block}" ${param}

        echo "Sleeping 5 seconds ..."
        sleep 5
    done
}

export -f load_delegations
export -f generate_transactions_batch

main() {
    echo "Starting ..."

    sanity_checks

    echo "Fetching grants ..."
    get_grants

    num_granters=$(wc -l < "${GRANTERS}")
    if [ "$num_granters" -le 0 ]; then
        echo "No granters found. Exiting."
        exit 0
    fi
    echo "Done, found ${num_granters} granters."

    echo "Processing delegations for restaking transactions ..."
    process_delegations

    echo "Generating batched transactions ..."
    generate_transactions

    echo "Submitting final transactions ..."
    sign_and_send

    echo "All done."
}

