const core = require("@actions/core");
const github = require("@actions/github");
const fs = require('fs');
const path = require('path');
const extract_zip = require('extract-zip');

async function main() {
  try {
    const github_token = core.getInput("github-token", {required: true});
    const run_id = parseInt(core.getInput("run-id", {required: true}));
    // These aren't required but have defaults, so pass in required: true.
    const pattern = core.getInput("pattern", {required: true});
    const artifact_dir = core.getInput("dir", {required: true});
    const extract = core.getInput("extract", {required: true}) === 'true';

    const octokit = github.getOctokit(github_token);

    const dest_dir = path.join(octokit.workspace, artifact_dir);
    fs.mkdirSync(dest_path, {recursive: true});

    const owner = github.context.repo.owner;
    const repo = github.context.repo.repo;

    var artifacts = await octokit.rest.actions.listWorkflowRunArtifacts({
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

      var download = await octokit.rest.actions.downloadArtifact({
        owner: owner,
        repo: repo,
        artifact_id: artifact.id,
        archive_format: 'zip',
      });

      const artifact_path = path.join(dest_dir, `${artifact.name}.zip`)
      fs.writeFileSync(artifact_path, Buffer.from(download.data));
      console.log(`Downloaded ${artifact_path}`);

      if (extract) {
        const target = path.join(dest_dir, artifact.name);
        await extract_zip(artifact_path, {dir: target});
        console.log(`Extracted ${artifact_path} to ${target}`)
      }
    }
  } catch (error) {
    core.setFailed(error.message);
  }
}

main();
