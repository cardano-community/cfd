#!/bin/bash

function run-cfd-migration-script {
     local CFD_DIR=$1
     local MIGRATION_SCRIPT=$2

     if [ -f "$CFD_DIR/$MIGRATION_SCRIPT" ]; then
         (
             cd "$CFD_DIR" || exit 1

             CARDANO_DIR="$CARDANO_DIR" \
             CARDANO_NETWORKS_DIR="$CARDANO_NETWORKS_DIR" \
             CARDANO_SOCKET_PATH="$CARDANO_SOCKET_PATH" \
             NETWORK_NAME="$NETWORK_NAME" \
             CONFIG_FILE="$CONFIG_FILE" \
             CFD_VERSION="$CFD_VERSION" \
             CFD_VERSION_FILE="$CFD_VERSION_FILE" \
             bash "$MIGRATION_SCRIPT"
         )
     fi
}

function update-cfd {
     local ARG_COUNT=${1:-0}
     local CFD_DIR
     local UPDATE_MARKER
     local NOW_TS
     local LAST_TS
     local STASH_BEFORE
     local STASH_AFTER
     local STASH_CREATED=false
     local UPSTREAM_REF
     local LOCAL_HEAD
     local REMOTE_HEAD
     local UPDATE_MARKER_EXISTS=false

     if [ "$ARG_COUNT" -gt 1 ]; then
         return 0
     fi

     CFD_DIR=$(cd "$(dirname "$0")" && pwd)
     UPDATE_MARKER="$CFD_DIR/.cfd-last-update-check"
     NOW_TS=$(date +%s)

     if [ -f "$UPDATE_MARKER" ]; then
         UPDATE_MARKER_EXISTS=true
         LAST_TS=$(cat "$UPDATE_MARKER" 2>/dev/null)
         if ! [[ "$LAST_TS" =~ ^[0-9]+$ ]]; then
             LAST_TS=0
         fi
     else
         LAST_TS=0
     fi

     if [ $((NOW_TS - LAST_TS)) -lt 3600 ]; then
         echo "$NOW_TS" > "$UPDATE_MARKER"
         return 0
     fi

     if ! git -C "$CFD_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
         echo "$NOW_TS" > "$UPDATE_MARKER"
         return 0
     fi

     UPSTREAM_REF=$(git -C "$CFD_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)

     if [ -z "$UPSTREAM_REF" ]; then
         echo "$NOW_TS" > "$UPDATE_MARKER"
         return 0
     fi

     if ! git -C "$CFD_DIR" fetch --quiet; then
         echo "$NOW_TS" > "$UPDATE_MARKER"
         return 0
     fi

     LOCAL_HEAD=$(git -C "$CFD_DIR" rev-parse HEAD 2>/dev/null)
     REMOTE_HEAD=$(git -C "$CFD_DIR" rev-parse "$UPSTREAM_REF" 2>/dev/null)

     if [ -z "$LOCAL_HEAD" ] || [ -z "$REMOTE_HEAD" ]; then
         echo "$NOW_TS" > "$UPDATE_MARKER"
         return 0
     fi

     if [ "$UPDATE_MARKER_EXISTS" = true ] && [ "$LOCAL_HEAD" == "$REMOTE_HEAD" ]; then
         echo "$NOW_TS" > "$UPDATE_MARKER"
         return 0
     fi

     if are-you-sure-dialog "An update is available. Do you want to apply it now?" "y"; then
         echo "Updating CFD..." 1>&2

         git -C "$CFD_DIR" restore --source="$UPSTREAM_REF" -- scripts/migrations-pre.sh 2>/dev/null

         run-cfd-migration-script "$CFD_DIR" "scripts/migrations-pre.sh"

         git -C "$CFD_DIR" restore --staged --worktree -- scripts/ 2>/dev/null
         git -C "$CFD_DIR" clean -fd -- scripts/ >/dev/null 2>&1

         STASH_BEFORE=$(git -C "$CFD_DIR" rev-parse -q --verify refs/stash 2>/dev/null)
         git -C "$CFD_DIR" stash push -u -m "cfd auto-update $(date -Iseconds)" -- . ':(exclude)scripts/**' ':(exclude).cfd-last-update-check' ':(exclude).cfd-version' >/dev/null 2>&1
         STASH_AFTER=$(git -C "$CFD_DIR" rev-parse -q --verify refs/stash 2>/dev/null)

         if [ -n "$STASH_AFTER" ] && [ "$STASH_AFTER" != "$STASH_BEFORE" ]; then
             STASH_CREATED=true
         fi

         if git -C "$CFD_DIR" pull; then
             run-cfd-migration-script "$CFD_DIR" "scripts/migrations-post.sh"
             echo "Update completed!" 1>&2
         else
             echo "CFD update failed. Continuing with the current version." 1>&2
         fi

         if [ "$STASH_CREATED" = true ]; then
             if ! git -C "$CFD_DIR" stash pop; then
                 echo "Restoring stashed local changes needs attention." 1>&2
             fi
         fi
     fi

     echo "$NOW_TS" > "$UPDATE_MARKER"
}
