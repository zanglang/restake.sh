# Restake.sh

## Introduction

This is an alternative backend for Eco-stake's automatic claiming-and-restake app [REStake](https://github.com/eco-stake/restake/).

Instead of NodeJS, `restake.sh` relies heavily on Bash shell scripting, [GNU Parallel](https://www.gnu.org/software/parallel/) and existing wallet command-line tools installed on the host.

GNU Parallel allows certain tasks, e.g. querying individual delegators' authorization grants and outstanding rewards, to become massively parallelized, and allows easy job monitoring and retrying, progress bars, and ETAs.

## Prerequisites

You will need:

   - Properly configured wallet CLI for your chain installed in PATH, e.g. `gaiad`
   - `jq` (https://stedolan.github.io/jq/download/) or `gojq` (https://github.com/itchyny/gojq)
   - `parallel` (https://www.gnu.org/software/parallel/)

The wallet CLI should be configured with `<CLI> config` with the following configuration:

   - `keyring-backend` as `test`, with private keys of the restake account already imported
   - `chain-id`
   - `node` for custom RPC, if using

**WARNING:** You should not be using the `test` keyring-backend on any production machines!

## How to use

    git clone ...
    cd restake.sh

    # edit configuration
    cp env.sh.sample env.sh
    vim env.sh

    # run script
    ./main.sh

## Implementing New Chains & Features

Core functionality can be overriden or extended by re-implementing functions in `base.sh`. For example, `cryptoorgchain.sh` demonstrates switching to [Yummy.capital](https://yummy.capital/)'s fantastic APIs for the Crypto.org Chain for fetching delegators, as well as custom logic to trigger compounding more frequently for larger delegators for higher APY %.

To support running multiple chains within the same folder, simply copy `main.sh` to a new file and define the new environment variables. For example, a hypothetical `juno.sh` could load a new `juno_env.sh`.

### Bonus: Cosmostation.sh

`cosmostation.sh` implements an alternative strategy that foregoes querying for delegators and grants, but instead relies on the fact that block explorers like Mintscan indexes authorisation grant transactions on the grantee's page instead of the granter's.

Using an undocumented Cosmostation API, we may retrieve all seen grant transactions on the bot's account page, and _then_ check if the grants are still valid. This reduced my script runtime **down to 20 seconds**!

Additionally, the `fetch` function can be easily re-implemented to download and filter all transactions from any wallet address indexed on Mintscan, e.g. to filter IBC transactions:

    jq -r ".[].data.tx.body.messages[] | select(.\"@type\"==\"/ibc.applications.transfer.v1.MsgTransfer\" or .\"@type\"==\"/ibc.core.channel.v1.MsgRecvPacket\")"

And merged with `jq` for further data-mining.

## Cronjob

Example cronjob:

    */5 * * * *    2>&1 /somewhere/main.sh | tee /somewhere/main.log

