# Source: docs/specs/01-spec-gcp-cloud-run-deployment/01-spec-gcp-cloud-run-deployment.md
# Pattern: CLI/Process + API + State
# Recommended test type: Integration

Feature: Cloud Run Service Definition

  Scenario: Dockerfile builds successfully from the public base image
    Given the repository is checked out at the feature branch
    And Docker daemon is running locally
    When an operator runs "docker build -f gcp/Dockerfile --build-arg IMAGE_TAG=latest -t local-test ."
    Then the command exits with code 0
    And "docker image inspect local-test --format {{.Config.Env}}" lists "DISTILLERY_CONFIG=/app/distillery-gcp.yaml"
    And the same inspect output lists "FASTMCP_HOME=/data/fastmcp"

  Scenario: Container fixes /data ownership before dropping privileges
    Given the image "local-test" built from gcp/Dockerfile
    And a host directory mounted at /data owned by uid 0
    When an operator runs the container with that mount and inspects the effective user at runtime
    Then "/data" is owned by the appuser uid after startup
    And the running application process is not executing as root

  Scenario: Cloud Run service manifest deploys a Ready revision
    Given the bootstrap script has completed against project "test-proj"
    And all required Secret Manager secrets (JINA_API_KEY, GITHUB_CLIENT_ID, GITHUB_CLIENT_SECRET, DISTILLERY_WEBHOOK_SECRET, DISTILLERY_BASE_URL) exist in project "test-proj"
    And an image tagged "us-central1-docker.pkg.dev/test-proj/distillery/distillery:latest" has been pushed to Artifact Registry
    When an operator runs "gcloud run services replace gcp/service.yaml --region=us-central1 --project=test-proj"
    Then the command exits with code 0
    And "gcloud run services describe distillery --region=us-central1 --project=test-proj --format=value(status.conditions[0].type,status.conditions[0].status)" prints "Ready\tTrue" within 5 minutes

  Scenario: Deployed service exposes OAuth discovery metadata
    Given a Ready Cloud Run revision of the distillery service at URL $SERVICE_URL
    When an operator runs "curl -sS -o /tmp/oauth.json -w %{http_code} $SERVICE_URL/.well-known/oauth-authorization-server"
    Then stdout prints "200"
    And "jq -r .issuer /tmp/oauth.json" prints a value equal to $SERVICE_URL
    And "jq -e .authorization_endpoint /tmp/oauth.json" exits with code 0

  Scenario: MCP tools/list endpoint responds after OAuth
    Given a Ready Cloud Run revision of the distillery service at URL $SERVICE_URL
    And an OAuth access token $TOKEN issued by completing the GitHub OAuth flow against the service
    When an operator runs "curl -sS -X POST $SERVICE_URL/mcp -H 'Content-Type: application/json' -H 'Authorization: Bearer '$TOKEN -d '{\"jsonrpc\":\"2.0\",\"method\":\"tools/list\",\"id\":1}'"
    Then the HTTP response status is 200
    And the response body is valid JSON containing a "result.tools" array
    And the array contains at least one tool definition

  Scenario: Service manifest declares gen2 execution environment and GCS FUSE volume
    Given the repository checked out at the feature branch
    When an operator runs "grep -E 'executionEnvironment: gen2' gcp/service.yaml"
    Then the command exits with code 0
    And "grep -E 'csi: gcsfuse.run.googleapis.com' gcp/service.yaml" exits with code 0
    And "grep -E 'mountPath: /data' gcp/service.yaml" exits with code 0

  Scenario: Service manifest requests at least 1024MB memory and containerConcurrency=10
    Given the repository checked out at the feature branch
    When an operator parses gcp/service.yaml for the container resource requests
    Then the memory limit is at least "1024Mi"
    And "containerConcurrency" equals 10

  Scenario: Request timeout accommodates embedding-heavy polls
    Given a deployed Cloud Run revision
    When an operator runs "gcloud run services describe distillery --region=us-central1 --format=value(spec.template.spec.timeoutSeconds)"
    Then the printed value is an integer greater than or equal to 300

  Scenario: DuckDB state persists across a forced revision redeploy
    Given a Ready Cloud Run revision with a non-empty /data/distillery.db written by a prior /api/poll call
    And the recorded mtime and size of /data/distillery.db are captured as baseline
    When an operator triggers "gcloud run services update distillery --region=us-central1 --update-env-vars=REDEPLOY_MARKER=$(date +%s)"
    And the new revision reports Ready=True
    Then "/data/distillery.db" is still present when inspected via a one-off Cloud Run job mounting the same bucket
    And the file size is greater than or equal to the baseline size
    And the file's DuckDB header is intact (the file opens successfully via `duckdb /data/distillery.db "SELECT 1"`)

  Scenario: Startup probe succeeds against OAuth discovery path
    Given a newly deployed Cloud Run revision
    When Cloud Run invokes the configured startup probe
    Then the probe targets path "/.well-known/oauth-authorization-server"
    And the revision transitions to Ready=True without probe failures being recorded on the revision status
