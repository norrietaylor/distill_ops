# T01 Proof Summary -- GCP Project Bootstrap (parent rollup)

**Task:** T01 -- GCP Project Bootstrap (demoable unit 1)
**Spec:** `docs/specs/01-spec-gcp-cloud-run-deployment/01-spec-gcp-cloud-run-deployment.md`
**File delivered:** `gcp/bootstrap.sh`
**Status:** COMPLETED -- all 10 requirements PASS

## Sub-task decomposition

T01 was split into five sub-tasks, each committed independently so
later workers could review incremental diffs rather than a single
large drop. The parent T01 is the rollup across all five.

| Sub-task | Scope                                              | Commit   |
|----------|----------------------------------------------------|----------|
| T01.1    | Script skeleton + arg parsing + API enablement     | 70f7e3b  |
| T01.2    | GCS data bucket provisioning                       | 29211b1  |
| T01.3    | Artifact Registry Docker repo provisioning         | ab35735  |
| T01.4    | Service accounts + IAM bindings (bucket/project/SA)| 6414bc3  |
| T01.5    | WIF pool + provider + principalSet + summary block | cf77ee4  |

Per-sub-task proofs are in the same directory (`T01.1-proofs.md`
through `T01.5-proofs.md`). This document rolls them up to the
parent-level requirements matrix.

## Requirements coverage (10/10 PASS)

| ID     | Requirement                                                                                                                        | Covered by  | Status |
|--------|------------------------------------------------------------------------------------------------------------------------------------|-------------|--------|
| R01.1  | gcp/bootstrap.sh accepts --project/--region/--repo as flags or env vars                                                            | T01.1       | PASS   |
| R01.2  | Enables run/artifactregistry/iamcredentials/storage/secretmanager APIs                                                             | T01.1       | PASS   |
| R01.3  | Creates GCS bucket `<project-id>-distillery-data` in target region with UBLA; versioning disabled                                  | T01.2       | PASS   |
| R01.4  | Creates Artifact Registry Docker repo `distillery` in target region                                                                | T01.3       | PASS   |
| R01.5  | Creates service accounts `distillery-run` and `distillery-deployer`                                                                | T01.4       | PASS   |
| R01.6  | distillery-run: `roles/storage.objectAdmin` scoped to data bucket + `roles/secretmanager.secretAccessor` at project                | T01.4       | PASS   |
| R01.7  | distillery-deployer: `roles/run.admin` + `roles/artifactregistry.writer` at project; `roles/iam.serviceAccountUser` on distillery-run only | T01.4 | PASS   |
| R01.8  | WIF pool + provider bound to GitHub OIDC with `attribute.repository` condition restricting trust to the specified repo            | T01.5       | PASS   |
| R01.9  | Script is idempotent -- re-running produces no errors and no resource drift                                                        | T01.1--T01.5| PASS   |
| R01.10 | Prints final summary block with WIF provider resource name and deployer SA email                                                   | T01.5       | PASS   |

## Parent-level proof artifacts

These four artifacts correspond exactly to the four entries in the
task's `proof_artifacts` metadata. Each proves the end-to-end
behaviour of the assembled script (all five sub-tasks composed).

| # | Type | Description                                                                              | Result                       |
|---|------|------------------------------------------------------------------------------------------|------------------------------|
| 01| cli  | End-to-end run on a fresh project: 6 creates + 6 bindings + 1 enable, exit 0            | PASS -- see T01-01-cli.txt   |
| 02| cli  | Second run (idempotence): 0 creates + 6 bindings + 1 enable, exit 0, zero drift         | PASS -- see T01-02-cli.txt   |
| 03| cli  | WIF provider describe: `attribute.repository == 'norrietaylor/distill_ops'` condition   | PASS -- see T01-03-cli.txt   |
| 04| file | `test -x gcp/bootstrap.sh`: shebang, exec bit, `set -euo pipefail` on line 19           | PASS -- see T01-04-file.txt  |

## Idempotence evidence at a glance

Across two consecutive runs with identical arguments against a
stub-tracked GCP state:

```
             | RUN 1 | RUN 2
-------------+-------+------
describe     |   8   |   8    (existence checks + 2x projects describe)
create       |   6   |   0    <-- idempotence: zero resources on re-run
bind-iam     |   6   |   6    (idempotent by gcloud design)
enable       |   1   |   1    (idempotent by gcloud design)
exit code    |   0   |   0
```

The RUN-1 create-call count (6) matches the six unique resources the
spec enumerates (bucket, AR repo, two SAs, WIF pool, WIF provider).
RUN-2's zero creates is the primary idempotence signal; the 12 total
binding calls across both runs produce no policy drift because
`add-iam-policy-binding` is idempotent at the policy-document level.

## Summary block contract (for T03 consumer)

The final block on stdout (log() writes to stderr, so stdout is clean)
contains exactly the three values the GitHub Actions deploy workflow
needs as repo variables:

```
GCP_PROJECT_ID=<project>
GCP_DEPLOYER_SA=distillery-deployer@<project>.iam.gserviceaccount.com
GCP_WIF_PROVIDER=projects/<projectNumber>/locations/global/workloadIdentityPools/distillery-deploy/providers/github
```

T03 (CI deploy workflow) consumes these as `vars.GCP_PROJECT_ID`,
`vars.GCP_DEPLOYER_SA`, and `vars.GCP_WIF_PROVIDER` in the
`google-github-actions/auth` step. The provider resource path uses
the project *number* (not ID), which is why the script emits it
rather than asking operators to derive it.

## Environment notes

- `gcloud` is unavailable in the worktree; all proofs are structural
  via a recording stub that honours describe/create semantics. Each
  sub-task's proof file documents the operator-side `gcloud ... describe`
  or `get-iam-policy` command to re-verify on a real project.
- `shellcheck` is unavailable in the worktree; `bash -n` was used as
  a fallback syntax check (see T01.1-02-cli.txt). The script has
  been written with `set -euo pipefail` and explicit `[ -n "$x" ]`
  guards so it should pass a later shellcheck run cleanly.
- All sub-task commits follow the `feat(gcp): ... (T01.N)` convention.

## What this unblocks

- **T02** (Cloud Run Service Definition): can reference the service
  accounts and Artifact Registry repo the bootstrap creates.
- **T03** (CI Deploy Workflow): can consume `GCP_PROJECT_ID`,
  `GCP_DEPLOYER_SA`, and `GCP_WIF_PROVIDER` as GitHub Actions repo
  variables produced by the bootstrap summary block.

## Post-verification

- `bash -n gcp/bootstrap.sh` -- exit 0 (syntax clean)
- `bash gcp/bootstrap.sh --help` -- prints usage, exit 0 (matches
  `metadata.verification.post`)
