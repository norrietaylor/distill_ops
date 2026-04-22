# 01-spec-gcp-cloud-run-deployment

## Introduction/Overview

Add a third first-class deployment target for the Distillery MCP server: **Google Cloud Run** with a **GCS FUSE** volume for DuckDB persistence. This parallels the existing `fly/` and `prefect/` targets and gives operators a GCP-native option with scale-to-zero pricing, HTTPS by default, and keyless CI auth. The deployment pulls the same public `ghcr.io/norrietaylor/distillery` base image used by the Fly deployment and layers GCP-specific config (config file, FastMCP state path, volume ownership) on top.

## Goals

1. A new `gcp/` directory in this repo containing Dockerfile, Distillery config, and Cloud Run service manifest — structurally parallel to `fly/` and `prefect/`.
2. An idempotent bootstrap script that provisions all required GCP resources (Artifact Registry, GCS bucket, service accounts, Workload Identity Federation pool/provider) from a fresh project.
3. A GitHub Actions workflow (`gcp-deploy.yml`) that builds the image, pushes to Artifact Registry, and deploys a Cloud Run revision — authenticated via WIF, no long-lived keys.
4. The existing `scheduler.yml` workflow can target the GCP deployment via a new `DISTILLERY_GCP_URL` repo variable, without duplicating workflow logic.
5. A deployed instance passes the same smoke tests the Fly deployment passes: GitHub OAuth flow completes, `POST /mcp` returns `tools/list`, and the `/api/poll` webhook executes end-to-end.

## User Stories

- As a **Distillery operator evaluating GCP**, I want to deploy to Cloud Run by following `docs/gcp.md`, so that I can run Distillery on my organization's existing GCP footprint without adopting Fly.io or a third-party hosted platform.
- As a **repo maintainer**, I want the GCP deployment CI to authenticate without a long-lived service-account JSON in GitHub secrets, so that we do not inherit a key-rotation burden.
- As an **operator running Distillery on GCP**, I want DuckDB state to survive Cloud Run revisions and scale-to-zero cold starts, so that I do not lose knowledge entries between requests.
- As the **project owner**, I want scheduled polls/rescoring/maintenance to fire on the GCP instance using the same `scheduler.yml` that already drives Fly, so that I do not maintain two scheduling systems.

## Demoable Units of Work

### Unit 1: GCP Project Bootstrap

**Purpose:** Produce a single, re-runnable script that takes a fresh GCP project and provisions every resource the Cloud Run deployment depends on. This is the foundation — no later unit can be demonstrated without it.

**Functional Requirements:**
- The system shall provide a shell script at `gcp/bootstrap.sh` that accepts a GCP project ID, region, and GitHub repo (`owner/name`) as parameters (flags or environment variables).
- The script shall enable the required GCP APIs (`run.googleapis.com`, `artifactregistry.googleapis.com`, `iamcredentials.googleapis.com`, `storage.googleapis.com`, `secretmanager.googleapis.com`).
- The script shall create a GCS bucket (`<project-id>-distillery-data`) in the target region with uniform bucket-level access enabled and versioning **disabled** (DuckDB writes are self-consistent; versioning multiplies storage cost without adding recovery value for this workload).
- The script shall create an Artifact Registry Docker repository (`distillery`) in the target region.
- The script shall create two service accounts: `distillery-run` (Cloud Run runtime identity) and `distillery-deployer` (GitHub Actions identity).
- The script shall grant `distillery-run` the `roles/storage.objectAdmin` role scoped to the data bucket and `roles/secretmanager.secretAccessor` at project scope.
- The script shall grant `distillery-deployer` the minimum roles for CI deploy (`roles/run.admin`, `roles/artifactregistry.writer`, `roles/iam.serviceAccountUser` on `distillery-run`).
- The script shall create a Workload Identity Federation pool and provider bound to the GitHub OIDC issuer, with an attribute condition restricting the trust relationship to the specified GitHub repo.
- The script shall be idempotent — running it a second time shall produce no errors and no resource drift.
- The script shall print a final summary block containing the WIF provider resource name and the deployer service-account email (the two values the GitHub workflow needs).

**Proof Artifacts:**
- CLI: `bash gcp/bootstrap.sh --project test-proj --region us-central1 --repo norrietaylor/distill_ops` completes exit 0 on a fresh project.
- CLI: Re-running the same command completes exit 0 (idempotence).
- CLI: `gcloud iam workload-identity-pools providers describe github --location=global --workload-identity-pool=distillery-deploy` returns the provider with the expected `attribute.repository` condition.
- File: `gcp/bootstrap.sh` exists and is executable (`chmod +x` set).

### Unit 2: Cloud Run Service Definition

