# Source: docs/specs/01-spec-gcp-cloud-run-deployment/01-spec-gcp-cloud-run-deployment.md
# Pattern: CLI/Process + API
# Recommended test type: Integration

Feature: CI Deploy Workflow

  Scenario: workflow_dispatch deploys a new Cloud Run revision end-to-end
    Given the repo variables GCP_WIF_PROVIDER, GCP_DEPLOYER_SA, and GCP_PROJECT_ID are set to the bootstrap outputs
    And no service-account JSON key exists in GitHub secrets
    When a maintainer runs "gh workflow run gcp-deploy.yml -f image_tag=latest -f region=us-central1 --ref main"
    And waits for the resulting run to complete
    Then "gh run view <run-id> --json conclusion --jq .conclusion" prints "success"
    And "gcloud run revisions list --service=distillery --region=us-central1 --limit=1 --format=value(metadata.name)" names a revision created within the last 10 minutes

  Scenario: Auth step uses OIDC, not a JSON key
    Given the gcp-deploy workflow has been triggered
    When the run completes
    And a maintainer runs "gh run view <run-id> --log"
    Then the log contains the phrase "Using OIDC" (or equivalent output from google-github-actions/auth indicating workload identity federation)
    And the log does not contain "credentials_json"
    And the log does not contain the path "/tmp/*.json" being passed as GOOGLE_APPLICATION_CREDENTIALS

  Scenario: Workflow file contains no references to long-lived key secrets
    Given the repository is checked out
    When an operator runs "grep -nE 'credentials_json|GOOGLE_APPLICATION_CREDENTIALS|service_account_key' .github/workflows/gcp-deploy.yml"
    Then the command exits with code 1
    And stdout is empty

  Scenario: Image is pushed with both the git SHA and latest tags
    Given a successful gcp-deploy run triggered from commit $SHA
    When an operator runs "gcloud artifacts docker images list us-central1-docker.pkg.dev/test-proj/distillery/distillery --include-tags --format=json"
    Then the output includes an image tagged "$SHA"
    And the output includes an image tagged "latest"

  Scenario: Post-deploy smoke check gates job success
    Given a deployed Cloud Run service at URL $SERVICE_URL
    When the workflow's smoke-check step runs "curl -sf $SERVICE_URL/.well-known/oauth-authorization-server"
    Then the step exits with code 0 within 60 seconds
    And the run job summary includes the line "smoke check: ok" (or equivalent human-readable status with the URL)

  Scenario: Smoke check failure fails the workflow
    Given a broken deployment where /.well-known/oauth-authorization-server returns 500
    When the gcp-deploy workflow runs
    Then the smoke-check step exits non-zero within 60 seconds
    And "gh run view <run-id> --json conclusion --jq .conclusion" prints "failure"

  Scenario: Concurrent deploy runs do not overlap
    Given one gcp-deploy run is already in progress
    When a maintainer triggers a second "gh workflow run gcp-deploy.yml -f image_tag=latest"
    Then the second run is queued by the "gcp-deploy" concurrency group (cancel-in-progress is false)
    And only one run at a time reaches the "gcloud run services replace" step

  Scenario: Workflow does not mutate Fly deploy state
    Given a clean repo state with fly-deploy.yml unchanged
    When the gcp-deploy workflow runs to completion
    Then "git diff main -- .github/workflows/fly-deploy.yml fly/" produces no output
    And no step in the run invoked "flyctl deploy" or touched the fly/ directory
