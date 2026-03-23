FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl jq ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -r -s /usr/sbin/nologin appuser

COPY update-ip.sh /usr/local/bin/update-ip.sh
RUN chmod +x /usr/local/bin/update-ip.sh

USER appuser

ENTRYPOINT ["/usr/local/bin/update-ip.sh"]