**Purpose:** Deliver the container image, config file, and service manifest needed to run Distillery on Cloud Run with durable DuckDB storage. After this unit, an operator with bootstrapped infrastructure can deploy a working MCP server with a single `gcloud run services replace` command.

**Functional Requirements:**
- The system shall include `gcp/Dockerfile` that extends `ghcr.io/norrietaylor/distillery:${IMAGE_TAG}` (default `latest`), copies `distillery-gcp.yaml` to `/app/`, sets `DISTILLERY_CONFIG=/app/distillery-gcp.yaml` and `FASTMCP_HOME=/data/fastmcp`, and fixes `/data` ownership to `appuser` at runtime before dropping privileges.
- The system shall include `gcp/distillery-gcp.yaml` configured with `storage.backend: duckdb`, `storage.database_path: /data/distillery.db`, Jina embeddings (`api_key_env: JINA_API_KEY`), GitHub OAuth (`client_id_env`/`client_secret_env`), and webhooks enabled (`secret_env: DISTILLERY_WEBHOOK_SECRET`).
- The system shall include `gcp/service.yaml` — a Cloud Run service manifest declaring: `max_instances=1`, `min_instances=0`, container port 8000, a GCS FUSE volume named `data` mounted at `/data` bound to the bootstrap bucket, the `distillery-run` service account as runtime identity, required secrets as Secret Manager references (`JINA_API_KEY`, `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`, `DISTILLERY_WEBHOOK_SECRET`, `DISTILLERY_BASE_URL`), and a startup probe against `/.well-known/oauth-authorization-server`.
- The system shall document secret creation commands (`gcloud secrets create ... --data-file=-`) in `docs/gcp.md` — secrets are out of scope for the bootstrap script because they require operator-provided values.
- The system shall use Cloud Run **second-generation** execution environment (required for GCS FUSE volume mounts).
- The system shall set a Cloud Run request timeout of at least 300 seconds to accommodate embedding-heavy polls.
- The Cloud Run service shall be deployable using only the files in `gcp/` plus a single `gcloud run services replace gcp/service.yaml --region=...` invocation.

**Proof Artifacts:**
- CLI: `docker build -f gcp/Dockerfile --build-arg IMAGE_TAG=latest -t local-test .` succeeds.
- CLI: `gcloud run services replace gcp/service.yaml --region=us-central1` deploys a revision reporting `Ready=True`.
- CLI: `curl https://<service-url>/.well-known/oauth-authorization-server` returns HTTP 200 with valid OAuth metadata JSON.
- CLI: `curl -X POST https://<service-url>/mcp -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","method":"tools/list","id":1}'` returns a tools array after completing OAuth.
- File: `gcp/service.yaml` contains `executionEnvironment: gen2` and a `csi: gcsfuse.run.googleapis.com` volume entry.
- CLI: After forcing a revision redeploy, `ls` in the running container shows `/data/distillery.db` is preserved (durability check).

### Unit 3: CI Deploy Workflow

**Purpose:** Push-button deploys from GitHub to Cloud Run, authenticated via Workload Identity Federation. Mirrors the ergonomics of `fly-deploy.yml` but for GCP.

**Functional Requirements:**
- The system shall add `.github/workflows/gcp-deploy.yml`, triggered by `workflow_dispatch` with inputs for `image_tag` (default `latest`) and `region` (default `us-central1`).
- The workflow shall authenticate to GCP using `google-github-actions/auth` with `workload_identity_provider` and `service_account` inputs sourced from repo variables (`GCP_WIF_PROVIDER`, `GCP_DEPLOYER_SA`, `GCP_PROJECT_ID`).
- The workflow shall never reference a service-account JSON key; it shall fail loudly if one is detected in secrets.
- The workflow shall build `gcp/Dockerfile`, push to `<region>-docker.pkg.dev/<project>/distillery/distillery:<git-sha>` (and `:latest`), and deploy a new Cloud Run revision via `gcloud run services replace gcp/service.yaml` with the image reference substituted.
- The workflow shall perform a post-deploy smoke check: `curl -sf https://<service-url>/.well-known/oauth-authorization-server` and fail the job if the probe does not return 200 within 60 seconds.
- The workflow shall run `concurrency: gcp-deploy` to prevent overlapping deploys.
- The workflow shall not touch the Fly deployment path or modify shared state used by `fly-deploy.yml`.

**Proof Artifacts:**
- CLI: `gh workflow run gcp-deploy.yml -f image_tag=latest` succeeds end-to-end against a test GCP project.
- CLI: `gh run view <run-id> --log` shows the auth step used OIDC (no key file exchange).
- File: `.github/workflows/gcp-deploy.yml` contains no references to `credentials_json`, `GOOGLE_APPLICATION_CREDENTIALS`, or `service_account_key`.
- URL: After deploy, the smoke-check URL returns 200 and is surfaced in the run summary.

