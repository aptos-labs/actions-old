# download-artifacts

This action lets a workflow download artifacts from a job. An optional
pattern can be specified.

## Usage

To use this, add a workflow file such as:

```yaml
name: ci-test-complete

on:
  # This action is often appropriate for workflow_run jobs, but it can be used with any kind of job
  workflow_run:
    workflows: ["ci-test"]
    types:
      - completed

jobs:
  process-artifacts:
    runs-on: ubuntu-latest
    name: Process artifacts
    steps:
      - name: Download and extract artifacts
        uses: diem/actions/download-artifacts@<version>
        with:
          # The ID for the workflow run.
          run-id: ${{ github.event.workflow_run.id }}
          # "pattern" specifies a regex of artifact names to download. Default is to download all artifacts.
          pattern: '^.*-test-results$'
          # "dir" is the destination directory to write out artifacts to. The default is "artifacts".
          dir: 'my-artifacts'
          # If "extract" is set to true, artifacts will be unzipped to path/<artifact-name>. Defaults to false.
          extract: true
      # At this point, the artifacts are available in the "artifacts" directory. They can be processed as appropriate.
      - name: Process artifacts
        # ...
```

## Updating

After making changes to `src/index.js` you must run `npm run prepare` to
generate `dist/*` files and check those in for the action to run successfully.
