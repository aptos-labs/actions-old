# Get Artifacts #

A downloader for artifacts from multiple prior workflow_runs (by workflow_file name, and branch), or a single run by workflow_run_id.  Instead of workflow_file name, a workflow_id name as described [here](https://docs.github.com/en/rest/reference/actions#list-workflow-runs "list-workflow-runs") may be passed, but please keep in mind if you use workflow_id name collisions may occur and you will recieve a mix of artifacts from different workflows.

Artifacts are always uploaded as zips, correspondingly this action allows you to unzip and then delete the original downloads with the "decompress" flags.

If an ```${{ inputs.target_dir }}/<workflow_run_id>/<artifact_name>/``` folder already exists no attempt will be made to download the artifacts for that run.   This script runs is effectively idempotent provided there are no new workflow runs since it's last invocation.  The assumption is github's cache action can be use to preserve prior downloads between workflow executions, preventing unnecessary downloads should you need to implement a workflow with costly downloads.  More info on caching [here](https://docs.github.com/en/actions/guides/caching-dependencies-to-speed-up-workflows "caching-dependencies-to-speed-up-workflows").

## Examples ##

Download artifacts from one workflow run.

```yaml
  test-get-artifacts-single:
    runs-on: ubuntu-latest
    name: test get-artifacts from a single workflow run
    steps:
      - uses: actions/checkout@v2
      - name: Download and extract single run's artifacts.
        uses: ./get-artifacts
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
          workflow_run_id: ${{ github.event.workflow_run.id }}
          artifacts: test.download
          # the following two lines are default values included for clarity.
          target_dir: ${{ github.workspace }}/downloads
          decompress: true
      - name: Test that "test.download" got downloaded
        run: |
          [[ -f  ${{ github.workspace }}/downloads/${{ github.event.workflow_run.id }}/test.download/test-file.download ]]
          [ $( ls ${{ github.workspace }}/downloads/ | wc -l ) = 1 ]
      - name: Test that "test.not-download" did not get downloaded
        run: |
          [[ ! -f  ${{ github.workspace }}/downloads/${{ github.event.workflow_run.id }}/test.not-download/test-file.not-download ]]
```

Download artifacts from multiple workflow runs, newest to oldest by repo (optional, calculated), branch (optional, ignored), and workflow_file name (mandatory).  The workflow_file must be the full name of the workflow file in the .github/workflows/ directory.

```yaml
  test-get-artifacts-multiple:
    runs-on: ubuntu-latest
    name: test get-artifacts multiple workflow runs.
    steps:
      - uses: actions/checkout@v2
      - name: Download and extract artifacts from the last ten runs of ci-test.yml on the master branch.
        uses: ./get-artifacts
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
          # You may instead pass a workflow id rather than the workflow name, at your discression/peril.
          workflow_file: ci-test.yml
          artifacts: test.download test.not-download
          # optional, otherwise all branches.
          branch: master
          # follow line is a default value included for clarity.
          history: 10
      - name: Test that multiple workflow run's files got downloaded
        run: |
          [[ -f ${{ github.workspace }}/downloads/${{ github.event.workflow_run.id }}/test.download/test-file.download ]]
          [[ -f ${{ github.workspace }}/downloads/${{ github.event.workflow_run.id }}/test.not-download/test-file.not-download ]]
          [ $( ls ${{ github.workspace }}/downloads/ | wc -l ) -gt 1 ]
```