### Unit 4: Scheduler Integration and Documentation

**Purpose:** Let operators drive polls/rescoring/maintenance on the GCP deployment using the existing `scheduler.yml`, and publish a setup guide that matches the quality of `docs/fly.md`.

**Functional Requirements:**
- The system shall extend `.github/workflows/scheduler.yml` so it reads an optional `DISTILLERY_GCP_URL` repo variable and, when set, calls the same set of `/api/*` webhooks against the GCP URL in addition to (not instead of) the existing Fly targets.
- The scheduler workflow shall treat GCP targeting as strictly additive — if `DISTILLERY_GCP_URL` is unset or empty, behavior is unchanged from today.
- The scheduler workflow shall emit a clear per-target status line in the job summary (`fly: ok`, `gcp: ok|failed`).
- The system shall add `docs/gcp.md` that mirrors the structure of `docs/fly.md`: prerequisites, bootstrap, secret creation, deploy, verification, scheduler wiring, Claude Code MCP client config, architecture table, and backup notes.
- The system shall update `README.md` to list GCP/Cloud Run as a third deployment target with a short usage block parallel to the Fly and Prefect sections.
- The GCP architecture table in `docs/gcp.md` shall document the single-replica constraint (`max_instances=1`) and the reason (GCS FUSE write contention / DuckDB single-writer).

**Proof Artifacts:**
- CLI: With `DISTILLERY_GCP_URL` set, `gh workflow run scheduler.yml -f job=poll` returns success and the run logs show a `POST` to the GCP `/api/poll` endpoint returning 200.
- CLI: With `DISTILLERY_GCP_URL` unset, the same invocation runs exactly the existing Fly flow (no GCP call attempted).
- File: `docs/gcp.md` exists and includes each of the sections listed in FR above.
- File: `README.md` contains a `### Google Cloud Run (\`gcp/\`)` subsection under `## Deployments`.

## Non-Goals (Out of Scope)

- **GKE / App Engine / Compute Engine** deployment variants — only Cloud Run is in scope.
- **Staging environment** on GCP — only a single prod target is in scope. Fly staging remains the PR gate.
- **Multi-region / multi-replica** operation — explicitly ruled out by the single-writer DuckDB constraint.
- **Terraform / Pulumi / Config Connector** IaC — the bootstrap script is shell-based; converting to IaC is a future concern.
- **Cloud Scheduler** as a replacement for GitHub Actions cron — not in scope (GitHub Actions is the chosen scheduler).
- **Switching storage to MotherDuck or Cloud SQL** — explicitly ruled out; DuckDB on GCS FUSE is the chosen backend.
- **Secret Manager rotation automation** — manual `gcloud secrets versions add` is acceptable.
- **Custom domain / certificate management** — the default `*.run.app` URL is sufficient for v1.
- **Modifying the upstream `ghcr.io/norrietaylor/distillery` image** — all GCP-specific behavior lives in this repo.

## Design Considerations

No UI is introduced. Operator-facing touchpoints are:
- `docs/gcp.md` — must match the structural conventions of `docs/fly.md` (same section headings, same command-block formatting, same Architecture table shape).
- `README.md` update — three-column symmetry with Fly and Prefect sections.
- `gh run` job summaries for `gcp-deploy.yml` and `scheduler.yml` — shall print the target Cloud Run URL and smoke-check result in a human-readable block.

## Repository Standards

- New files under `gcp/` mirror the directory and naming conventions of `fly/` (Dockerfile, distillery-*.yaml, service config file).
- Workflow files live under `.github/workflows/` using the existing naming pattern (`<target>-deploy.yml`, `scheduler.yml`).
- Documentation lives under `docs/` using the existing `<target>.md` pattern.
- Shell scripts use `set -euo pipefail` and accept configuration via flags with `--help` output.
- Commit messages follow the observed pattern in `git log` (conventional commit style, e.g. `feat(gcp): add Cloud Run bootstrap`).
- No long-lived service-account keys anywhere in the repo or in CI — WIF is mandatory.
- Do not hardcode project IDs or user emails in files under version control; use repo variables / workflow inputs.

## Technical Considerations

