# Source: docs/specs/01-spec-gcp-cloud-run-deployment/01-spec-gcp-cloud-run-deployment.md
# Pattern: CLI/Process + API
# Recommended test type: Integration

Feature: Scheduler Integration and Documentation

  Scenario: Scheduler fires /api/poll against GCP when DISTILLERY_GCP_URL is set
    Given repo variable DISTILLERY_GCP_URL is set to a live Cloud Run service URL $GCP_URL
    And repo variable DISTILLERY_FLY_URL is set to the existing Fly URL $FLY_URL
    When a maintainer runs "gh workflow run scheduler.yml -f job=poll"
    And waits for the resulting run to complete
    Then "gh run view <run-id> --json conclusion --jq .conclusion" prints "success"
    And the run logs show a POST request to "$GCP_URL/api/poll" with response status 200
    And the run logs show a POST request to "$FLY_URL/api/poll" with response status 200

  Scenario: Scheduler behavior is unchanged when DISTILLERY_GCP_URL is unset
    Given repo variable DISTILLERY_GCP_URL is unset or empty
    And repo variable DISTILLERY_FLY_URL is set to $FLY_URL
    When a maintainer runs "gh workflow run scheduler.yml -f job=poll"
    And the resulting run completes
    Then the run logs include a POST to "$FLY_URL/api/poll"
    And the run logs contain no request to any "*.run.app" or GCP-hosted URL
    And no job summary line references GCP

  Scenario: Job summary emits per-target status lines
    Given both DISTILLERY_FLY_URL and DISTILLERY_GCP_URL are set
    When the scheduler run completes
    And a maintainer runs "gh run view <run-id> --json jobs --jq '.jobs[].summary'"
    Then the summary output contains a line matching "fly: ok" or "fly: failed"
    And the summary output contains a line matching "gcp: ok" or "gcp: failed"

  Scenario: GCP failure does not mask Fly success in the overall run
    Given DISTILLERY_GCP_URL points to a URL that returns HTTP 500 for /api/poll
    And DISTILLERY_FLY_URL points to a healthy Fly service
    When the scheduler workflow runs
    Then the run reports the Fly target status as "ok"
    And the run reports the GCP target status as "failed"
    And the overall run conclusion is "failure" (both targets must succeed for the matrix to pass)

  Scenario: docs/gcp.md covers every required section
    Given the repository is checked out at the feature branch
    When an operator runs "grep -E '^## ' docs/gcp.md"
    Then the output lists headings for Prerequisites, Bootstrap, Secret creation, Deploy, Verification, Scheduler wiring, Claude Code MCP client config, Architecture, and Backup (case-insensitive match acceptable)

  Scenario: docs/gcp.md documents the single-replica constraint with rationale
    Given docs/gcp.md exists
    When an operator searches the Architecture table in docs/gcp.md
    Then the table includes the constraint "max_instances=1"
    And the adjacent cell or note explains the reason references GCS FUSE write contention or DuckDB single-writer semantics

  Scenario: README advertises GCP as a third deployment target
    Given the repository is checked out at the feature branch
    When an operator runs "grep -nE '^### Google Cloud Run' README.md"
    Then the command exits with code 0
    And the matched section in README.md is located under the "## Deployments" heading
    And the section contains a usage block parallel in shape to the Fly and Prefect sections (invocation command + link to docs/gcp.md)

  Scenario: Operator follows docs/gcp.md from zero to working MCP response
    Given a fresh GCP project with billing enabled and a GitHub OAuth app pre-registered
    When an operator executes each command block in docs/gcp.md top to bottom
    Then the operator reaches a successful "POST /mcp tools/list" response
    And the wall-clock time from the first command to that response is under 30 minutes
