#!/bin/bash
#
# Container entrypoint: prepares configuration, then supervises TorrServer.
# TorrServer is restarted automatically if it exits (crash or update),
# SIGTERM from "docker stop" is forwarded to it for a graceful shutdown.
#

TS_BIN=/TS/TorrServer
TS_PID_FILE=/TS/TorrServer.pid
TS_RESTART_FLAG=/TS/TorrServer.restart
RUNTIME_ENV=/TS/runtime.env

# Options that can be set via docker env or ts.ini (docker env wins)
TS_SETTINGS="TS_PORT TS_RELEASE TS_UPDATE TS_OPTIONS LINUX_UPDATE BIP_URL cron_task PUID PGID UMASK"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [start] $*"
}

section() {
    echo " "
    echo "============================================="
    log "$*"
    echo "============================================="
}

# Sleep that can be interrupted by a trapped signal
nap() {
    sleep "$1" &
    wait $!
}

# ---------------------------------------------------------------------------
# Architecture
# ---------------------------------------------------------------------------
case $(dpkg --print-architecture) in
    amd64) ARCH="amd64" ;;
    arm64) ARCH="arm64" ;;
    armhf) ARCH="arm7" ;;
    i386)  ARCH="386" ;;
    *) log "Unsupported architecture $(dpkg --print-architecture). Can't continue."; exit 1 ;;
esac
BIN_NAME="TorrServer-linux-${ARCH}"

# ---------------------------------------------------------------------------
# Default configuration files (only if missing or empty)
# ---------------------------------------------------------------------------
mkdir -p "$TS_CONF_PATH" "$TS_TORR_DIR"
ln -sfn "$TS_TORR_DIR" /torrents

for f in ts.ini settings.json; do
    if [ ! -s "$TS_CONF_PATH/$f" ]; then
        cp -f "/defaults/$f" "$TS_CONF_PATH/$f"
        log "Default $TS_CONF_PATH/$f created."
    fi
done

# ---------------------------------------------------------------------------
# Settings: docker env > ts.ini > defaults
# ---------------------------------------------------------------------------
declare -A FROM_ENV
for v in $TS_SETTINGS; do
    [ -n "${!v}" ] && FROM_ENV[$v]="${!v}"
done

# ts.ini may be edited on Windows, so strip CR without touching the file
# shellcheck source=/dev/null
. <(tr -d '\r' < "$TS_CONF_PATH/ts.ini")

for v in "${!FROM_ENV[@]}"; do
    printf -v "$v" '%s' "${FROM_ENV[$v]}"
done

: "${TS_PORT:=8090}"
: "${TS_RELEASE:=latest}"
: "${TS_UPDATE:=true}"
: "${LINUX_UPDATE:=false}"
: "${PUID:=0}"
: "${PGID:=0}"

# Empty env values are ignored, so "none" is the way to disable these from env
[ "$BIP_URL" = "none" ] && BIP_URL=""
[ "$cron_task" = "none" ] && cron_task=""

if [ "$TS_RELEASE" = "latest" ]; then
    TS_URL="https://github.com/YouROK/TorrServer/releases/latest/download/$BIN_NAME"
else
    TS_URL="https://github.com/YouROK/TorrServer/releases/download/$TS_RELEASE/$BIN_NAME"
fi

# shellcheck disable=SC2086,SC2163
export $TS_SETTINGS TS_URL

section "Settings:"
for v in $TS_SETTINGS; do
    src="default"
    [ -n "${FROM_ENV[$v]+x}" ] && src="env"
    grep -q "^[[:space:]]*$v=" "$TS_CONF_PATH/ts.ini" && [ "$src" = "default" ] && src="ts.ini"
    printf '  %-13s = %-30s (%s)\n' "$v" "${!v}" "$src"
done

[ -n "$UMASK" ] && umask "$UMASK"

# ---------------------------------------------------------------------------
# Migration: earlier versions of this image wrote the peers blocklist from
# BIP_URL to bip.txt, but TorrServer uses bip.txt as the web access blacklist
# (MatriX.147+ imports it into "waf" section of settings.json).
# Peers blocklist now lives in the "blocklist" file.
# ---------------------------------------------------------------------------
if [ -n "$BIP_URL" ]; then
    for f in bip.txt bip.txt.bak; do
        if [ -e "$TS_CONF_PATH/$f" ]; then
            rm -f "$TS_CONF_PATH/$f"
            log "Removed legacy $TS_CONF_PATH/$f (peers blocklist is in $TS_CONF_PATH/blocklist now)."
        fi
    done
    waf_size=$(jq '.waf.blacklist | length' "$TS_CONF_PATH/settings.json" 2>/dev/null)
    if [ "${waf_size:-0}" -gt 1000 ]; then
        cp -f "$TS_CONF_PATH/settings.json" "$TS_CONF_PATH/settings.json.bak"
        if jq '.waf.blacklist = []' "$TS_CONF_PATH/settings.json.bak" > "$TS_CONF_PATH/settings.json.new"; then
            mv -f "$TS_CONF_PATH/settings.json.new" "$TS_CONF_PATH/settings.json"
            log "Cleared web access blacklist imported from legacy bip.txt ($waf_size entries)," \
                "backup: $TS_CONF_PATH/settings.json.bak"
        else
            rm -f "$TS_CONF_PATH/settings.json.new"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# OS updates (optional, slows down the start)
