# T03 Proof Summary: CI Deploy Workflow

## Task
T03 — Add `.github/workflows/gcp-deploy.yml` with Workload Identity Federation authentication,
image build/push to Artifact Registry, Cloud Run deployment via `gcloud run services replace`,
and a post-deploy smoke check.

## Proof Artifacts

| Artifact | Type | Status | Notes |
|----------|------|--------|-------|
| T03-01-cli.txt | cli (live run) | SKIPPED | Requires live GCP project — no environment available |
| T03-02-cli.txt | cli (run log) | SKIPPED | Depends on T03-01 |
| T03-03-file.txt | file (grep) | PASS | No forbidden credential references in workflow file |
| T03-04-url.txt | url (smoke check) | SKIPPED | Requires deployed Cloud Run service |

## Requirements Coverage

| Req | Description | Status |
|-----|-------------|--------|
| R03.1 | workflow_dispatch with image_tag and region inputs | PASS (structural) |
| R03.2 | WIF auth via GCP_WIF_PROVIDER / GCP_DEPLOYER_SA / GCP_PROJECT_ID | PASS (structural) |
| R03.3 | No credential JSON references; loud fail path documented | PASS (T03-03-file.txt) |
| R03.4 | Build and push to Artifact Registry with git-sha and latest tags | PASS (structural) |
| R03.5 | Deploy via gcloud run services replace with substituted image | PASS (structural) |
| R03.6 | Post-deploy smoke check with 60-second timeout | PASS (structural) |
| R03.7 | concurrency: gcp-deploy | PASS (structural) |
| R03.8 | Does not touch fly-deploy.yml or shared fly state | PASS (structural) |

## Key Design Decisions

- `concurrency.cancel-in-progress: false` — a deploy in progress should complete rather
  than be cancelled mid-revision-push; the queue model is preferred over preemption.
- The `id-token: write` permission is required for the OIDC token exchange with GCP WIF.
- `service.yaml` image substitution uses `sed` with the resolved registry path to avoid
  modifying the source `gcp/service.yaml` on disk (writes to `/tmp/service-deploy.yaml`).
- The smoke check polls in a loop rather than using a single curl with `--retry` so that
  the 60-second deadline is measured wall-clock and partial successes are visible in logs.
- The WIF guard is implemented as a comment + structural constraint (no credentials fields
  present in the auth action) rather than a runtime `secrets.*` check, because GitHub
  Actions evaluates `secrets.*` references as empty strings for undefined secrets — a
  runtime check provides false confidence without being genuinely enforceable.

## Commit
See `git log --oneline -1` for the commit SHA.
