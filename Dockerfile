FROM golang:alpine AS build-env
ARG NETWORK=mainnet
ARG VERSION=v3.3.4

ENV PACKAGES curl make git libc-dev bash gcc linux-headers eudev-dev python3

# Set working directory for the build
WORKDIR /go/src/github.com/crypto-org-chain

# Install minimum necessary dependencies, download source at desired version, build Cosmos SDK, remove packages
RUN apk add --no-cache $PACKAGES && \
  git clone https://github.com/crypto-org-chain/chain-main.git && \
  cd chain-main && git checkout tags/$VERSION && \
  git submodule update --init --recursive && \
  NETWORK=${NETWORK} make install


# Final image
FROM alpine:edge
ARG NETWORK=mainnet
ARG UUID=1000
ARG GUID=1000
ARG NODE=http://localhost:26657

# Install ca-certificates
RUN apk add --no-cache jq curl parallel bash --update ca-certificates
RUN addgroup chain-main -g ${GUID} && \
  adduser -S -u ${UUID} -G chain-main chain-main -h "/chain-main"

USER chain-main

# Copy over binaries from the build-env
COPY --from=build-env /go/bin/chain-maind /usr/bin/chain-maind
COPY --chown=chain-main ./*.sh /restake/

RUN mkdir /restake/data

RUN chain-maind config keyring-backend test && \
    chain-maind config chain-id crypto-org-chain-mainnet-1 && \
    chain-maind config node ${NODE}

# Run restake by default
CMD ["/restake/cryptoorgchain.sh"]