# ---------------------------------------------------------------------------
if [ "$LINUX_UPDATE" = "true" ]; then
    section "Checking for Linux updates ..."
    apt-get update && apt-get upgrade -y && apt-get clean
    rm -rf /var/lib/apt/lists/*
    log "Finished checking for Linux updates."
fi

# ---------------------------------------------------------------------------
# TorrServer binary: bundled in the image, re-downloaded only when it is
# broken or does not match a pinned TS_RELEASE
# ---------------------------------------------------------------------------
current_ver=$("$TS_BIN" --version 2>/dev/null)
if [ -z "$current_ver" ] || { [ "$TS_RELEASE" != "latest" ] && [ "$current_ver" != "TorrServer $TS_RELEASE" ]; }; then
    section "Downloading $BIN_NAME ($TS_RELEASE) ..."
    if curl -fsSL --retry 3 --connect-timeout 20 --max-time 300 -A "$USER_AGENT" -o "$TS_BIN.new" "$TS_URL" \
        && chmod 755 "$TS_BIN.new" && "$TS_BIN.new" --version >/dev/null 2>&1; then
        mv -f "$TS_BIN.new" "$TS_BIN"
        log "Downloaded $("$TS_BIN" --version)."
    else
        rm -f "$TS_BIN.new"
        log "Download failed, keeping ${current_ver:-current binary}."
    fi
fi

# ---------------------------------------------------------------------------
# Ownership of the data directory (Unraid: PUID=99, PGID=100)
# ---------------------------------------------------------------------------
if [ "$PUID" != "0" ] || [ "$PGID" != "0" ]; then
    find "$TS_CONF_PATH" \( ! -user "$PUID" -o ! -group "$PGID" \) -exec chown -h "$PUID:$PGID" {} +
fi

# Environment for update_TS.sh (cron runs with an empty environment)
# shellcheck disable=SC2086
declare -px $TS_SETTINGS TS_URL TS_CONF_PATH TS_TORR_DIR USER_AGENT GODEBUG PATH > "$RUNTIME_ENV"
[ -n "$TZ" ] && declare -px TZ >> "$RUNTIME_ENV"

# ---------------------------------------------------------------------------
# Scheduled updates
# ---------------------------------------------------------------------------
if [ -n "$cron_task" ]; then
    echo "$cron_task /update_TS.sh > /proc/1/fd/1 2>&1" | crontab -
    cron
    section "Cron task set to: $cron_task"
else
    crontab -r 2>/dev/null
fi

# ---------------------------------------------------------------------------
# Supervisor
# ---------------------------------------------------------------------------
TS_PID=""
STOPPING=0
# Leftovers if the container was stopped during an update
rm -f "$TS_PID_FILE" "$TS_RESTART_FLAG"

stop_ts() {
    [ -z "$TS_PID" ] && return
    kill -TERM "$TS_PID" 2>/dev/null
    # TorrServer stops within 5 sec, with "-k" option it ignores signals
    for _ in $(seq 8); do
        kill -0 "$TS_PID" 2>/dev/null || return
        sleep 1
    done
    kill -KILL "$TS_PID" 2>/dev/null
}

shutdown() {
    STOPPING=1
    section "Stopping TorrServer ..."
    stop_ts
}
trap shutdown TERM INT

if [ "$TS_UPDATE" = "true" ]; then
    /update_TS.sh --now &
fi

fails=0
while [ "$STOPPING" = 0 ]; do
    opts="$TS_OPTIONS"
    if [ "$fails" -ge 1 ] && [ -n "$opts" ]; then
        log "Starting without options \"$opts\"."
        opts=""
    fi
    if [ "$fails" -eq 2 ] && [ -x "$TS_CONF_PATH/backup/TorrServer" ]; then
        log "Restoring TorrServer from $TS_CONF_PATH/backup."
        cp -f "$TS_CONF_PATH/backup/TorrServer" "$TS_BIN.new" && mv -f "$TS_BIN.new" "$TS_BIN"
    fi
    if [ "$fails" -ge 3 ]; then
        log "TorrServer keeps failing. If the binary is corrupted, download it from"
        log "https://github.com/YouROK/TorrServer/releases, rename to TorrServer and put to $TS_CONF_PATH/backup/"
        nap 60
        [ "$STOPPING" = 1 ] && break
    fi

    section "Starting $("$TS_BIN" --version 2>/dev/null) ..."
    cd "$TS_CONF_PATH" || exit 1
    # shellcheck disable=SC2086
    setpriv --reuid="$PUID" --regid="$PGID" --clear-groups \
        "$TS_BIN" --path "$TS_CONF_PATH/" --torrentsdir "$TS_TORR_DIR" --port "$TS_PORT" $opts &
    TS_PID=$!
    echo "$TS_PID" > "$TS_PID_FILE"
    started=$SECONDS

    wait "$TS_PID"
    rc=$?
    # wait is interrupted by a trapped signal: wait for the real exit
    if [ "$STOPPING" = 1 ]; then
        wait "$TS_PID" 2>/dev/null
        break
    fi
    rm -f "$TS_PID_FILE"

    if [ -e "$TS_RESTART_FLAG" ]; then
        rm -f "$TS_RESTART_FLAG"
        fails=0
        log "Restart requested by update."
        continue
    fi

    if (( SECONDS - started < 15 )); then
        fails=$((fails + 1))
        log "TorrServer exited with code $rc right after start (attempt $fails)."
    else
        fails=0
        log "TorrServer exited with code $rc, restarting."
    fi
    nap 2
done

rm -f "$TS_PID_FILE"
log "Stopped."
