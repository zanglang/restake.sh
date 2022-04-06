# Restake.sh

## Introduction

This is an alternative backend for Eco-stake's automatic claiming-and-restake app [REStake](https://github.com/eco-stake/restake/).

Instead of NodeJS, `restake.sh` relies heavily on Bash shell scripting, [GNU Parallel](https://www.gnu.org/software/parallel/) and existing wallet command-line tools installed on the host.

GNU Parallel allows certain tasks, e.g. querying individual delegators' authorization grants and outstanding rewards, to become massively parallelized, and allows easy job monitoring and retrying, progress bars, and ETAs.

## Prerequisites

You will need:

   - Properly configured wallet CLI for your chain installed in PATH, e.g. `gaiad`
   - `jq` (https://stedolan.github.io/jq/download/)
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

## Cronjob

Example cronjob:

    */5 * * * *    2>&1 /somewhere/main.sh | tee /somewhere/main.log

