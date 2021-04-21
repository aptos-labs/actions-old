const core = require("@actions/core");
const github = require("@actions/github");

async function main() {
  try {
    const github_token = core.getInput("github-token", {required: true});
    const title = core.getInput("title", {required: true});
    const body = core.getInput("body", {required: true});
    const assignees = core.getInput("assignees", {required: false});
    const labels = core.getInput("labels", {required: false});

    const assignees_list = (assignees || "")
      .split(",")
      .map(s => s.trim())
      .filter(s => s.length > 0);
    const labels_list = (labels || "")
      .split(",")
      .map(s => s.trim())
      .filter(s => s.length > 0);


    const client = new github.getOctokit(github_token);
    let gh_repo = process.env.GITHUB_REPOSITORY
    // find existing issue
    console.log(`Find existing issue with matching title`);
    let existing
    const existing_issues = await client.search.issuesAndPullRequests({
      q: `repo:${gh_repo} is:issue is:open in:title ${title}`
    });
    if (existing_issues) {
      existing = existing_issues.data.items.find(issue => issue.title === title);
    }

    const owner = github.context.payload.repository.owner.login;
    const repo = github.context.payload.repository.name;
    if (existing) {
      // update in place
      const issue = await client.issues.update({
        issue_number: existing.number,
        owner: owner,
        repo: repo,
        assignees: assignees_list,
        labels: labels_list,
        body: body
      });
      console.log(`Updated issue ${issue.data.number}: ${issue.data.html_url}`);
    } else {
      // create new
      const issue = await client.issues.create({
        owner: owner,
        repo: repo,
        assignees: assignees_list,
        labels: labels_list,
        title: title,
        body: body
      });
      console.log(`Created issue ${issue.data.number}: ${issue.data.html_url}`);
    }
  } catch (error) {
    console.error(error);
    core.setFailed(error.message);
  }
}

main();
