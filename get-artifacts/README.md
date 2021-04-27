# Get Artifacts #

A downloader for artifacts from multiple prior workflow_runs (by workflow_file_name and branch), or a single run by workflow_run_id.

Artifacts are always uploaded as zips, correspondingly this action allows you to unzip and then delete the original downloads with the "decompress" flags.

If an ```${{ inputs.target_dir }}/<workflow_run_id>/<artifact_name>/``` folder already exist no attempt will be made to download the artifacts for that run.  The assumption it github's cache action can be use to preserve prior downloads between workflow executions, preventing unnecessary downloads.  More info on cacheing [here](https://docs.github.com/en/actions/guides/caching-dependencies-to-speed-up-workflows "caching-dependencies-to-speed-up-workflows").

## Examples ##

Download artifacts from one workflow run.

```yaml
  test-get-artifacts-single:
    runs-on: ubuntu-latest
    name: test get-artifacts single job
    steps:
      - uses: actions/checkout@v2
      - name: Download and extract single run's artifacts.
        uses: ./get-artifacts
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
          workflow_run_id: ${{ github.event.workflow_run.id }}
          artifacts: test.download
          # the following lines are defaults included for clarity.
          target_dir: ${{ github.workspace }}/downloads
          decompress: true
      - name: Test that "test.download" got downloaded
        run: |
          [[ -f  ${{ github.workspace }}/downloads/${{ github.event.workflow_run.id }}/test.download/test-file.download ]]
      - name: Test that "test.not-download" did not get downloaded
        run: |
          [[ ! -f  ${{ github.workspace }}/downloads/${{ github.event.workflow_run.id }}/test.not-download/test-file.not-download ]]
```

Download artifacts from multiple workflow runs, newest to oldest by repo (optional, calculated), branch (optional, ignored), and workflow_file name (mandatory).  The workflow_file must be the full name of the workflow file in the .github/workflows/ directory.

```yaml
  test-get-artifacts-multiple:
    runs-on: ubuntu-latest
    name: test get-artifacts-multiple
    steps:
      - uses: actions/checkout@v2
      - name: Download and extract single run's artifacts.
        uses: ./get-artifacts
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
          workflow_file: create-artifacts.yml
          artifacts: test.download test.not-download
          branch: master
      - name: Test that multiple jobs files got downloaded
        run: |
          [[ -f ${{ github.workspace }}/downloads/${{ github.event.workflow_run.id }}/test.download/test-file.download ]]
          [[ -f ${{ github.workspace }}/downloads/${{ github.event.workflow_run.id }}/test.not-download/test-file.not-download ]]
          [[ $( ls -l ${{ github.workspace }}/downloads/ | wc -l ) -gt 1 ]]
```
