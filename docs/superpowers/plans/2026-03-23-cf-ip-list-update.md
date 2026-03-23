# Cloudflare IP List Updater Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Docker container that monitors public IP changes and updates a Cloudflare Zero Trust gateway IP list.

**Architecture:** Single shell script with infinite sleep loop in a `debian:bookworm-slim` container. GitHub Action builds/pushes to GHCR with weekly rebuilds and 3-month cleanup.

**Tech Stack:** Bash, curl, jq, Docker, GitHub Actions

**Spec:** `docs/superpowers/specs/2026-03-23-cf-ip-list-update-design.md`

---

### Task 1: Create .gitignore and .env.example

**Files:**
- Create: `.gitignore`
- Create: `.env.example`

**Prerequisites:** `.env.test` already exists with real credentials (not committed).

- [x] **Step 1: Create .gitignore**

```gitignore
.env*
!.env.example
```

- [x] **Step 2: Create .env.example as a committable template**

```
CLOUDFLARE_ACCOUNT_ID=
CLOUDFLARE_API_TOKEN=
CLOUDFLARE_LIST_ID=
CHECK_INTERVAL=60
LOG_VERBOSE=false
```

- [x] **Step 3: Commit**

```bash
git add .gitignore .env.example
git commit -m "chore: add .gitignore and .env.example template"
```

---

### Task 2: Write the shell script

**Files:**
- Create: `update-ip.sh`

- [x] **Step 1: Create update-ip.sh with env validation and defaults**

```bash
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
```

- [x] **Step 2: Make executable**

```bash
chmod +x update-ip.sh
```

- [x] **Step 3: Test the script locally with .env.test**

```bash
set -a && source .env.test && set +a && bash update-ip.sh &
# Wait a few seconds for one cycle, then kill
sleep 5 && kill %1
```

Expected: Should log startup message, detect IP change, and update the Cloudflare list.

- [x] **Step 4: Verify the Cloudflare list was updated**

```bash
source .env.test && curl -s "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/gateway/lists/${CLOUDFLARE_LIST_ID}/items" \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" | jq '.result[].value'
```

Expected: Should show the current public IP.

- [x] **Step 5: Commit**

```bash
git add update-ip.sh
git commit -m "feat: add IP update shell script"
```

---

### Task 3: Create the Dockerfile

**Files:**
- Create: `Dockerfile`

- [x] **Step 1: Create Dockerfile**

```dockerfile
FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl jq ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -r -s /usr/sbin/nologin appuser

COPY update-ip.sh /usr/local/bin/update-ip.sh
RUN chmod +x /usr/local/bin/update-ip.sh

USER appuser

ENTRYPOINT ["/usr/local/bin/update-ip.sh"]
```

- [x] **Step 2: Build the image**

```bash
docker build -t cf-ip-list-update:test .
```

Expected: Build succeeds with no errors.

- [x] **Step 3: Test run the container**

```bash
docker run -d --name cf-test --env-file .env.test cf-ip-list-update:test && sleep 10 && docker logs cf-test && docker stop cf-test && docker rm cf-test
```

Expected: Container starts, logs startup message, detects IP, updates Cloudflare list.

- [x] **Step 4: Verify Cloudflare list was updated**

```bash
source .env.test && curl -s "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/gateway/lists/${CLOUDFLARE_LIST_ID}/items" \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" | jq '.result[].value'
```

Expected: Shows current public IP.

- [x] **Step 5: Commit**

```bash
git add Dockerfile
git commit -m "feat: add Dockerfile for IP list updater"
```

---

### Task 4: Create GitHub Action workflow

**Files:**
- Create: `.github/workflows/build.yml`

- [x] **Step 1: Create directory and workflow file**

```bash
mkdir -p .github/workflows
```

```yaml
name: Build and Push Docker Image

on:
  push:
    branches: [main]
  schedule:
    - cron: '0 0 * * 1'  # Weekly on Monday 00:00 UTC

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Extract metadata
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
          tags: |
            type=raw,value=latest
            type=sha,prefix=
            type=raw,value={{date 'YYYY-MM-DD'}}

      - name: Build and push
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}

  cleanup:
    runs-on: ubuntu-latest
    needs: build-and-push
    permissions:
      packages: write

    steps:
      - name: Clean up old images
        uses: dataaxiom/ghcr-cleanup-action@v1
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
          older-than: 3 months
          keep-n-tagged: 1
```

- [x] **Step 2: Validate YAML syntax**

```bash
cat .github/workflows/build.yml | python3 -c "import sys,yaml; yaml.safe_load(sys.stdin); print('YAML valid')" 2>&1 || echo "Note: install pyyaml (pip install pyyaml) if this fails. The YAML can also be validated by pushing and checking GitHub Actions."
```

Expected: "YAML valid" (requires `pyyaml` — skip if unavailable)

- [x] **Step 3: Commit**

```bash
git add .github/workflows/build.yml
git commit -m "ci: add GitHub Action for Docker build, push, and cleanup"
```
