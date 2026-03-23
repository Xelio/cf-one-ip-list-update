#!/bin/bash
set -euo pipefail

# Required env vars
: "${CLOUDFLARE_ACCOUNT_ID:?ERROR: CLOUDFLARE_ACCOUNT_ID is required}"
: "${CLOUDFLARE_API_TOKEN:?ERROR: CLOUDFLARE_API_TOKEN is required}"
: "${CLOUDFLARE_LIST_ID:?ERROR: CLOUDFLARE_LIST_ID is required}"

# Optional env vars with defaults
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"
LOG_VERBOSE="${LOG_VERBOSE:-false}"

API_BASE="https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/gateway/lists/${CLOUDFLARE_LIST_ID}"
LAST_IP=""

log() {
    echo "$(date -Iseconds) $1"
}

log_error() {
    echo "$(date -Iseconds) ERROR: $1" >&2
}

get_public_ip() {
    local trace
    trace=$(curl -sf --max-time 10 https://cloudflare.com/cdn-cgi/trace) || {
        log_error "Failed to fetch public IP"
        return 1
    }
    local ip
    ip=$(echo "$trace" | grep '^ip=' | cut -d'=' -f2)
    if [ -z "$ip" ]; then
        log_error "Could not parse IP from trace response"
        return 1
    fi
    echo "$ip"
}

get_list_items() {
    local response http_code body
    response=$(curl -s --max-time 10 -w "\n%{http_code}" \
        "${API_BASE}/items" \
        -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}") || {
        log_error "Failed to connect to Cloudflare API"
        return 1
    }
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" -ne 200 ]; then
        log_error "Get list items failed (HTTP ${http_code}): ${body}"
        return 1
    fi

    local success
    success=$(echo "$body" | jq -r '.success')
    if [ "$success" != "true" ]; then
        log_error "Get list items API returned success=false: ${body}"
        return 1
    fi

    echo "$body"
}

patch_list() {
    local new_ip="$1"
    local remove_values="$2"

    local payload
    payload=$(jq -n \
        --arg ip "$new_ip" \
        --argjson remove "$remove_values" \
        '{append: [{value: $ip}], remove: $remove}')

    local response http_code body
    response=$(curl -s --max-time 10 -w "\n%{http_code}" \
        "${API_BASE}" \
        -X PATCH \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        -d "$payload") || {
        log_error "Failed to connect to Cloudflare API for patch"
        return 1
    }
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" -ne 200 ]; then
        log_error "Patch list failed (HTTP ${http_code}): ${body}"
        return 1
    fi

    local success
    success=$(echo "$body" | jq -r '.success')
    if [ "$success" != "true" ]; then
        log_error "Patch list API returned success=false: ${body}"
        return 1
    fi

    echo "$body"
}

update_ip() {
    local current_ip
    current_ip=$(get_public_ip) || return 1

    if [ "$current_ip" = "$LAST_IP" ]; then
        if [ "$LOG_VERBOSE" = "true" ]; then
            log "IP unchanged: ${current_ip}"
        fi
        return 0
    fi

    log "IP changed: ${LAST_IP:-none} -> ${current_ip}"

    local list_response
    list_response=$(get_list_items) || return 1

    local remove_values
    remove_values=$(echo "$list_response" | jq '[.result[].value]')

    patch_list "$current_ip" "$remove_values" > /dev/null || return 1

    LAST_IP="$current_ip"
    log "Successfully updated list with IP: ${current_ip}"
}

# Startup
log "Starting Cloudflare IP list updater"
log "Check interval: ${CHECK_INTERVAL}s | Verbose: ${LOG_VERBOSE}"

while true; do
    update_ip || log_error "Update failed, will retry next interval"
    sleep "$CHECK_INTERVAL"
done