- **GCS FUSE + DuckDB:** Cloud Run volume mounts using GCS FUSE are in GA and expose filesystem semantics over GCS. DuckDB's single-file format and WAL will write through FUSE; fsync latency is higher than block storage. Mitigations: (1) pin `max_instances=1` so there is never a second writer; (2) accept the higher first-write latency; (3) document that DuckDB `checkpoint` may be slow on GCS FUSE. If empirical testing during Unit 2 shows unacceptable latency, fall back to bundling a `gsutil rsync` sidecar pattern — record the decision in `docs/gcp.md` if that path is taken.
- **FastMCP state persistence:** `FASTMCP_HOME` must point to `/data/fastmcp` (on the FUSE mount) so OAuth client registrations and tokens survive cold starts, matching the Fly pattern.
- **Image source:** The `ghcr.io/norrietaylor/distillery` image is public — Cloud Run can pull it directly, so the `gcp/Dockerfile` `FROM` works without GHCR credentials. However, Cloud Run **deploys** must reference an image the service account can read; re-tagging into Artifact Registry (as Unit 3 does) is the clean path.
- **Cold start:** GCS FUSE mount adds ~1-3s to cold start. The startup probe grace period must accommodate this.
- **Memory floor:** The Fly deployment bumped VM memory from 512MB to 1024MB after scheduled poll OOMs (see `fly/fly.toml:40-42` and upstream issue #396). Cloud Run default is 512MB — the service manifest must set memory to at least 1024MB (2 vCPU / 1 GiB is a reasonable starting point).
- **Request concurrency:** Match Fly's `hard_limit=10` via Cloud Run `containerConcurrency=10`.
- **Idempotence in bootstrap:** Use `gcloud ... create || true` guards cautiously — prefer `describe` then conditional `create`, because silencing all errors hides real failures.
- **WIF attribute condition:** Scope the provider to `attribute.repository == "norrietaylor/distill_ops"` to prevent any other GitHub repo from impersonating the deployer SA.
- **scheduler.yml change:** The existing workflow already targets one URL. The extension must be strictly additive and must not alter the Fly call path — implementation should run Fly and GCP in parallel matrix jobs rather than serially.

## Security Considerations

- **No service-account JSON keys** in GitHub secrets or in the repo. WIF is mandatory; the deploy workflow must fail if a key is present (can be enforced via a grep step on the workflow file during review).
- **WIF provider scoped to single repo** via attribute condition — prevents other repos in the GitHub org from minting tokens for this SA.
- **Runtime SA (`distillery-run`) permissions minimized** — only object-admin on the single data bucket and secret accessor for the four named secrets. No project-level roles.
- **Deployer SA (`distillery-deployer`) permissions minimized** — `run.admin` is broad; consider `roles/run.developer` if it suffices for `services replace`. Verify during implementation.
- **Secrets stored in Secret Manager**, referenced by Cloud Run via `--set-secrets`. Never in `service.yaml` plaintext, never in the image.
- **GitHub OAuth scope unchanged** — the Distillery server continues to request only the `user` scope; GCP deployment inherits this posture.
- **Webhook endpoints** continue to require the `Authorization: Bearer $DISTILLERY_WEBHOOK_SECRET` header; Cloud Run's default of "allow unauthenticated" is acceptable because the application-level token is the real gate (same model as Fly).
- **Bucket access** — uniform bucket-level access enabled; no public access; object lifecycle rule optional (future consideration).
- **Data at rest** — GCS default encryption is Google-managed keys (GMEK). CMEK is out of scope for v1; note in docs as a future hardening step.

## Success Metrics

- **Functional:** An operator following `docs/gcp.md` from an empty GCP project reaches a working `POST /mcp tools/list` response in under 30 minutes of wall time, excluding GitHub OAuth app registration.
- **Deploy latency:** `gcp-deploy.yml` end-to-end (trigger → smoke check green) completes in under 5 minutes.
- **Security posture:** Zero service-account JSON keys in any secret store; `grep -r "service_account_key" .github/` returns no results.
- **Parity:** The same scheduler-driven poll/rescore/maintenance cadence works against the GCP URL with zero application-code changes to the upstream `distillery` repo.
- **Cost:** At idle, Cloud Run min-instances=0 yields $0 compute. GCS storage for a 100MB DB + FUSE operations costs under $1/month in a typical usage profile (document this estimate with a link to the GCP pricing page in `docs/gcp.md`).

## Open Questions

- **Secret Manager vs. plain env vars:** Cloud Run supports both. This spec requires Secret Manager for the four sensitive values. Confirm during implementation that `--set-secrets` syntax in `service.yaml` works cleanly with WIF-deployed revisions (no known blocker; flagging for verification).
- **GCS FUSE WAL behavior:** To be validated empirically during Unit 2. If DuckDB checkpoints thrash GCS, adjust `checkpoint_threshold` in distillery config or switch to a periodic `gsutil rsync` of a local ephemeral copy. Decision will be recorded in `docs/gcp.md`.
- **WIF attribute condition granularity:** Bind to `attribute.repository` only, or also `attribute.ref == "refs/heads/main"`? Tighter binding prevents branch-based deploy attacks but requires main-branch-only CI. Defer decision to implementation; default to repo-only unless threat model updates.
