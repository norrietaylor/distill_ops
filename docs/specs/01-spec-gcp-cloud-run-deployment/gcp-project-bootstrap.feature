# Source: docs/specs/01-spec-gcp-cloud-run-deployment/01-spec-gcp-cloud-run-deployment.md
# Pattern: CLI/Process
# Recommended test type: Integration

Feature: GCP Project Bootstrap

  Scenario: Bootstrap script provisions all resources on a fresh project
    Given a fresh GCP project "test-proj" with billing enabled
    And the executing user has Project Owner IAM on that project
    When an operator runs "bash gcp/bootstrap.sh --project test-proj --region us-central1 --repo norrietaylor/distill_ops"
    Then the command exits with code 0
    And "gcloud services list --project test-proj --enabled" lists run.googleapis.com, artifactregistry.googleapis.com, iamcredentials.googleapis.com, storage.googleapis.com, and secretmanager.googleapis.com
    And "gcloud storage buckets describe gs://test-proj-distillery-data --format=value(iamConfiguration.uniformBucketLevelAccess.enabled)" prints "True"
    And "gcloud storage buckets describe gs://test-proj-distillery-data --format=value(versioning.enabled)" prints either "None" or "False"
    And "gcloud artifacts repositories describe distillery --location=us-central1 --format=value(format)" prints "DOCKER"
    And "gcloud iam service-accounts list --project test-proj" includes both distillery-run and distillery-deployer email addresses

  Scenario: Re-running the bootstrap script is idempotent
    Given the bootstrap script has already been run successfully against project "test-proj"
    When an operator runs "bash gcp/bootstrap.sh --project test-proj --region us-central1 --repo norrietaylor/distill_ops" a second time
    Then the command exits with code 0
    And no "AlreadyExists" error is reported on stderr as a fatal failure
    And "gcloud iam service-accounts list --project test-proj --filter=email:distillery-run*" still returns exactly one service account
    And "gcloud storage buckets list --project test-proj --filter=name:test-proj-distillery-data" still returns exactly one bucket

  Scenario: Runtime service account receives bucket-scoped storage.objectAdmin
    Given the bootstrap script has completed against project "test-proj"
    When an operator runs "gcloud storage buckets get-iam-policy gs://test-proj-distillery-data --format=json"
    Then the output binds role "roles/storage.objectAdmin" to member "serviceAccount:distillery-run@test-proj.iam.gserviceaccount.com"
    And "gcloud projects get-iam-policy test-proj --flatten=bindings --filter=bindings.members:distillery-run*" does not list roles/storage.objectAdmin at project scope

  Scenario: Runtime service account can read Secret Manager secrets at project scope
    Given the bootstrap script has completed against project "test-proj"
    When an operator runs "gcloud projects get-iam-policy test-proj --flatten=bindings --filter=bindings.members:distillery-run@test-proj.iam.gserviceaccount.com --format=value(bindings.role)"
    Then the output includes "roles/secretmanager.secretAccessor"

  Scenario: Deployer service account receives minimum CI deploy roles
    Given the bootstrap script has completed against project "test-proj"
    When an operator inspects IAM bindings for "distillery-deployer@test-proj.iam.gserviceaccount.com"
    Then the deployer is granted "roles/run.admin" or "roles/run.developer" at project scope
    And the deployer is granted "roles/artifactregistry.writer" at project scope
    And the deployer is granted "roles/iam.serviceAccountUser" scoped to the distillery-run service account

  Scenario: Workload Identity Federation is scoped to the specified GitHub repo
    Given the bootstrap script has completed against project "test-proj" with --repo norrietaylor/distill_ops
    When an operator runs "gcloud iam workload-identity-pools providers describe github --location=global --workload-identity-pool=distillery-deploy --project test-proj --format=value(attributeCondition)"
    Then the printed attribute condition restricts "attribute.repository" to "norrietaylor/distill_ops"
    And "gcloud iam workload-identity-pools providers describe github --location=global --workload-identity-pool=distillery-deploy --project test-proj --format=value(oidc.issuerUri)" prints "https://token.actions.githubusercontent.com"

  Scenario: Final summary block emits the values CI needs
    Given a fresh GCP project "test-proj"
    When an operator runs "bash gcp/bootstrap.sh --project test-proj --region us-central1 --repo norrietaylor/distill_ops"
    Then stdout contains a line matching "projects/.+/locations/global/workloadIdentityPools/distillery-deploy/providers/github"
    And stdout contains the string "distillery-deployer@test-proj.iam.gserviceaccount.com"

  Scenario: Bootstrap script is executable
    Given the repository has been cloned
    When an operator runs "test -x gcp/bootstrap.sh"
    Then the command exits with code 0
