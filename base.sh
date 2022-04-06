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
    if ! command -v jq >/dev/null; then
        echo "jq is not found in PATH!"
        exit 1
    elif ! command -v parallel >/dev/null; then
        echo "GNU parallel is not found in PATH!"
        exit 1
    elif [ -z ${VALIDATOR+x} ] || [ -z ${BOT+x} ]; then
        echo "Environment variables are not configured yet?"
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
    if [ -n "$next" ] && [ "${offset}" -le "500" ]; then
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

    load_grants $1

    tmp="$TMP/$1"
    if ! jq -r ".grants[]" "${TMP}"/$1.* > "${tmp}" 2>/dev/null; then
        return
    fi

    withdraw=$(jq -r "select(.authorization.msg==\"/cosmos.distribution.v1beta1.MsgWithdrawDelegatorReward\" and .expiration > now)" "${tmp}")
    delegate=$(jq -r "select(.authorization.\"@type\"==\"/cosmos.staking.v1beta1.StakeAuthorization\" and (.authorization.allow_list.address[] | contains(\"$VALIDATOR\")) and .expiration > now)" "${tmp}")
    if [ -z "${withdraw}" ] || [ -z "${delegate}" ]; then
        return
    fi

    touch "${TMP}/$1.granted"
}

get_granters() {
    parallel -a "${DELEGATORS}" \
        --jobs "${PARALLEL:-50}" \
        --joblog joblog \
        --retries 1 \
        --progress --bar --eta \
        load_granters

    find "${TMP}" -type f -name "*.granted" -exec basename {} \; | cut -d. -f1 >> "${TMP}/granters.txt"
    mv "${TMP}/granters.txt" "${GRANTERS}"
}

load_delegations() {
    # calculate delegatable pending rewards. Called by parallel

    tmp="$TMP/$1"
    if ! ${BIN} q staking delegation "$1" "${VALIDATOR}" -o json > "$tmp"; then
        echo "Failed to fetch delegation for $1"
        return
    fi
    stake=$(jq -r ".delegation.shares | tonumber" "$tmp")
    if [ "$stake" -le "0" ] || [ "$stake" == "" ]; then
        return
    fi

    if ! ${BIN} q distribution rewards "$1" "${VALIDATOR}" -o json > "$tmp"; then
        echo "Failed to fetch rewards for $1"
        return
    fi
    rewards=$(jq -r ".rewards[0].amount | tonumber | floor" "$tmp")
    if [ "$rewards" -le "${THRESHOLD}" ]; then
        echo "$1 rewards ${rewards} too low, skipping."
        return
    fi

    # generate claim-and-restake tx

    ${BIN} tx distribution withdraw-rewards "${VALIDATOR}" --from "$1" --gas "${GAS:-200000}" --generate-only > "${TMP}/$1.withdraw"
    ${BIN} tx staking delegate "${VALIDATOR}" "${rewards}${DENOM}" --from "$1" --gas "${GAS:-200000}" --generate-only > "${TMP}/$1.delegate"

    if ! jq -s '(map(.body.messages) | flatten) as $msgs | .[0].body.messages |= $msgs | .[0]' "${TMP}/$1.withdraw" "${TMP}/$1.delegate" |\
        ${BIN} tx authz exec - --from "$BOT" --generate-only > "${TMP}/$1.exec"; then
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

    if ! jq -s "(map(.body.messages) | flatten) as \$msgs | .[0].body.messages |= \$msgs | .[0].body.memo = \"${MEMO}\" | (.[0].body.messages | length) as \$len | .[0].auth_info.fee.gas_limit = (\$len * 200000 | tostring) | .[0].auth_info.fee.amount = [{\"denom\":\"${DENOM}\", \"amount\":(\$len * ${GAS_LIMIT:-200000} * ${GAS_PRICE} | floor | tostring)}] | .[0]" "${@}" > "${TMP}/batch.${PARALLEL_SEQ}.json"; then
        echo "Failed to generate transaction!"
        exit 1
    fi
}

generate_transactions() {
    # find generated tx jsons in batch of 50s and merge into 1 large tx

    find "${TMP}" -type f -name "*.exec" |\
        parallel \
            -N "${PARALLEL:-50}" \
            generate_transactions_batch
}

sign_and_send() {
    # send all batched transactions

    batch=0
    for tx in "${TMP}"/batch.*.json; do
        count=$(grep -c MsgExec "${tx}")
        echo "Batch $(( ++batch )) = $count txs"

        # sign and submit transaction
        ${BIN} tx sign "${tx}" --from "${BOT}" --chain-id "${CHAIN}" |\
            ${BIN} tx broadcast - --broadcast-mode sync
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

