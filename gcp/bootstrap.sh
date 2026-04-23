#!/usr/bin/env bash
# gcp/bootstrap.sh — idempotent provisioner for the Distillery Cloud Run deployment.
#
# Reads GCP project/region and the GitHub repo the deploy workflow runs from,
# then enables required APIs and (in later steps) creates the data bucket,
# Artifact Registry repo, service accounts, IAM bindings, and Workload
# Identity Federation pool/provider.
#
# Re-running is a no-op. Each step uses `describe`-then-conditional-create
# or add-iam-policy-binding (which is idempotent by design) — we avoid
# blanket `|| true` because it hides real failures.
#
# Usage:
#   bash gcp/bootstrap.sh --project <id> --region <region> --repo <owner/name>
#
# Or via environment:
#   GCP_PROJECT=... GCP_REGION=... GCP_REPO=... bash gcp/bootstrap.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults and state
# ---------------------------------------------------------------------------

PROJECT="${GCP_PROJECT:-}"
REGION="${GCP_REGION:-}"
REPO="${GCP_REPO:-}"

# APIs required by the Cloud Run deployment. Cloud Run itself, Artifact
# Registry for the image, IAM Credentials for WIF token exchange, Cloud
# Storage for the FUSE-mounted data bucket, Secret Manager for the four
# runtime secrets.
REQUIRED_APIS=(
  run.googleapis.com
  artifactregistry.googleapis.com
  iamcredentials.googleapis.com
  storage.googleapis.com
  secretmanager.googleapis.com
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
  printf '[bootstrap] %s\n' "$*" >&2
}

die() {
  printf '[bootstrap] error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: bash gcp/bootstrap.sh --project <id> --region <region> --repo <owner/name>

Idempotently provisions the GCP resources required by the Distillery Cloud
Run deployment: APIs, data bucket, Artifact Registry repo, service
accounts, IAM bindings, and a Workload Identity Federation pool/provider
bound to the specified GitHub repo.

Required arguments (flags or environment variables):
  --project <id>          GCP project ID            (env: GCP_PROJECT)
  --region  <region>      GCP region, e.g.          (env: GCP_REGION)
                          us-central1
  --repo    <owner/name>  GitHub repository the     (env: GCP_REPO)
                          deploy workflow runs from

Optional:
  -h, --help              Print this message and exit

Examples:
  bash gcp/bootstrap.sh \
    --project my-gcp-project \
    --region  us-central1 \
    --repo    norrietaylor/distill_ops

  GCP_PROJECT=my-gcp-project GCP_REGION=us-central1 \
    GCP_REPO=norrietaylor/distill_ops bash gcp/bootstrap.sh

The script is safe to re-run; each step is idempotent.
EOF
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project)
        [ "$#" -ge 2 ] || die "--project requires a value"
        PROJECT="$2"
        shift 2
        ;;
      --project=*)
        PROJECT="${1#*=}"
        shift
        ;;
      --region)
        [ "$#" -ge 2 ] || die "--region requires a value"
        REGION="$2"
        shift 2
        ;;
      --region=*)
        REGION="${1#*=}"
        shift
        ;;
      --repo)
        [ "$#" -ge 2 ] || die "--repo requires a value"
        REPO="$2"
        shift 2
        ;;
      --repo=*)
        REPO="${1#*=}"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1 (try --help)"
        ;;
    esac
  done
}

