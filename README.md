# cf-one-ip-list-update

A lightweight Docker container that monitors your public IP address and automatically keeps a [Cloudflare One (Zero Trust) IP list ](https://developers.cloudflare.com/cloudflare-one/reusable-components/lists/) up to date.

Useful for allowlisting your home or office IP in Cloudflare Zero Trust policies when you have a dynamic IP address.

## How it works

On each check interval the container:

1. Fetches your current public IP from `https://cloudflare.com/cdn-cgi/trace`
2. Skips the update if the IP hasn't changed since the last check
3. If the IP changed: retrieves all existing entries from the Cloudflare list, then sends a single PATCH request that adds the new IP and removes all old ones

## Prerequisites

- A Cloudflare account with Zero Trust enabled
- A Cloudflare API token with **Zero Trust: Edit** permission
- An existing Cloudflare Gateway IP list (note the List ID from the dashboard URL)

## Configuration

Copy `.env.example` to `.env` and fill in your values:

```
CLOUDFLARE_ACCOUNT_ID=your_account_id
CLOUDFLARE_API_TOKEN=your_api_token
CLOUDFLARE_LIST_ID=your_list_id
CHECK_INTERVAL=60
LOG_VERBOSE=false
```

| Variable | Required | Default | Description |
|---|---|---|---|
| `CLOUDFLARE_ACCOUNT_ID` | Yes | — | Your Cloudflare account ID |
| `CLOUDFLARE_API_TOKEN` | Yes | — | API token with Gateway: Edit permission |
| `CLOUDFLARE_LIST_ID` | Yes | — | ID of the Gateway IP list to manage |
| `CHECK_INTERVAL` | No | `60` | Seconds between IP checks |
| `LOG_VERBOSE` | No | `false` | Log a message each cycle even when IP is unchanged |

## Usage

### docker run

```bash
docker run -d \
  --name cf-one-ip-list-update \
  --restart unless-stopped \
  --env-file .env \
  ghcr.io/xelio/cf-one-ip-list-update:latest
```

### Docker Compose

```yaml
services:
  cf-one-ip-list-update:
    image: ghcr.io/xelio/cf-one-ip-list-update:latest
    restart: unless-stopped
    env_file: .env
```

Or with inline environment variables:

```yaml
services:
  cf-one-ip-list-update:
    image: ghcr.io/xelio/cf-one-ip-list-update:latest
    restart: unless-stopped
    environment:
      CLOUDFLARE_ACCOUNT_ID: ${CLOUDFLARE_ACCOUNT_ID}
      CLOUDFLARE_API_TOKEN: ${CLOUDFLARE_API_TOKEN}
      CLOUDFLARE_LIST_ID: ${CLOUDFLARE_LIST_ID}
      CHECK_INTERVAL: 60
      LOG_VERBOSE: "false"
```

### View logs

```bash
docker logs -f cf-one-ip-list-update
```

Example output:

```
2026-03-23T09:50:27+00:00 Starting Cloudflare IP list updater
2026-03-23T09:50:27+00:00 Check interval: 60s | Verbose: false
2026-03-23T09:50:44+00:00 IP changed: none -> 203.0.113.42
2026-03-23T09:50:56+00:00 Successfully updated list with IP: 203.0.113.42
```

## Building locally

```bash
docker build -t cf-one-ip-list-update .
docker run -d --name cf-one-ip-list-update --restart unless-stopped --env-file .env cf-one-ip-list-update
```

## Image updates

The GitHub Action rebuilds and pushes the image to GHCR automatically:

- On every push to `main`
- Weekly on Mondays (to pick up base image security patches)

Images older than 3 months are cleaned up automatically.
