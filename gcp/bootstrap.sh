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

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  parse_args "$@"
  validate_args
  require_gcloud

  log "project=$PROJECT region=$REGION repo=$REPO"

  enable_apis

  log "done (APIs enabled). Later steps will be added by subsequent sub-tasks."
}

main "$@"
