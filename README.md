# distill_ops

Deployment configurations for [Distillery](https://github.com/norrietaylor/distillery) — the team knowledge base for Claude Code.

This repo contains platform-specific deployment configs, workflows, and documentation. The generic Distillery Docker image is built and published by the main distillery repo to `ghcr.io/norrietaylor/distillery`.

## Deployments

### Fly.io (`fly/`)

Local DuckDB on a persistent volume with GitHub OAuth.

```bash
cd fly
flyctl launch --copy-config
flyctl secrets set JINA_API_KEY=... GITHUB_CLIENT_ID=... GITHUB_CLIENT_SECRET=... DISTILLERY_WEBHOOK_SECRET=...
flyctl deploy
```

See [fly/README.md](fly/README.md) for full setup instructions.

### Prefect Horizon (`prefect/`)

MotherDuck cloud DuckDB with GitHub OAuth.

```bash
cd prefect
prefect deploy --prefect-file prefect.yaml
```

See [prefect/README.md](prefect/README.md) for full setup instructions.

## Workflows

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `fly-deploy.yml` | Manual dispatch | Deploy GHCR image to Fly.io |
| `scheduler.yml` | Cron (hourly/daily/weekly) | Call webhook endpoints for feed polling, rescoring, maintenance |

## Image Source

The Docker image is built from the [distillery](https://github.com/norrietaylor/distillery) repo's root `Dockerfile` and published to GHCR by its `supply-chain.yml` workflow:

```
ghcr.io/norrietaylor/distillery:latest
ghcr.io/norrietaylor/distillery:sha-<commit>
ghcr.io/norrietaylor/distillery:v<version>
```

Fly.io's `Dockerfile` extends this base image with Fly-specific config (volume ownership, `distillery-fly.yaml`, FastMCP state persistence).

## Documentation

- [Fly.io Deployment Guide](docs/fly.md)
- [Prefect Horizon Guide](docs/prefect.md)
- [Main Distillery Docs](https://norrietaylor.github.io/distillery/)
