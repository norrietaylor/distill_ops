# Fly.io deployment — extends the generic distillery image with
# Fly-specific configuration (volume ownership, config file, FastMCP state).
#
# The generic image is built and published by the distillery repo's
# supply-chain.yml workflow to ghcr.io/norrietaylor/distillery.

ARG IMAGE_TAG=latest

# Static busybox stage — provides /bin/sh and the basic utilities our
# build-time RUN and runtime CMD depend on (chown, rm, echo, su, ln).
# The upstream distillery image switched to a shell-less base, so
# `RUN <command>` (which Docker invokes via `/bin/sh -c`) and the
# CMD's `sh -c "chown ... && if [...] && exec su ..."` both fail with
# `exec: "/bin/sh": stat /bin/sh: no such file or directory`. busybox
# is a single static binary; symlinking the applets is enough to make
# the existing scripts work without rewriting the init contract.
# Track upstream restoration of a POSIX shell in norrietaylor/distillery.
FROM busybox:musl AS shell

FROM ghcr.io/norrietaylor/distillery:${IMAGE_TAG}

USER root

# Inject busybox + symlinks for the applets we depend on. The RUN below
# uses exec form so it does not require /bin/sh — it directly execs
# busybox, which then creates the /bin/sh symlink that subsequent
# shell-form RUN and CMD instructions need.
COPY --from=shell /bin/busybox /usr/local/bin/busybox
RUN ["/usr/local/bin/busybox", "ln", "-sf", "/usr/local/bin/busybox", "/bin/sh"]
RUN ["/usr/local/bin/busybox", "ln", "-sf", "/usr/local/bin/busybox", "/bin/chown"]
RUN ["/usr/local/bin/busybox", "ln", "-sf", "/usr/local/bin/busybox", "/bin/rm"]
RUN ["/usr/local/bin/busybox", "ln", "-sf", "/usr/local/bin/busybox", "/bin/echo"]
RUN ["/usr/local/bin/busybox", "ln", "-sf", "/usr/local/bin/busybox", "/bin/su"]

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
