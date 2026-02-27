#!/usr/bin/env bash
set -euo pipefail

input=$(cat)

# Feature flags
ENABLE_USAGE_FETCH=false  # Disabled: OAuth token not available in container

# --- Output cache: skip all work if recently computed (2s TTL) ---
OUTPUT_CACHE="/tmp/claude_sl_out"
FIRST_RUN_MARKER="/tmp/claude_sl_init"
now=$(date +%s)

# Platform-aware stat for mtime in epoch seconds
_stat_mtime() {
    if [[ "$(uname)" == "Darwin" ]]; then
        stat -f %m "$1" 2>/dev/null
    else
        stat -c %Y "$1" 2>/dev/null
    fi
}

if [ -f "$OUTPUT_CACHE" ]; then
    output_mtime=$(_stat_mtime "$OUTPUT_CACHE") || output_mtime=0
    if (( now - output_mtime < 2 )); then
        cat "$OUTPUT_CACHE"
        exit 0
    fi
elif [ ! -f "$FIRST_RUN_MARKER" ]; then
    # Very first invocation ever - return placeholder instantly, compute in background
    touch "$FIRST_RUN_MARKER"
    _dir=$(jq -r '.workspace.current_dir // ""' <<< "$input" 2>/dev/null)
    _dir="${_dir##*/}"
    printf "[\033[31mSANDBOX\033[0m \033[37m%s\033[0m] \033[2m\033[0m" "$_dir"
    # Run the full script in background so the cache is warm for the next call
    (bash "$0" <<< "$input" > /dev/null 2>&1) &
    disown 2>/dev/null
    exit 0
fi

# Parse input JSON (single jq call)
used_pct=0 cwd="" model_name="unknown" session_id="default"
eval "$(jq -r '@sh "used_pct=\(.context_window.used_percentage // 0) cwd=\(.workspace.current_dir // "") model_name=\(.model.display_name // .model.id // "unknown") session_id=\(.session_id // "default")"' <<< "$input")"

# Fetch 5-hour usage from Anthropic OAuth API (cached for 60s)
CACHE_FILE="/tmp/claude_usage_cache.json"
CACHE_MAX_AGE=60
session_pct=0
resets_at=""
diff=0

if [ "$ENABLE_USAGE_FETCH" = true ]; then

fetch_usage() {
    local token response

    # Try macOS keychain first, then fall back to .claude.json
    if command -v security &>/dev/null; then
        local creds
        creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null) || return 1
        token=$(jq -r '.claudeAiOauth.accessToken // empty' <<< "$creds" 2>/dev/null) || return 1
    elif [ -f "$HOME/.claude.json" ]; then
        token=$(jq -r '.claudeAiOauth.accessToken // empty' "$HOME/.claude.json" 2>/dev/null) || return 1
    else
        return 1
    fi
    [ -z "$token" ] && return 1

    response=$(curl -s --max-time 3 \
        -H "Authorization: Bearer $token" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "User-Agent: claude-code-statusline/1.0" \
        "https://api.anthropic.com/api/oauth/usage" 2>/dev/null) || return 1

    echo "$response" > "$CACHE_FILE"
}

# Always fetch in background - never block the statusline
read_cache=false
if [ -f "$CACHE_FILE" ]; then
    cache_mtime=$(_stat_mtime "$CACHE_FILE") || cache_mtime=0
    if (( now - cache_mtime > CACHE_MAX_AGE )); then
        fetch_usage &>/dev/null &
        disown 2>/dev/null
    fi
    read_cache=true
else
    fetch_usage &>/dev/null &
    disown 2>/dev/null
fi

