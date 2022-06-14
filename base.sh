#!/bin/bash

# shellcheck disable=SC2155
export SCRIPT_PATH=$(dirname "$0")
export DELEGATORS="${SCRIPT_PATH}/data/delegators.txt"
export GRANTERS="${SCRIPT_PATH}/data/granters.txt"

####

# shellcheck disable=SC2064
if [ -z ${TMP+x} ]; then
    export TMP=$(mktemp -d)
    trap "{ rm -rf $TMP; }" EXIT
fi

sanity_checks() {
    if [ ! -d "${TMP}" ]; then
        mkdir "${TMP}"
    else
        2>/dev/null rm -f "${TMP}"/*
    fi

    echo "{}" > "${TMP}/test"

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
    elif ! jq . "${TMP}/test"; then
        # https://stackoverflow.com/questions/58128001/could-not-open-file-lol-json-permission-denied-using-jq
        echo "jq wasn't able to load a test JSON. Make sure you're not using the Snap version of jq."
        exit 1
    fi
}

get_delegators() {
    limit=100

    param=
    offset=${1:-0}
    if [ "${offset}" != "0" ]; then
        param="--offset ${offset}"
    fi
    if [ -n "$RPC" ]; then
        param="${param} --node ${RPC}"
    fi

    tmp="$TMP/${VALIDATOR}.${offset}"
    F="${TMP}/delegators.txt"
    echo "Fetching with offset ${offset} ..."

    # shellcheck disable=SC2086
    if ! ${BIN} q staking delegations-to "$VALIDATOR" --limit "${limit}" --output json ${param} > "${tmp}"; then
        echo "Error querying delegators!"
        exit 1
    fi

    if ! jq -r ".delegation_responses[].delegation.delegator_address" "${tmp}" >> "${F}"; then
        echo "Error parsing ${tmp}! Dumping:"
        cat "${tmp}"
        exit 1
    fi

    next=$(jq -r ".pagination.next_key // empty" "${tmp}")
    if [ -n "$next" ] ; then
        # recurse
        offset=$((offset+limit))
        get_delegators "${offset}"
    else
        echo "Load complete. Moving ${F} ..."
        mv -f "${F}" "${DELEGATORS}"
    fi
}

load_grants() {
    # called by load_granters

    limit=1000

    param=
    offset=${2:-0}
    if [ "${offset}" != "0" ]; then
        param="--offset ${offset}"
    fi
    if [ -n "$RPC" ]; then
        param="${param} --node ${RPC}"
    fi

    tmp="$TMP/$1.${offset}"

    # shellcheck disable=SC2086
    if ! ${BIN} q authz grants "$1" "$BOT" --limit "${limit}" --output json ${param} > "${tmp}"; then
        echo "Error querying authz!"
        exit 1
    fi

    next=$(jq -r ".pagination.next_key // empty" "${tmp}")
    if [ -n "$next" ]; then
        # recurse
        offset=$((offset+limit))
        load_grants "$1" "${offset}"
    fi
}

# shellcheck disable=SC2086
load_granters() {
    # called by parallel

    load_grants "$1"

    # clear previously cached data, if any
    tmp="${TMP}/$1"
    rm -f "${tmp}.granted" 2>/dev/null

    if ! jq -r ".grants[]" "${TMP}"/$1.* > "${tmp}" ; then
        echo "Error parsing grants for $1!"
        return
    fi

    # check for valid grants
    if ! jq -r "select(((.authorization.\"@type\"==\"/cosmos.staking.v1beta1.StakeAuthorization\" and (.authorization.allow_list.address[] | contains(\"$VALIDATOR\"))) or (.authorization.\"@type\"==\"/cosmos.authz.v1beta1.GenericAuthorization\" and .authorization.msg==\"/cosmos.staking.v1beta1.MsgDelegate\")) and (.expiration | fromdateiso8601) > now)" "${tmp}" > "${tmp}.granted"
    then
        echo "No valid grants found for $1."
        return
    fi

    # check for remaining allowances, if any
    allowance=$(jq -s -r "map(.authorization.max_tokens | select(. != null).amount | tonumber) | add" "${tmp}.granted" 2>/dev/null)
    if [ "$allowance" = "null" ]; then
        # no max_tokens set
        return
    elif [ "$allowance" = "0" ]; then
        echo "No authorizations with allowances remaining for $1."
    fi

    echo "$allowance" > "${tmp}.allowance"
}

get_granters() {
    parallel -a "${DELEGATORS}" \
        --jobs "${PARALLEL:-50}" \
        --joblog joblog \
        --retries 1 \
        --progress --bar --eta \
        load_granters

    find "${TMP}" -type f -name "*.granted" ! -empty -exec basename {} \; | cut -d. -f1 >> "${TMP}/granters.txt"
    mv "${TMP}/granters.txt" "${GRANTERS}"
}

load_delegations() {
    # calculate delegatable pending rewards. Called by parallel

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
    rewards=$(jq -r ".rewards[0].amount | tonumber | floor" "${tmp}.rewards")

    # check authz allowances remaining
    if [ -f "${tmp}.allowance" ]; then
        allowance=$(cat "${tmp}.allowance")
        if [ "$allowance" -ge 0 ]; then
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

    batch=0
    for tx in "${TMP}"/batch.*.json; do
        count=$(grep -c MsgExec "${tx}")
        echo "Batch $(( ++batch )) = $count txs"

        # sign and submit transaction
        2>&1 ${BIN} tx sign "${tx}" --from "${BOT}" --chain-id "${CHAIN}" |\
            ${BIN} tx broadcast - --broadcast-mode "${BROADCAST_MODE:-block}"

        echo "Sleeping 5 seconds ..."
        sleep 5
    done
}

export -f load_grants
export -f load_granters
export -f load_delegations
export -f generate_transactions_batch

main() {
    echo "Starting ..."

    sanity_checks

    get_delegators

    num_delegators=$(wc -l < "${DELEGATORS}")
    if [ "$num_delegators" -le 0 ]; then
        echo "No delegators found. Exiting."
        exit 0
    fi
    echo "Done. ${num_delegators} delegators found. Fetching grants ..."

    get_granters

    num_granters=$(wc -l < "${GRANTERS}")
    if [ "$num_granters" -le 0 ]; then
        echo "No granters found. Exiting."
        exit 0
    fi
    echo "Done. ${num_delegators} delegators processed, found ${num_granters} granters."

    echo "Processing delegations ..."
    process_delegations

    echo "Generating authz transactions ..."
    generate_transactions

    echo "Submitting final transactions ..."
    sign_and_send

    echo "All done."
}

