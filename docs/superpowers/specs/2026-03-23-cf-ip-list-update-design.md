# Cloudflare IP List Updater — Design Spec

## Overview

A Docker container that monitors the host's public IP address and updates a Cloudflare Zero Trust gateway IP list when it changes. Designed to run as a long-lived container with configurable check intervals.

## Architecture

Single shell script (`update-ip.sh`) running an infinite sleep loop inside a `debian:bookworm-slim` container. No external orchestration needed — Docker's restart policy handles crash recovery.

### Project Structure

```
cf-ip-list-update/
├── update-ip.sh              # Main script
├── Dockerfile                # debian-slim based image
├── .env.test                 # Test environment variables (not committed)
├── .gitignore                # Ignores .env.test
└── .github/
    └── workflows/
        └── build.yml         # Build, push, cleanup
```

## Shell Script (`update-ip.sh`)

### Flow

1. Validate required environment variables at startup; exit with error if missing.
2. Enter infinite loop:
   a. Get public IP via `curl -s https://cloudflare.com/cdn-cgi/trace`, parse the `ip=` line.
   b. Compare with last known IP (held in a shell variable). If unchanged, log if verbose mode is on, then sleep and repeat.
   c. Fetch existing list items from Cloudflare API: `GET /accounts/$ACCOUNT_ID/gateway/lists/$LIST_ID/items`. Extract item values from `result[]` using `jq`.
   d. Patch the list: `PATCH /accounts/$ACCOUNT_ID/gateway/lists/$LIST_ID` with `append` (new IP) and `remove` (old item values).
   e. Update the stored IP variable.
   f. Sleep `CHECK_INTERVAL` seconds.

### Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `CLOUDFLARE_ACCOUNT_ID` | yes | — | Cloudflare account ID |
| `CLOUDFLARE_API_TOKEN` | yes | — | API bearer token |
| `CLOUDFLARE_LIST_ID` | yes | — | Gateway list ID |
| `CHECK_INTERVAL` | no | `60` | Seconds between checks |
| `LOG_VERBOSE` | no | `false` | Log every check cycle including "IP unchanged" |

### Error Handling

- Required env vars validated at startup before entering the loop. Script exits immediately if any are missing.
- Network/API errors are logged to stderr. The loop continues on failure — transient issues are retried on the next cycle.
- HTTP status codes and Cloudflare `success` field are checked on every API call.

### Logging

- Startup: logs config summary (interval, verbose mode).
- IP change: logs old and new IP with timestamp.
- API errors: logs HTTP code and response body to stderr.
- Verbose mode (`LOG_VERBOSE=true`): additionally logs every "IP unchanged" check.
- All timestamps in ISO 8601 format via `date -Iseconds`.

## Dockerfile

Based on `debian:bookworm-slim`.

1. Install `curl`, `jq`, `ca-certificates` via apt. Clean up apt cache.
2. Create a non-root user (`appuser`).
3. Copy `update-ip.sh` to `/usr/local/bin/`, make executable.
4. Switch to non-root user via `USER`.
5. Entrypoint: `["/usr/local/bin/update-ip.sh"]`.

No healthcheck — the script's loop and logging serve as the heartbeat.

## GitHub Action (`.github/workflows/build.yml`)

### Triggers

- Push to `main` branch.
- Weekly schedule: Monday 00:00 UTC (`cron: '0 0 * * 1'`).

### Jobs

#### `build-and-push`

1. Checkout repository.
2. Log in to GHCR via `docker/login-action` using `GITHUB_TOKEN`.
3. Set up Docker Buildx via `docker/setup-buildx-action`.
4. Generate image tags via `docker/metadata-action`:
   - `latest`
   - Git SHA (short)
   - Date: `YYYY-MM-DD`
5. Build and push via `docker/build-push-action`.

#### `cleanup`

Runs after `build-and-push` succeeds.

- Uses `dataaxiom/ghcr-cleanup-action`.
- Removes images older than 3 months.
- Keeps at least 1 tagged image (`keep-n-tagged: 1`) to preserve `latest`.

## Cloudflare API Interactions

### Get List Items

```
GET https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/gateway/lists/$LIST_ID/items
Authorization: Bearer $CLOUDFLARE_API_TOKEN
```

Response: `result` is a flat array of objects with `value` and `created_at` fields. Extract all `value` fields via `jq '[.result[].value]'` for the remove list.

### Patch List

```
PATCH https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/gateway/lists/$LIST_ID
Content-Type: application/json
Authorization: Bearer $CLOUDFLARE_API_TOKEN
```

Body:
```json
{
  "append": [{"value": "<new_ip>"}],
  "remove": ["<old_value_1>", "<old_value_2>"]
}
```

## Local Testing

`.env.test` holds environment variables for local testing:

```
CLOUDFLARE_ACCOUNT_ID=<your-account-id>
CLOUDFLARE_API_TOKEN=<your-api-token>
CLOUDFLARE_LIST_ID=<your-list-id>
CHECK_INTERVAL=60
LOG_VERBOSE=true
```

Run locally with: `docker run --env-file .env.test <image>`

This file is listed in `.gitignore` to prevent accidental credential commits. A `.gitignore` file will be included in the project.

## Decisions

- **debian-slim over Alpine**: chosen for broader compatibility.
- **Sleep loop over cron**: more Docker-idiomatic, simpler interval configuration (seconds vs crontab syntax), no PID 1 issues.
- **Single script**: the logic is linear and simple; splitting into multiple scripts adds complexity with no benefit.
- **Non-root user**: security best practice for containers.
