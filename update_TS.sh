#!/bin/bash
#
# Updates peers blocklist and TorrServer binary, restarts TorrServer
# only if something has changed. Started by start_TS.sh and by cron.
# Usage: update_TS.sh [--now]   (--now: skip the random delay)
#

TS_BIN=/TS/TorrServer
TS_PID_FILE=/TS/TorrServer.pid
TS_RESTART_FLAG=/TS/TorrServer.restart
UPD_DIR=/TS/updates

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [update] $*"
}

# shellcheck source=/dev/null
[ -e /TS/runtime.env ] && . /TS/runtime.env

# Only one update at a time
exec 9>/TS/update.lock
flock -n 9 || { log "Another update is running, skipping."; exit 0; }

# Random delay for scheduled runs, so that not every container hits github at once
[ "$1" != "--now" ] && sleep $((RANDOM % 40))

rm -rf "$UPD_DIR"
mkdir -p "$UPD_DIR"
trap 'rm -rf "$UPD_DIR"' EXIT

fix_owner() {
    [ "${PUID:-0}" != "0" ] || [ "${PGID:-0}" != "0" ] && chown -R "$PUID:$PGID" "$@"
}

download() {
    curl -fsSL --retry 3 --connect-timeout 20 --max-time 300 -A "$USER_AGENT" -o "$2" "$1"
}

# Asks the supervisor in start_TS.sh to restart TorrServer
restart_ts() {
    local pid
    pid=$(cat "$TS_PID_FILE" 2>/dev/null)
    [ -z "$pid" ] && return
    touch "$TS_RESTART_FLAG"
    kill -TERM "$pid" 2>/dev/null
    # with "-k" option TorrServer ignores signals
    for _ in $(seq 8); do
        kill -0 "$pid" 2>/dev/null || return
        sleep 1
    done
    kill -KILL "$pid" 2>/dev/null
}

# Waits until the web server responds, prints its version
wait_ts() {
    local ver
    for _ in $(seq 30); do
        sleep 1
        ver=$(curl -fsS --max-time 2 "http://localhost:$TS_PORT/echo" 2>/dev/null) && { echo "$ver"; return 0; }
    done
    return 1
}

# Converts eMule ipfilter.dat / P2P / plain lists to the PeerGuardian P2P
# format ("name:first-last") that TorrServer reads from the "blocklist" file.
# Ranges are sorted and merged, private and multicast networks are skipped.
parse_blocklist() {
    local ip='[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'
    grep -v '^#' \
        | tr -d '[:blank:]' \
        | sed -E "s/[a-zA-Z]${ip}//g; s/${ip}[a-zA-Z]//g" \
        | grep -oE "$ip(-$ip)?" \
        | awk -F '[.-]' '
            {
                for (i = 1; i <= NF; i++) if ($i > 255) next
                if ($1 == 0 || $1 == 10 || $1 == 127 || $1 >= 224) next
                if ($1 == 172 && $2 >= 16 && $2 <= 31) next
                if ($1 == 192 && $2 == 168) next
                first = (($1 * 256 + $2) * 256 + $3) * 256 + $4
                last = NF == 8 ? (($5 * 256 + $6) * 256 + $7) * 256 + $8 : first
                if (last < first) { t = first; first = last; last = t }
                printf "%.0f %.0f\n", first, last
            }' \
        | sort -n -k 1,1 -k 2,2 \
        | awk '
            function ip(n) {
                return int(n / 16777216) "." int(n / 65536) % 256 "." int(n / 256) % 256 "." n % 256
            }
            function out() { print "blocklist:" ip(first) "-" ip(last) }
            NR == 1 { first = $1; last = $2; next }
            $1 <= last + 1 { if ($2 > last) last = $2; next }
            { out(); first = $1; last = $2 }
            END { if (NR) out() }'
}

need_restart=0
updated_bin=0

# ---------------------------------------------------------------------------
# Peers blocklist
# ---------------------------------------------------------------------------
if [ -n "$BIP_URL" ]; then
    log "Checking for blocklist updates from $BIP_URL ..."
    raw="$UPD_DIR/blocklist_raw"
    if download "$BIP_URL" "$raw"; then
        case $(file -b --mime-type "$raw") in
            application/zip)                    unzip -p "$raw" ;;
            application/gzip|application/x-gzip) gunzip -c "$raw" ;;
            text/*)                             cat "$raw" ;;
            *) log "Unknown blocklist format: $(file -b "$raw")" ;;
        esac | parse_blocklist > "$UPD_DIR/blocklist"

        bl_size=$(wc -l < "$UPD_DIR/blocklist")
        if [ "$bl_size" -eq 0 ]; then
            log "Error: no addresses found in the blocklist."
        elif cmp -s "$UPD_DIR/blocklist" "$TS_CONF_PATH/blocklist"; then
            log "Blocklist is up to date ($bl_size ranges)."
        else
            cp -f "$UPD_DIR/blocklist" "$TS_CONF_PATH/blocklist"
            chmod 644 "$TS_CONF_PATH/blocklist"
            fix_owner "$TS_CONF_PATH/blocklist"
            log "Blocklist updated: $bl_size ranges."
            need_restart=1
        fi
    else
        log "Error: can't download the blocklist."
    fi
fi

# ---------------------------------------------------------------------------
# TorrServer
# ---------------------------------------------------------------------------
if [ "$TS_UPDATE" = "true" ]; then
    log "Checking for TorrServer updates ($TS_RELEASE) ..."
    new_bin="$UPD_DIR/TorrServer"
    if download "$TS_URL" "$new_bin" && chmod 755 "$new_bin" \
        && new_ver=$("$new_bin" --version 2>/dev/null) && [ -n "$new_ver" ]; then
        current_ver=$("$TS_BIN" --version 2>/dev/null)
        if [ "$new_ver" != "$current_ver" ]; then
            log "Updating ${current_ver:-TorrServer} -> $new_ver ..."
            mkdir -p "$TS_CONF_PATH/backup"
            cp -f "$TS_BIN" "$TS_CONF_PATH/backup/TorrServer"
            fix_owner "$TS_CONF_PATH/backup"
            # mv instead of cp: the running binary can't be overwritten
            cp -f "$new_bin" "$TS_BIN.new" && mv -f "$TS_BIN.new" "$TS_BIN"
            updated_bin=1
            need_restart=1
        else
            log "$current_ver is up to date."
        fi
    else
        log "Error: no internet access or the downloaded file is corrupted."
    fi
fi

# ---------------------------------------------------------------------------
# Restart
# ---------------------------------------------------------------------------
if [ "$need_restart" = 1 ]; then
    log "Restarting TorrServer ..."
    restart_ts
    if running_ver=$(wait_ts); then
        log "TorrServer $running_ver is running."
    elif [ "$updated_bin" = 1 ]; then
        log "Error: new version doesn't start, restoring backup."
        cp -f "$TS_CONF_PATH/backup/TorrServer" "$TS_BIN.new" && mv -f "$TS_BIN.new" "$TS_BIN"
        restart_ts
        wait_ts >/dev/null && log "Backup restored."
    else
        log "Error: TorrServer doesn't respond after restart."
    fi
fi

log "Finished."
