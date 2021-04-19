const core = require("@actions/core");
const github = require("@actions/github");
const fs = require('fs');
const path = require('path');
const extract_zip = require('extract-zip');

async function main() {
  try {
    const run_id = parseInt(core.getInput("run-id", {required: true}));
    // These aren't required but have defaults, so pass in required: true.
    const pattern = core.getInput("pattern", {required: true});
    const artifact_path = core.getInput("path", {required: true});
    const extract = core.getInput("extract", {required: true}) === 'true';

    const dest_path = path.join(github.workspace, artifact_path);
    fs.mkdirSync(dest_path, {recursive: true});

    const owner = github.context.repo.owner;
    const repo = github.context.repo.repo;

    var artifacts = await github.actions.listWorkflowRunArtifacts({
      owner: owner,
      repo: repo,
      run_id: run_id
    });

    const pattern_re = new RegExp(pattern);

    for (const artifact of artifacts.data.artifacts) {
      if (!pattern_re.test(artifact.name)) {
        console.log(`Skipping artifact ${artifact.name} because it doesn't match pattern '${pattern}'`);
        continue;
      }

      var download = await github.actions.downloadArtifact({
        owner: owner,
        repo: repo,
        artifact_id: artifact.id,
        archive_format: 'zip',
      });

      const this_artifact_path = path.join(artifacts_path, `${artifact.name}.zip`)
      fs.writeFileSync(artifact_path, Buffer.from(download.data));
      console.log(`Downloaded ${this_artifact_path}`);

      if (extract) {
        const target = path.join(artifacts_path, artifact.name);
        await extract_zip(artifact_path, {dir: target});
        console.log(`Extracted ${this_artifact_path} to ${target}`)
      }
    }
  } catch (error) {
    core.setFailed(error.message);
  }
}

main();
