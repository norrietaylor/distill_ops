# Round 1 Questions — GCP Cloud Run Deployment

## Q1: Compute service
**Answer:** Cloud Run (Recommended)
- Serverless container, scale-to-zero, pay-per-request
- Closest GCP analogue to the existing Fly.io deployment

## Q2: Database storage
**Answer:** Persistent Disk (single instance) → resolved in Round 2 as GCS FUSE volume mount
- Cloud Run does not support block-level Persistent Disks; this is a Compute Engine feature
- Followed up in round 2 to resolve the contradiction

## Q3: Scheduled jobs
**Answer:** Keep GitHub Actions (Recommended)
- Reuse existing `.github/workflows/scheduler.yml`
- Extend with a new `DISTILLERY_GCP_URL` repo variable

## Q4: CI/CD flow
**Answer:** GitHub Actions → gcloud (Recommended)
- New workflow mirrors `fly-deploy.yml`
- Authenticate via Workload Identity Federation (OIDC, keyless)

---

# Round 2 Questions — Storage Clarification

## Q2.1: Durable storage shape on Cloud Run
**Answer:** Cloud Run + GCS FUSE (Recommended)
- Mount a GCS bucket as `/data` via Cloud Run volume mount (GA)
- DuckDB file and FastMCP OAuth state persist across revisions
- Must pin `max_instances=1` to avoid FUSE write contention
- `min_instances=0` preserves scale-to-zero

## Q2.2: Region
**Answer:** us-central1 (Recommended)
- Use in examples; parameterize in scripts

## Q2.3: Staging environment
**Answer:** Prod only (Recommended)
- Single GCP deployment; Fly staging remains the PR gate

## Q2.4: GitHub → GCP auth
**Answer:** Workload Identity Federation (Recommended)
- Keyless OIDC; no service-account JSON key in GitHub secrets
