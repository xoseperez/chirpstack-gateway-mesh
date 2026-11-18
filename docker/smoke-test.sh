#!/usr/bin/env bash

# Checks a built image before it is pushed: the binary runs on the platform, the
# start script renders a complete configuration from environment variables, the
# service accepts that configuration together with every region file shipped,
# it starts on it, and the start script waits for concentratord.
#
#   docker/smoke-test.sh IMAGE PLATFORM

set -euo pipefail

IMAGE=$1
PLATFORM=$2

# --init keeps the tested command from becoming PID 1, which signals sent from
# inside the container (such as the timeouts below) cannot kill.
run() { docker run --rm --init --platform "${PLATFORM}" --network none "$@"; }

fail() { echo "FAIL: $*" >&2; exit 1; }

# A border gateway relaying over ISM2400 for US915 end-devices. RELAY_REGION is
# the old name of RELAY_REGION_RELAY.
ENV=(
    -e RELAY_BORDER=true
    -e RELAY_ROOT_KEY=0102030405060708090a0b0c0d0e0f10
    -e RELAY_HEARTBEAT_INTERVAL=1m
    -e RELAY_REGION_DEVICES=us915
    -e RELAY_REGION=ism2400
)

echo "== ${PLATFORM}: binary"
run "${IMAGE}" ./chirpstack-gateway-mesh -V

echo "== ${PLATFORM}: configuration"
CONFIG=$(run "${ENV[@]}" "${IMAGE}" bash start --render)
echo "${CONFIG}"
if grep -nE '\$\{|\{\{' <<< "${CONFIG}"; then
    fail "placeholders left in the configuration"
fi
for expected in \
    'root_key="0102030405060708090a0b0c0d0e0f10"' \
    'border_gateway=true' \
    'frequencies=[2403000000,2479000000,2425000000]' \
    'tx_power=10' \
    'heartbeat_interval="1m"' \
    'event_bind="ipc:///tmp/forwarder_event"' \
    '902300000,'; do
    grep -qF -- "${expected}" <<< "${CONFIG}" || fail "'${expected}' missing from the configuration"
done

echo "== ${PLATFORM}: service accepts the configuration"
# "configfile" loads the configuration and prints it back without starting
# anything. A setting under the wrong table would be ignored and come back as
# its default, so check the ones that moved between upstream versions.
PARSED=$(run "${ENV[@]}" "${IMAGE}" \
    bash -c 'bash start --render > /dev/null && ./chirpstack-gateway-mesh -c run/config.toml -c regions/region_us915.toml configfile') \
    || fail "the service rejected the configuration"
for expected in \
    'heartbeat_interval="1m"' \
    'root_key="0102030405060708090a0b0c0d0e0f10"' \
    'border_gateway=true'; do
    grep -qF -- "${expected}" <<< "${PARSED}" || fail "'${expected}' did not survive the round trip"
done

echo "== ${PLATFORM}: every region file parses"
# The script runs inside the container, so its variables must not expand here.
# shellcheck disable=SC2016
run "${IMAGE}" bash -c '
    bash start --render > /dev/null 2>&1
    for f in regions/region_*.toml; do
        ./chirpstack-gateway-mesh -c run/config.toml -c "$f" configfile > /dev/null || { echo "rejected: $f"; exit 1; }
        echo "ok: $f"
    done' || fail "a region file was rejected"

echo "== ${PLATFORM}: service starts"
# With no concentratord to talk to, the service gets stuck or gives up after
# logging that it started, so the timeout ends it.
OUTPUT=$(run "${ENV[@]}" "${IMAGE}" \
    bash -c 'bash start --render > /dev/null && timeout -s KILL 10 ./chirpstack-gateway-mesh -c run/config.toml -c regions/region_us915.toml' 2>&1 || true)
echo "${OUTPUT}"
grep -q 'Starting ChirpStack Gateway Mesh (border_gateway: true' <<< "${OUTPUT}" \
    || fail "the service did not get past reading its configuration"

echo "== ${PLATFORM}: start script waits for concentratord"
OUTPUT=$(run "${IMAGE}" timeout -s KILL 8 bash start 2>&1 || true)
echo "${OUTPUT}"
grep -q 'Relaying for: *eu868' <<< "${OUTPUT}" || fail "the start script did not get to the banner"
if grep -q 'Starting ChirpStack Gateway Mesh' <<< "${OUTPUT}"; then
    fail "the service started before concentratord's sockets existed"
fi

echo "== ${PLATFORM}: OK"
