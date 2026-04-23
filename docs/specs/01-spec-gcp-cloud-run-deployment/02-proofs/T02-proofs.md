# T02 Proof Summary -- Cloud Run Service Definition (parent rollup)

**Task:** T02 -- Cloud Run Service Definition (demoable unit 2)
**Spec:** `docs/specs/01-spec-gcp-cloud-run-deployment/01-spec-gcp-cloud-run-deployment.md`
**Files delivered:** `gcp/Dockerfile`, `gcp/distillery-gcp.yaml`, `gcp/service.yaml`
**Status:** COMPLETED -- all 8 requirements PASS

## Sub-task history

T02 was dispatched in parallel as three sub-tasks, but worker-2 delivered
all three files in a single commit. The lead then reconciled the sub-task
statuses and added a follow-up fix for a missing `max-instances` annotation.
Full reconciliation log: `T02.X-lead-reconciliation.md`.

| Sub-task | Scope                          | Commit                |
|----------|--------------------------------|-----------------------|
| T02.1    | `gcp/distillery-gcp.yaml`      | d4c8f23               |
| T02.2    | `gcp/Dockerfile`               | d4c8f23               |
| T02.3    | `gcp/service.yaml`             | d4c8f23 + 51102cb     |

The per-sub-task proof (`T02.1-proofs.md` + artifacts) covers the three
files together and is not re-done here. This document rolls the work up to
the parent-level requirement matrix and adds an executable docker-build
proof that the prior worker had deferred.

## Requirements coverage (8/8 PASS)

| ID     | Requirement                                                                                                                                                      | Covered by                         | Status |
|--------|------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------|--------|
| R02.1  | Dockerfile extends `ghcr.io/norrietaylor/distillery:${IMAGE_TAG}`, copies `distillery-gcp.yaml`, sets `DISTILLERY_CONFIG` + `FASTMCP_HOME`, fixes /data ownership | T02-01-docker-build.txt            | PASS   |
| R02.2  | `distillery-gcp.yaml`: DuckDB at `/data/distillery.db`, Jina embeddings, GitHub OAuth env refs, webhooks enabled                                                 | T02-03-distillery-gcp-config.txt   | PASS   |
| R02.3  | `service.yaml`: max-instances=1, min-instances=0, containerPort=8000, GCS FUSE volume, `distillery-run` SA, 5 Secret Manager refs, startup probe on OAuth metadata | T02-02-service-yaml-requirements.txt | PASS   |
| R02.4  | Cloud Run second-generation execution environment (required for GCS FUSE)                                                                                        | T02-02-service-yaml-requirements.txt | PASS   |
| R02.5  | Request timeout >= 300s                                                                                                                                          | T02-02-service-yaml-requirements.txt | PASS   |
| R02.6  | Memory >= 1024 MB                                                                                                                                                | T02-02-service-yaml-requirements.txt | PASS   |
| R02.7  | `containerConcurrency == 10` (match Fly hard_limit)                                                                                                              | T02-02-service-yaml-requirements.txt | PASS   |
| R02.8  | Deployable via gcp/ files + one `gcloud run services replace gcp/service.yaml --region=...`                                                                      | T02-04-deployability.txt           | PASS   |

## Parent-level proof artifacts

| # | Type | Description                                                                                        | Result                                    |
|---|------|----------------------------------------------------------------------------------------------------|-------------------------------------------|
|01 | cli  | `docker build --platform=linux/amd64 -f gcp/Dockerfile --build-arg IMAGE_TAG=latest -t ... .`      | PASS -- see T02-01-docker-build.txt       |
|02 | file | `service.yaml` parsed + every R02.3..R02.7 field asserted against its required value               | PASS -- see T02-02-service-yaml-requirements.txt |
|03 | file | `distillery-gcp.yaml` parsed + every R02.2 field asserted against its required value               | PASS -- see T02-03-distillery-gcp-config.txt     |
|04 | file | Cross-reference chain: every external ref in `service.yaml` resolves to a gcp/ file, a bootstrap asset, or an operator-created Secret Manager entry | PASS -- see T02-04-deployability.txt |

## Task metadata vs delivered proofs

Six proof_artifacts are declared in the task metadata. Four are reproducible
from the worktree; two require a live GCP project or a deployed service URL
and are deferred to later units.

| # | metadata.proof_artifacts entry                                                                       | Delivered here        | Rationale                                                                 |
|---|------------------------------------------------------------------------------------------------------|-----------------------|---------------------------------------------------------------------------|
| 1 | `docker build -f gcp/Dockerfile --build-arg IMAGE_TAG=latest -t local-test .`                        | Yes (T02-01)          | Executed with `--platform=linux/amd64` (aarch64 host + amd64 base image). |
| 2 | `gcloud run services replace gcp/service.yaml --region=us-central1` -> revision Ready=True           | Deferred (manual)     | Needs a live GCP project. Exercised by T03 CI workflow proof + T04 smoke. |
| 3 | `curl https://<service-url>/.well-known/oauth-authorization-server` -> HTTP 200 + OAuth JSON         | Deferred (manual)     | Needs a deployed service URL; same as above.                              |
| 4 | `curl -X POST https://<service-url>/mcp -d '{"method":"tools/list"}'` -> tools array after OAuth     | Deferred (manual)     | Needs a deployed service URL + OAuth'd client; belongs to T04 smoke test. |
| 5 | `grep -E 'executionEnvironment: gen2' ... && grep 'csi: gcsfuse.run.googleapis.com' ...`             | Yes (T02-02, equivalent) | Key is `driver: gcsfuse...` under `csi:` -- equivalent grep asserted.  |
| 6 | After revision redeploy, `ls /data/distillery.db` -> file preserved across revisions                 | Deferred (manual)     | Needs a live service + two revisions; belongs to T04 smoke/persistence.   |

The deferred items are explicitly marked `capture_method: manual` in the
task metadata and depend on T03 (CI deploy workflow) landing the service
in a real project. They are **not** structural properties of the gcp/
files, so they don't gate T02 completion; they are end-to-end behaviour
checks that the T04 scheduler-integration / smoke proofs will cover.

## Environment notes

- **Docker build host:** aarch64. The base image
  `ghcr.io/norrietaylor/distillery:latest` publishes only `linux/amd64`
  (single-platform), so the build was run with `--platform=linux/amd64`
  after registering amd64 binfmt handlers via `tonistiigi/binfmt --install amd64`.
  Cloud Run itself is amd64, so this matches the target runtime.
- **gcloud:** unavailable in the worktree; live Cloud Run proofs are
  deferred to T03 (CI deploy workflow) and T04 (smoke tests).
- **YAML validation:** both config files parse cleanly via `yaml.safe_load`
  (matches `metadata.verification.pre`).

## What this unblocks

- **T03** (CI Deploy Workflow): consumes `gcp/Dockerfile` for the
  `docker build` step and `gcp/service.yaml` for
  `gcloud run services replace` after image substitution.
- **T04** (Scheduler Integration + Documentation): relies on the deployed
  service URL / OAuth metadata endpoint exposed by this manifest.

## Post-verification

- `docker build --platform=linux/amd64 -f gcp/Dockerfile ...` -- exit 0.
- `python3 -c "import yaml; yaml.safe_load(open('gcp/distillery-gcp.yaml')); yaml.safe_load(open('gcp/service.yaml'))"` -- exit 0 (matches `metadata.verification.pre`).
