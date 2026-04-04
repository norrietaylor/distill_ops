# Fly.io deployment — extends the generic distillery image with
# Fly-specific configuration (volume ownership, config file, FastMCP state).
#
# The generic image is built and published by the distillery repo's
# supply-chain.yml workflow to ghcr.io/norrietaylor/distillery.

ARG IMAGE_TAG=latest
FROM ghcr.io/norrietaylor/distillery:${IMAGE_TAG}

USER root

# Persist FastMCP OAuth state (client registrations, tokens) on the Fly volume
# so tokens survive machine autostop/restart cycles.
ENV FASTMCP_HOME=/data/fastmcp

# Copy Fly-specific config
COPY fly/distillery-fly.yaml /app/distillery-fly.yaml
ENV DISTILLERY_CONFIG=/app/distillery-fly.yaml

RUN chown -R appuser:appuser /app

EXPOSE 8000

# Fix volume ownership at runtime (Fly mounts as root), then drop to appuser.
# Set RESET_DB=true in Fly secrets to wipe the database on next boot (one-shot).
CMD ["sh", "-c", "chown -R appuser:appuser /data && if [ \"$RESET_DB\" = 'true' ]; then rm -f /data/distillery.db /data/distillery.db.wal && echo 'DB reset complete'; fi && exec su -s /bin/sh appuser -c 'distillery-mcp --transport http'"]
