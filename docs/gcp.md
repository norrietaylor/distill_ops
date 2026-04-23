# Google Cloud Run Deployment

Deploy the Distillery MCP server to [Google Cloud Run](https://cloud.google.com/run) with persistent DuckDB storage on a GCS FUSE volume, GitHub OAuth, and scale-to-zero billing.

## Prerequisites

- [Google Cloud SDK (`gcloud`)](https://cloud.google.com/sdk/docs/install) installed and authenticated: `gcloud auth login`
- A GCP project with billing enabled
- A [GitHub OAuth App](deployment.md#step-1-register-a-github-oauth-app) registered
- `bash`, `curl`, and `openssl` available in your shell

## Configuration Files

| File | Purpose |
|------|---------|
| `gcp/Dockerfile` | Extends the generic distillery image with GCP-specific config (volume ownership, config file, FastMCP state path) |
| `gcp/service.yaml` | Cloud Run service manifest (GCS FUSE mount, Secret Manager refs, max-instances=1, startup probe) |
| `gcp/distillery-gcp.yaml` | Distillery config (DuckDB on FUSE volume, Jina embeddings, GitHub OAuth, webhooks) |
| `gcp/bootstrap.sh` | Idempotent provisioner for all required GCP resources |

## Bootstrap

The bootstrap script provisions all GCP resources from a fresh project in a single command. It is safe to re-run — each step is idempotent.

```bash
bash gcp/bootstrap.sh \
  --project <gcp-project-id> \
  --region  us-central1 \
  --repo    <github-owner>/<github-repo>
```

Or using environment variables:

```bash
GCP_PROJECT=<gcp-project-id> \
GCP_REGION=us-central1 \
GCP_REPO=<github-owner>/<github-repo> \
bash gcp/bootstrap.sh
```

The script enables the required APIs, creates the GCS data bucket, Artifact Registry repository, service accounts, IAM bindings, and a Workload Identity Federation pool and provider.

At the end, the script prints a summary block:

```
================= BOOTSTRAP SUMMARY =================
Set these as GitHub Actions repository variables
(Settings -> Secrets and variables -> Actions -> Variables):

  GCP_PROJECT_ID=<project-id>
  GCP_DEPLOYER_SA=distillery-deployer@<project-id>.iam.gserviceaccount.com
  GCP_WIF_PROVIDER=projects/<number>/locations/global/workloadIdentityPools/distillery-deploy/providers/github

The deploy workflow (.github/workflows/gcp-deploy.yml) reads these
three variables and exchanges a GitHub OIDC token for a short-lived
access token — no service-account JSON key is ever issued.
=====================================================
```

Copy these three values into your GitHub repository variables before deploying.

## Secrets

Secrets are stored in GCP Secret Manager and injected into the Cloud Run revision at runtime. Create them before deploying:

```bash
# Jina embedding API key
echo -n "<your-jina-api-key>" | gcloud secrets create JINA_API_KEY \
  --project=<gcp-project-id> \
  --data-file=-

# GitHub OAuth app credentials
echo -n "<github-client-id>" | gcloud secrets create GITHUB_CLIENT_ID \
  --project=<gcp-project-id> \
  --data-file=-

echo -n "<github-client-secret>" | gcloud secrets create GITHUB_CLIENT_SECRET \
  --project=<gcp-project-id> \
  --data-file=-

# Webhook authorization secret (shared with scheduler.yml)
SECRET=$(openssl rand -hex 32)
echo -n "$SECRET" | gcloud secrets create DISTILLERY_WEBHOOK_SECRET \
  --project=<gcp-project-id> \
  --data-file=-

# Public URL for GitHub OAuth callbacks (fill in after first deploy)
echo -n "https://<service-name>-<hash>-<region>.run.app" | gcloud secrets create DISTILLERY_BASE_URL \
  --project=<gcp-project-id> \
  --data-file=-
```

To update an existing secret with a new value:

```bash
echo -n "<new-value>" | gcloud secrets versions add <SECRET_NAME> \
  --project=<gcp-project-id> \
  --data-file=-
```

## Deploy

### Via GitHub Actions (recommended)

After setting the three repository variables from the bootstrap summary:

```bash
gh workflow run gcp-deploy.yml \
  -f image_tag=latest \
  -f region=us-central1
```

The workflow builds the `gcp/Dockerfile`, pushes to Artifact Registry, deploys a Cloud Run revision, and runs a post-deploy smoke check. Authentication uses Workload Identity Federation — no service-account JSON key is needed.

### Manually

```bash
# Substitute PROJECT_ID and deploy
REGION=us-central1
PROJECT=<gcp-project-id>

sed \
  -e "s|image: .*distillery/distillery:.*|image: ${REGION}-docker.pkg.dev/${PROJECT}/distillery/distillery:latest|" \
  -e "s|PROJECT_ID|${PROJECT}|g" \
  gcp/service.yaml > /tmp/service-deploy.yaml

gcloud run services replace /tmp/service-deploy.yaml \
  --region="${REGION}" \
  --project="${PROJECT}"
```

## Verification

```bash
# Get the service URL
SERVICE_URL=$(gcloud run services describe distillery \
  --region=us-central1 \
  --project=<gcp-project-id> \
  --format="value(status.url)")

# Smoke check: OAuth discovery endpoint
curl -sf "${SERVICE_URL}/.well-known/oauth-authorization-server"

# MCP tools list (after completing OAuth)
curl -X POST "${SERVICE_URL}/mcp" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":1}'

# View logs
gcloud run services logs read distillery \
  --region=us-central1 \
  --project=<gcp-project-id>
```

## Scheduler Wiring

The GitHub Actions workflow at `.github/workflows/scheduler.yml` drives scheduled feed polling, rescoring, and KB maintenance. To include the GCP deployment in the schedule, set a single repository variable:

```bash
# Get the Cloud Run service URL
SERVICE_URL=$(gcloud run services describe distillery \
  --region=us-central1 \
  --project=<gcp-project-id> \
  --format="value(status.url)")

# Set the GitHub repo variable (Fly remains the primary target)
gh variable set DISTILLERY_GCP_URL --body "${SERVICE_URL}"

# The webhook secret must match what you stored in Secret Manager
gh secret set DISTILLERY_WEBHOOK_SECRET --body "$SECRET"
```

When `DISTILLERY_GCP_URL` is set, the scheduler fires each webhook against both Fly and GCP **in parallel** (matrix strategy). When `DISTILLERY_GCP_URL` is unset or empty, behavior is unchanged — only the Fly target is called.

The job summary emits a per-target status line after each webhook call:

```
fly: ok
gcp: ok
```

The scheduled cadence is:

| Schedule | Endpoint | Operation |
|----------|----------|-----------|
| Hourly (:23) | `POST /api/poll` | Poll all feed sources |
| Daily (06:17 UTC) | `POST /api/rescore` | Re-score feed entries |
| Weekly (Mon 07:41 UTC) | `POST /api/maintenance` | KB metrics, quality, stale detection, digest |

Verify a webhook manually:

```bash
curl -sf -X POST \
  -H "Authorization: Bearer $SECRET" \
  "${SERVICE_URL}/api/poll"
```

## Connecting from Claude Code

```json
{
  "mcpServers": {
    "distillery": {
      "url": "https://<service-name>-<hash>-<region>.run.app/mcp",
      "transport": "http"
    }
  }
}
```

Claude Code triggers the GitHub OAuth flow on first connection.

## Architecture

| Aspect | Details |
|--------|---------|
| **Transport** | Streamable HTTP (FastMCP) on port 8000 + REST webhooks at `/api/*` |
| **Storage** | Local DuckDB on GCS FUSE volume (`/data/distillery.db`) |
| **Auth** | GitHub OAuth via FastMCP `GitHubProvider` (identity gate only) |
| **Scaling** | `max_instances=1` (single replica — see constraint below); `min_instances=0` (scale to zero when idle) |
| **Single-replica constraint** | GCS FUSE exposes filesystem semantics over GCS objects. DuckDB assumes a single process owns the `.db` file and its WAL. Running two concurrent revisions would corrupt the database. `max_instances=1` is a hard requirement and must not be raised without switching to a multi-writer-safe storage backend. |
| **Concurrency** | `containerConcurrency=10` (matches Fly `hard_limit=10`) |
| **Memory** | 1024 MiB minimum (matches Fly; 512 MiB OOM'd on embedding-heavy polls) |
| **CPU** | 2 vCPU; CPU unthrottled (`cpu-throttling: false`) so GCS FUSE mount finishes before startup probe |
| **Cold start** | GCS FUSE adds ~1-3 s; startup probe allows ~30 s grace |
| **Execution environment** | Cloud Run second-generation (`executionEnvironment: gen2`) — required for GCS FUSE volume mounts |
| **CI auth** | Workload Identity Federation (no service-account JSON keys) |
| **Cost** | Scale-to-zero: $0 compute at idle. GCS storage for a 100 MB database plus FUSE operations is typically under $1/month. See the [GCP pricing calculator](https://cloud.google.com/products/calculator) for an estimate against your usage profile. |

### Authentication Model

GitHub OAuth is used purely as an **identity gate** — it verifies who the caller is, not what they can access on GitHub. The server never gains access to user repositories or organizations.

The flow (handled by FastMCP's `GitHubProvider`):

1. OAuth requests only the `user` scope (read-only public profile)
2. `GitHubTokenVerifier` calls `https://api.github.com/user` to verify tokens
3. Identity claims (`login`, `name`, `email`) are available to tool handlers
4. The raw GitHub token is never exposed to application code

### Rate Limiting

| Guard | Default | Purpose |
|-------|---------|---------|
| `embedding_budget_daily` | 500 | Max Jina API calls/day (0 = unlimited) |
| `max_db_size_mb` | 900 | Reject writes above this DB size |
| `warn_db_size_pct` | 80 | Warn in `distillery_metrics` at this % |

Budget counters are stored in DuckDB's `_meta` table and survive scale-to-zero cold starts.

## Backup

GCS natively versions objects, but versioning is disabled on the data bucket (DuckDB writes are self-consistent; versioning multiplies storage cost without adding recovery value for this workload). For point-in-time backups, copy the database file directly:

```bash
# One-off backup to a separate GCS path
gcloud storage cp \
  "gs://<project-id>-distillery-data/distillery.db" \
  "gs://<project-id>-distillery-data/backups/distillery-$(date +%Y%m%d).db"

# List backups
gcloud storage ls "gs://<project-id>-distillery-data/backups/"
```

Consider scheduling a periodic backup via Cloud Scheduler or a separate GitHub Actions cron job if the database accumulates data you cannot afford to lose.

> **Future hardening:** Data at rest uses Google-managed encryption keys (GMEK) by default. Customer-managed encryption keys (CMEK) are out of scope for v1 and can be added as a follow-up.
