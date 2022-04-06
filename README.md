# Restake.sh

## Introduction

This is an alternative backend for Eco-stake's automatic claiming-and-restake app [REStake](https://github.com/eco-stake/restake/).

Instead of NodeJS, `restake.sh` relies heavily on Bash shell scripting, [GNU Parallel](https://www.gnu.org/software/parallel/) and existing wallet command-line tools installed on the host.

Parallel allows certain tasks, e.g. querying individual delegators' authorization grants and outstanding rewards, to be massively parallelized, reducing a run that used to take me 30 minutes to just 5!

## Prerequisites

You will need:

   - Properly configured wallet CLI for your chain installed in PATH, e.g. `gaiad` with `keyring-backend=test`
   - `jq` (https://stedolan.github.io/jq/download/)
   - `parallel` (https://www.gnu.org/software/parallel/)

## How to use

    git clone ...
    cd restake.sh

    # edit configuration
    cp env.sh.sample env.sh
    vim env.sh

    # run script
    ./main.sh

## Implementing New Chains

Core functionality can be overriden or extended by re-implementing functions in `base.sh`. For example, `cryptoorgchain.sh` demonstrates switching to [Yummy.capital](https://yummy.capital/)'s fantastic APIs for the Crypto.org Chain for fetching delegators, as well as custom logic to trigger compounding more frequently for larger delegators for higher APY %.

## Cronjob

Example cronjob:

    */5 * * * *    2>&1 /somewhere/main.sh | tee /somewhere/main.log

