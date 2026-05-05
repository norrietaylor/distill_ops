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

# Copy Fly-specific config. Owned by uid/gid 65532 (the upstream Chainguard
# `nonroot` user — see distillery#419 / its root Dockerfile) so a separate
# build-time recursive chown isn't needed: every other file under /app is
# already 65532-owned by the upstream image.
COPY --chown=65532:65532 fly/distillery-fly.yaml /app/distillery-fly.yaml
ENV DISTILLERY_CONFIG=/app/distillery-fly.yaml

EXPOSE 8000

# Clear the upstream ENTRYPOINT (`distillery-mcp`) so our CMD runs as
# the literal command instead of being appended as arguments to the
# entrypoint binary. Without this, Docker concatenates ENTRYPOINT + CMD
# into `distillery-mcp sh -c "<our script>"`, which makes argparse fail
# with `unrecognized arguments: sh -c chown ...` and exit 2 in a tight
# crash loop. The new init responsibility belongs to our shell script —
# it does the runtime chown / RESET_DB / privilege drop and only then
# execs `distillery-mcp` itself.
ENTRYPOINT []

# Fix volume ownership at runtime (Fly mounts as root), then drop to the
# upstream `nonroot` user (uid/gid 65532). The chown uses uid:gid form so
# it doesn't depend on /etc/passwd lookups; the privilege drop uses the
# username `nonroot` because busybox `su` takes a name (Chainguard's
# distroless image ships /etc/passwd with the `nonroot` entry).
# Set RESET_DB=true in Fly secrets to wipe the database on next boot (one-shot).
CMD ["sh", "-c", "chown -R 65532:65532 /data && if [ \"$RESET_DB\" = 'true' ]; then rm -f /data/distillery.db /data/distillery.db.wal && echo 'DB reset complete'; fi && exec su -s /bin/sh nonroot -c 'distillery-mcp --transport http'"]
