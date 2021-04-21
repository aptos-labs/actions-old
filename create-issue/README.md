# create-issue

This action creates a GH issue or update an existing open one of matching title.

## Usage

Here's an example workflow using this action:

```yaml
some-job:
  runs-on: ubuntu-latest
  name: create an issue
  steps:
    - name: checkout
      uses: actions/checkout@v2
    - name: require review
      uses: diem/actions/create-issue@90db1e55a7a
      with:
        github-token: ${{ secrets.GITHUB_TOKEN }}
        title: "Found an issue in xyz"
        body: "blah blah"
        assignees: "some-oncall"
        labels: "some-issue-abc"
```
