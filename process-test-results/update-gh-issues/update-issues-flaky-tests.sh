#!/bin/bash

# fast fail.
set -eo pipefail

function usage() {
  echo -t token used to communicate with github apis.
  echo -r target github repository
  echo -w url to workflow run that produced these test results.
  echo -j junit xml, processed by this project
  echo -? this message.
  echo
  echo This script will create issues for any tests that had flakyFailure/flakyErrors reported in them.  It should
  echo only be run on test output that had fully succeeded.
}

REPO=
LABEL="flaky-test"
LOOK_BACK_DAYS=30
JUNIT_FILE=
WORLFLOW_LINK=
TOKEN=

while getopts 'r:w:j:t:' OPTION; do
  case "$OPTION" in
    r)
      REPO="$OPTARG"
      ;;
    w)
      WORLFLOW_LINK="$OPTARG"
      ;;
    j)
      JUNIT_FILE="$OPTARG"
      ;;
    t)
      TOKEN="$OPTARG"
      ;;
    ?)
      usage
      exit 1
      ;;
  esac
done

CURL_HOOKS=("-H" "Authorization: token ${TOKEN}" "-H" "Accept: application/vnd.github.v3+json" "--silent")

#
#  Give two inputs and one global environment variable
#  Input 1: A URL to make a call to a github api that supports pagination
#  Input 2: A file to output the contents of the call
#
#  Global Environment Variable:
#  CURL_HOOKS: extra parameters to pass to curl as a bash array.  Headers, tokens, etc.
#
#  This function calls the url until all data is exhausted (page through the results)
#  Strips out all metadata headers and places _all_ of the returned items in to an
#  anonymous top level json array which is written to the output file.
#
function all_pages() {
  URL=$1
  OUTFILE=$2

  PAGE=0
  PAGE_SIZE=100
  temp_file=$(mktemp /tmp/all_pages.XXXXXX)
  curl "${CURL_HOOKS[@]}" "${URL}&per_page=${PAGE_SIZE}&page=${PAGE}" > "$temp_file"
  incomplete=$(jq '.incomplete_results' < "$temp_file")

  jq '.items' < "$temp_file" | sed \$d > "${OUTFILE}"  #strips the closing ] of the list

  while [ "$incomplete" == "true" ]; do
   PAGE=$((PAGE + 1))
   curl "${CURL_HOOKS[@]}" "${URL}&per_page=${PAGE_SIZE}&page=${PAGE}" > file
   incomplete=$(file | jq '.incomplete_results')
   {
      echo ",
"
      jq '.items' < "$temp_file" | sed \$d | sed '1d'
   } >> "${OUTFILE}"
   done
   echo "]" >>  "${OUTFILE}"
   rm "$temp_file"
}

DATE=
if [ "$( date --version 2>/dev/null | grep -c GNU )" -gt 0 ]; then
   DATE=$(date +%Y-%m-%d -d "${LOOK_BACK_DAYS} days ago")
else
   DATE=$(date -v-${LOOK_BACK_DAYS}d +%Y-%m-%d )
fi
echo Cut off date: "$DATE"

# if sufficiently old we will close.
all_pages "https://api.github.com/search/issues?q=repo:${REPO}+type:issue+%22%5BFlaky%20Test%5D%22+NOT+Stale+in:title+label:${LABEL}+is:open+updated:<${DATE}" old_issues.json
ISSUES_TO_CLOSE=$( jq '.[] | select(.title | startswith ("[Flaky Test]")) | .number' < old_issues.json )

echo Issues to close: "${ISSUES_TO_CLOSE[@]}"

# Close issues and prepend [Stale] to the title to prevent folks/this script from searching for it in the future.
for issue in $ISSUES_TO_CLOSE; do
  echo "Closing stale $issue"
  curl "${CURL_HOOKS[@]}" -X PATCH "https://api.github.com/repos/${REPO}/issues/${issue}" -d '{"state": "closed"}' > result_file
  title="$(jq '.[] | .title' < result_file | sed 's/"//g')"
  if [[ "$title" =~ \[Stale\].\[Flaky.Test\]* ]]; then
     echo Already stale: "${issue}"
  else
     curl "${CURL_HOOKS[@]}" -X PATCH "https://api.github.com/repos/${REPO}/issues/${issue}" -d '{"title": "[Stale] '+"${title}"+'"}'
  fi
done

# Creat a file that will map test names to open (or recently closed issues).
all_pages "https://api.github.com/search/issues?q=repo:${REPO}+type:issue+%22%5BFlaky%20Test%5D%22+NOT+Stale+in:title+label:${LABEL}+updated:>=${DATE}" known_issues.json
jq '.[] | ((.number|tostring) + "@" + .title)' < known_issues.json | sed 's/^"//g' | sed 's/"$//g' > issues_to_names

xsltproc getComment.xml "$JUNIT_FILE" > all_flakes.txt

rm -rf ./flake* || true
csplit -s -f flake -n 3 all_flakes.txt '/:::Start of a newly transformed test case flake:::/' || true

echo Issues to open/update:
for flake in ./flake*; do
  #if the file is not empty space then....
  if [[ "$(grep -q '[^[:space:]]' < "$flake"; echo $?)" == "0" ]]; then
    TESTNAME=$(head -2 < "$flake" | tail -1)
    echo Test name: "$TESTNAME"
    issue_number="$(grep "$TESTNAME" < issues_to_names | sed 's/@.*//g' || true )"
    if [ -z "$issue_number" ]; then
      echo No \(non-stale\) existing issue.
      curl "${CURL_HOOKS[@]}" -X POST "https://api.github.com/repos/${REPO}/issues" -d '{"title":"[Flaky Test] '"${TESTNAME}"'"}' > result_file
      issue_number="$(jq '.number' < result_file)"
      echo created new issue: "$issue_number"
      curl "${CURL_HOOKS[@]}" -X POST "https://api.github.com/repos/${REPO}/issues/${issue_number}/labels" -d '{"labels": [ "flaky-test" ]}' > result_file
    else
      echo Existing issue "$issue_number"
      #Force the issue to be open.
      curl "${CURL_HOOKS[@]}" -X PATCH "https://api.github.com/repos/${REPO}/issues/${issue_number}" -d '{"state": "open"}'
    fi
    #Post a comment about the failure:
    {
      echo '{"body":'
      echo "From: ${WORLFLOW_LINK}
\`\`\`
$(tail -n +3 < "$flake")
\`\`\`" | jq -aRs .
      echo '}'
    } > comment.json
    curl "${CURL_HOOKS[@]}" -X POST "https://api.github.com/repos/${REPO}/issues/${issue_number}/comments" -d @comment.json
  fi
done