# Read usage cache
if [ "$read_cache" = true ] && [ -f "$CACHE_FILE" ]; then
    eval "$(jq -r '@sh "session_pct=\(.five_hour.utilization // 0) resets_iso=\(.five_hour.resets_at // "")"' "$CACHE_FILE" 2>/dev/null)"
    session_pct=${session_pct%.*}
    [ -z "$session_pct" ] && session_pct=0

    if [ -n "$resets_iso" ]; then
        if [[ "$(uname)" == "Darwin" ]]; then
            clean_ts=$(sed -E 's/\.[0-9]+//; s/:([0-9]{2})$/\1/' <<< "$resets_iso")
            reset_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$clean_ts" +%s 2>/dev/null) || reset_epoch=0
        else
            reset_epoch=$(date -d "$resets_iso" +%s 2>/dev/null) || reset_epoch=0
        fi
        diff=$((reset_epoch - now))
        if [ "$diff" -gt 0 ]; then
            hrs=$((diff / 3600))
            mins=$(( (diff % 3600) / 60 ))
            if [ "$hrs" -gt 0 ]; then
                resets_at="${hrs}h${mins}m"
            else
                resets_at="${mins}m"
            fi
        fi
    fi
fi

fi  # ENABLE_USAGE_FETCH

# Build progress bars inline (no subshells - functions set variables directly)
_build_bar() {
    local pct=$1 filled=$(($1 * 10 / 100)) i
    _bar=""
    for ((i=0; i<filled; i++)); do _bar+="█"; done
    for ((i=filled; i<10; i++)); do _bar+="░"; done
}

_build_bar "$used_pct"; context_bar="$_bar"

# Colour thresholds (no subshells, $'...' for real escape bytes)
if [ "$used_pct" -lt 50 ]; then context_colour=$'\033[32m'
elif [ "$used_pct" -lt 75 ]; then context_colour=$'\033[33m'
else context_colour=$'\033[31m'; fi

session_bar=""
session_colour=""
if [ "$ENABLE_USAGE_FETCH" = true ]; then
    _build_bar "$session_pct"; session_bar="$_bar"
    if [ "$session_pct" -lt 50 ]; then session_colour=$'\033[32m'
    elif [ "$session_pct" -lt 75 ]; then session_colour=$'\033[33m'
    else session_colour=$'\033[31m'; fi
fi

# Parameter expansion instead of basename subprocess
dir_name="${cwd##*/}"

# --- Model usage tracking per session ---
MODEL_TRACK_DIR="/tmp/claude_model_tracking"
mkdir -p "$MODEL_TRACK_DIR"
MODEL_TRACK_FILE="${MODEL_TRACK_DIR}/${session_id}"

# Clean up stale session files in background (~5% of runs)
if (( RANDOM % 20 == 0 )); then
    find "$MODEL_TRACK_DIR" -type f -mtime +1 -delete 2>/dev/null &
    disown 2>/dev/null
fi

# Increment count for current model (single jq call)
if [ -f "$MODEL_TRACK_FILE" ]; then
    jq --arg m "$model_name" '.[$m] = ((.[$m] // 0) + 1)' "$MODEL_TRACK_FILE" > "${MODEL_TRACK_FILE}.tmp" 2>/dev/null && \
        mv "${MODEL_TRACK_FILE}.tmp" "$MODEL_TRACK_FILE"
else
    printf '{\"%s\":%d}' "$model_name" 1 > "$MODEL_TRACK_FILE"
fi

# Model colour helper (sets _mcolour, no subshell)
_model_colour() {
    case "$1" in
        *Opus*)   _mcolour=$'\033[35m' ;;
        *Sonnet*) _mcolour=$'\033[34m' ;;
        *Haiku*)  _mcolour=$'\033[32m' ;;
        *)        _mcolour=$'\033[37m' ;;
    esac
}

# Build segmented model bar from tracking data (single jq call)
model_bar_width=10
model_bar=""
model_legend=""
if [ -f "$MODEL_TRACK_FILE" ]; then
    tracking_data=$(jq -r '
        ([.[]] | add // 0) as $total |
        length as $count |
        "\($total) \($count)",
        (to_entries | sort_by(-.value) | .[] | "\(.key)=\(.value)")
    ' "$MODEL_TRACK_FILE" 2>/dev/null) || tracking_data=""

    if [ -n "$tracking_data" ]; then
        # Read header line without spawning head
        IFS= read -r _header <<< "$tracking_data"
        read -r total_ticks model_count <<< "$_header"
        total_ticks=${total_ticks:-0}
        model_count=${model_count:-0}

        if [ "$total_ticks" -gt 0 ]; then
            filled_so_far=0
            model_idx=0
            active_pct=0

            # Read remaining lines without spawning tail
            _rest="${tracking_data#*$'\n'}"
            while IFS='=' read -r m_name m_ticks; do
                [ -z "$m_name" ] && continue
                model_idx=$((model_idx + 1))
                _model_colour "$m_name"
                if [ "$model_idx" -eq "$model_count" ]; then
                    blocks=$((model_bar_width - filled_so_far))
                else
                    blocks=$((m_ticks * model_bar_width / total_ticks))
                    [ "$blocks" -lt 1 ] && blocks=1
                fi
                filled_so_far=$((filled_so_far + blocks))

                segment=""
                for ((i=0; i<blocks; i++)); do segment+="█"; done
                model_bar="${model_bar}${_mcolour}${segment}"$'\033[0m'

                if [ "$m_name" = "$model_name" ]; then
                    active_pct=$((m_ticks * 100 / total_ticks))
                fi
            done <<< "$_rest"

            _model_colour "$model_name"
            model_legend="${_mcolour}${model_name} ${active_pct}%"$'\033[0m'
        fi
    fi
fi

# Fallback if no tracking data yet
if [ -z "$model_bar" ]; then
    _model_colour "$model_name"
    model_bar="${_mcolour}"
    for ((i=0; i<model_bar_width; i++)); do model_bar+="█"; done
    model_bar+=$'\033[0m'
    model_legend="${_mcolour}${model_name} 100%"$'\033[0m'
fi

reset_str=""
if [ "$ENABLE_USAGE_FETCH" = true ] && [ -n "$resets_at" ]; then
    if [ "$diff" -lt 1800 ]; then
        reset_str=$' \033[94m'"${resets_at}"$'\033[0m'
    else
        reset_str=$' \033[97m'"${resets_at}"$'\033[0m'
    fi
fi

# Write output to cache and display
# SANDBOX prefix in red, then dir name, then metrics
usage_section=""
if [ "$ENABLE_USAGE_FETCH" = true ]; then
    printf -v usage_section " | 📶 %s%s\033[0m%s%%%s" \
        "$session_colour" "$session_bar" "$session_pct" "$reset_str"
fi

printf "[\033[31mSANDBOX\033[0m \033[37m%s\033[0m] 🧠 %s%s\033[0m%s%%%s | 🧑‍💻 %s %s" \
    "$dir_name" "$context_colour" "$context_bar" "$used_pct" \
    "$usage_section" \
    "$model_bar" "$model_legend" \
    | tee "$OUTPUT_CACHE"
