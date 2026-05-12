#!/bin/bash

CONFIG_FILE=${CONFIG_FILE:-"conf.json"}
CFD_VERSION_FILE=${CFD_VERSION_FILE:-".cfd-version"}
STARTUP_SCRIPT_FILE=${STARTUP_SCRIPT_FILE:-"scripts/startup.sh"}

if [ -f "$CFD_VERSION_FILE" ]; then
    CFD_INSTALLED_VERSION=$(cat "$CFD_VERSION_FILE" 2>/dev/null)
else
    CFD_INSTALLED_VERSION="$CFD_VERSION"
fi

function is-cfd-version-before {
    local CURRENT_VERSION="$1"
    local TARGET_VERSION="$2"
    local FIRST_VERSION

    if [ -z "$CURRENT_VERSION" ]; then
        return 0
    fi

    FIRST_VERSION=$(printf "%s\n%s\n" "$CURRENT_VERSION" "$TARGET_VERSION" | sort -V | head -n 1)

    [ "$FIRST_VERSION" == "$CURRENT_VERSION" ] && [ "$CURRENT_VERSION" != "$TARGET_VERSION" ]
}

function bump-cfd-version {
    local TARGET_VERSION="$1"

    echo "$TARGET_VERSION" > "$CFD_VERSION_FILE"
    CFD_INSTALLED_VERSION="$TARGET_VERSION"
}

function run-cfd-migration {
    local TARGET_VERSION="$1"
    local MIGRATION_FUNCTION="$2"

    if ! is-cfd-version-before "$CFD_INSTALLED_VERSION" "$TARGET_VERSION"; then
        return 0
    fi

    if "$MIGRATION_FUNCTION"; then
        bump-cfd-version "$TARGET_VERSION"
    else
        return 1
    fi
}

function migrate-node-socket-path-to-config {
    local NODE_SOCKET_PATH
    local TMP_CONFIG

    if grep -Fq 'CARDANO_SOCKET_PATH=$(from-config ".networks.\"${NETWORK_NAME}\".software.\"cardano-node\".\"node-socket-path\"")' "$STARTUP_SCRIPT_FILE"; then
        return 0
    fi

    echo "Run migration 2.26..."
    NODE_SOCKET_PATH="$CARDANO_SOCKET_PATH"

    if [ -z "$NODE_SOCKET_PATH" ]; then
        NODE_SOCKET_PATH="./cardano.socket"
    elif [ -n "$CARDANO_NETWORKS_DIR" ]; then
        NODE_SOCKET_PATH="${NODE_SOCKET_PATH/#$CARDANO_NETWORKS_DIR/.}"
    fi

    TMP_CONFIG=$(mktemp)

    if jq --arg node_socket_path "$NODE_SOCKET_PATH" '
        .networks |= (
            with_entries(
                if .value.software["cardano-node"] then
                    .value.software["cardano-node"]["node-socket-path"] = $node_socket_path
                else
                    .
                end
            )
        )
    ' "$CONFIG_FILE" > "$TMP_CONFIG"; then
        mv "$TMP_CONFIG" "$CONFIG_FILE"
    else
        rm -f "$TMP_CONFIG"
        return 1
    fi

}

function run-cfd-migrations {
    run-cfd-migration "2.26" migrate-node-socket-path-to-config
}

run-cfd-migrations