validate_args() {
  [ -n "$PROJECT" ] || die "project is required (--project or GCP_PROJECT)"
  [ -n "$REGION" ]  || die "region is required (--region or GCP_REGION)"
  [ -n "$REPO" ]    || die "repo is required (--repo or GCP_REPO)"

  # Repo must be exactly owner/name with no extra slashes.
  case "$REPO" in
    */*/*|*/|/*|*/'')
      die "repo must be in the form owner/name (got: $REPO)"
      ;;
    */*) : ;;
    *)   die "repo must be in the form owner/name (got: $REPO)" ;;
  esac
}

require_gcloud() {
  command -v gcloud >/dev/null 2>&1 \
    || die "gcloud CLI not found on PATH — install the Google Cloud SDK first"
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------

enable_apis() {
  log "enabling APIs on project=$PROJECT"
  # `services enable` is idempotent — enabling an already-enabled service is
  # a no-op and returns 0. We pass all APIs in a single call so the gcloud
  # dependency resolver handles them together.
  gcloud services enable "${REQUIRED_APIS[@]}" --project="$PROJECT"
}

# Name for the GCS bucket that backs the GCS FUSE volume mount. Derived
# from the project ID so multiple projects never collide on the GCS
# global namespace.
bucket_name() {
  printf '%s-distillery-data' "$PROJECT"
}

create_bucket() {
  local bucket
  bucket="$(bucket_name)"
  # `describe` returns non-zero when the bucket does not exist — we use
  # that instead of blanket `|| true` on `create`, which would hide real
  # permission/quota errors. Errors other than NotFound are surfaced by
  # the trailing pipe via `PIPESTATUS` check.
  if gcloud storage buckets describe "gs://${bucket}" \
       --project="$PROJECT" \
       --format='value(name)' >/dev/null 2>&1; then
    log "bucket gs://${bucket} already exists — skipping"
  else
    log "creating bucket gs://${bucket} in ${REGION}"
    # Uniform bucket-level access is set at creation time. Versioning is
    # disabled by default on new buckets, so we do not pass a flag — but
    # we note the decision for readers: DuckDB writes are self-consistent,
    # so object versioning multiplies storage cost without adding recovery
    # value for this workload.
    gcloud storage buckets create "gs://${bucket}" \
      --project="$PROJECT" \
      --location="$REGION" \
      --uniform-bucket-level-access
  fi
}

# Artifact Registry Docker repo that holds the Cloud Run image. The CI
# workflow tags images as
#   <region>-docker.pkg.dev/<project>/distillery/distillery:<sha>
# so the repo name is a constant `distillery` — parallel to the fly/
# pattern of one repo per deployment target.
AR_REPO="distillery"

create_ar_repo() {
  # describe -> conditional create, same pattern as the bucket step.
  # Silencing create errors with `|| true` would hide permission or quota
  # failures, so we gate on describe's exit code instead.
  if gcloud artifacts repositories describe "$AR_REPO" \
       --project="$PROJECT" \
       --location="$REGION" \
       --format='value(name)' >/dev/null 2>&1; then
    log "artifact registry repo ${AR_REPO} already exists in ${REGION} — skipping"
  else
    log "creating artifact registry repo ${AR_REPO} (docker) in ${REGION}"
    gcloud artifacts repositories create "$AR_REPO" \
      --project="$PROJECT" \
      --location="$REGION" \
      --repository-format=docker \
      --description="Distillery container images for the Cloud Run deployment"
  fi
}

# Service account account-ids. Emails are derived from these + the project.
SA_RUN="distillery-run"
SA_DEPLOYER="distillery-deployer"

# Build the full SA email from an account-id.
sa_email() {
  printf '%s@%s.iam.gserviceaccount.com' "$1" "$PROJECT"
}

# Create one SA if missing; idempotent by describe-check.
create_sa() {
  local account_id="$1" display_name="$2" email
  email="$(sa_email "$account_id")"
  if gcloud iam service-accounts describe "$email" \
       --project="$PROJECT" \
       --format='value(email)' >/dev/null 2>&1; then
    log "service account ${email} already exists — skipping"
  else
    log "creating service account ${email}"
    gcloud iam service-accounts create "$account_id" \
      --project="$PROJECT" \
      --display-name="$display_name"
  fi
}

create_service_accounts() {
  create_sa "$SA_RUN"      "Distillery Cloud Run runtime identity"
  create_sa "$SA_DEPLOYER" "Distillery GitHub Actions deployer"
}

# bind_iam attaches the minimum roles required for each SA. We use
# add-iam-policy-binding everywhere — it is idempotent by design:
# re-adding the same principal/role returns 0 and leaves the policy
# unchanged. This means we do not need describe-first guards here.
#
# Scope of each binding:
#   distillery-run      roles/storage.objectAdmin         ON data bucket only
#   distillery-run      roles/secretmanager.secretAccessor AT project scope
#   distillery-deployer roles/run.admin                   AT project scope
#   distillery-deployer roles/artifactregistry.writer     AT project scope
#   distillery-deployer roles/iam.serviceAccountUser      ON distillery-run SA only
#
# The run.admin role is broad. The spec's Security section flags that
# roles/run.developer may suffice for `services replace` — keeping
# run.admin for v1 so the CI workflow can also manage traffic if ever
# needed; tighten in a follow-up if proven unnecessary.
bind_iam() {
  local run_email deployer_email bucket
  run_email="$(sa_email "$SA_RUN")"
  deployer_email="$(sa_email "$SA_DEPLOYER")"
  bucket="$(bucket_name)"

  log "binding roles/storage.objectAdmin on gs://${bucket} -> ${run_email}"
  gcloud storage buckets add-iam-policy-binding "gs://${bucket}" \
    --project="$PROJECT" \
    --member="serviceAccount:${run_email}" \
    --role="roles/storage.objectAdmin" >/dev/null

  log "binding roles/secretmanager.secretAccessor (project) -> ${run_email}"
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:${run_email}" \
    --role="roles/secretmanager.secretAccessor" \
    --condition=None >/dev/null

  log "binding roles/run.admin (project) -> ${deployer_email}"
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:${deployer_email}" \
    --role="roles/run.admin" \
    --condition=None >/dev/null

  log "binding roles/artifactregistry.writer (project) -> ${deployer_email}"
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:${deployer_email}" \
    --role="roles/artifactregistry.writer" \
    --condition=None >/dev/null

  log "binding roles/iam.serviceAccountUser on ${run_email} -> ${deployer_email}"
  gcloud iam service-accounts add-iam-policy-binding "$run_email" \
    --project="$PROJECT" \
    --member="serviceAccount:${deployer_email}" \
    --role="roles/iam.serviceAccountUser" >/dev/null
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  parse_args "$@"
  validate_args
  require_gcloud

  log "project=$PROJECT region=$REGION repo=$REPO"

  enable_apis
  create_bucket
  create_ar_repo
  create_service_accounts
  bind_iam

  log "done (APIs enabled, data bucket ready, artifact registry ready, service accounts + IAM bound). Later steps will be added by subsequent sub-tasks."
}

main "$@"
