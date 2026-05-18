# GCP Cloud Run deployment — extends the generic distillery image with
# Cloud Run-specific configuration (config file, FastMCP state path).
#
# The generic image is built and published by the distillery repo's
# supply-chain.yml workflow to ghcr.io/norrietaylor/distillery.
#
# That base image is Chainguard-based: shell-less, and it already runs as
# the non-root user uid 65532 with ENTRYPOINT ["distillery-mcp"] and
# CMD ["--transport", "http"]. This Dockerfile therefore only layers on
# config — no `USER root`, no build-time `RUN` (which would need /bin/sh),
# no runtime shell wrapper. The upstream ENTRYPOINT + CMD run verbatim.

ARG IMAGE_TAG=latest
FROM ghcr.io/norrietaylor/distillery:${IMAGE_TAG}

# Persist FastMCP OAuth state (client registrations, tokens) on the GCS FUSE
# volume so tokens survive Cloud Run revisions and scale-to-zero cold starts.
ENV FASTMCP_HOME=/data/fastmcp

# Cloud Run-specific config. Owned by uid/gid 65532 (the upstream Chainguard
# `nonroot` user) to match the rest of /app — so no build-time chown is
# needed, which is also why no shell-form `RUN` appears here: the base image
# has no /bin/sh.
COPY --chown=65532:65532 gcp/distillery-gcp.yaml /app/distillery-gcp.yaml
ENV DISTILLERY_CONFIG=/app/distillery-gcp.yaml

EXPOSE 8000

# No ENTRYPOINT/CMD override: the base image's
#   ENTRYPOINT ["/app/.venv/bin/distillery-mcp"]  CMD ["--transport", "http"]
# already starts the server as uid 65532. The GCS FUSE volume at /data is
# mounted read-write and accessible to the runtime service account — DuckDB
# writes there directly, with no runtime chown (chown is unsupported on a
# gcsfuse mount anyway). If a revision logs /data permission errors, set
# gcsfuse `mountOptions` (uid=65532,gid=65532) in gcp/service.yaml rather
# than reintroducing a chown.
