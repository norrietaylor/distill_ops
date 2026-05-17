# GCP Cloud Run deployment — extends the generic distillery image with
# Cloud Run-specific configuration (volume ownership, config file, FastMCP state).
#
# The generic image is built and published by the distillery repo's
# supply-chain.yml workflow to ghcr.io/norrietaylor/distillery.

ARG IMAGE_TAG=latest
FROM ghcr.io/norrietaylor/distillery:${IMAGE_TAG}

USER root

# Persist FastMCP OAuth state (client registrations, tokens) on the GCS FUSE volume
# so tokens survive Cloud Run revisions and scale-to-zero cold starts.
ENV FASTMCP_HOME=/data/fastmcp

# Copy Cloud Run-specific config
COPY gcp/distillery-gcp.yaml /app/distillery-gcp.yaml
ENV DISTILLERY_CONFIG=/app/distillery-gcp.yaml

RUN chown -R appuser:appuser /app

EXPOSE 8000

# Fix volume ownership at runtime (GCS FUSE mounts as root), then drop to appuser.
# Cloud Run invokes with USER=appuser, but `/data` comes from the FUSE mount as root-owned.
CMD ["sh", "-c", "chown -R appuser:appuser /data && exec su -s /bin/sh appuser -c 'distillery-mcp --transport http'"]
