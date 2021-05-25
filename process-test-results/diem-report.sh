#!/bin/bash
#
#  This is where nextest/diem specific code resides.   It is generally passed to report.sh as bash functions
#  that may be used by the report.sh script.
#


# fast fail.
set -eo pipefail

function echoerr() {
  cat <<< "$@" 1>&2;
}

# Check prerequisites.
function check_command() {
  for var in "$@"; do
    if ! (command -v "$var" >/dev/null 2>&1); then
      echoerr "This command requires $var to be installed"
      exit 1
    fi
  done
}
check_command allure xsltproc tidy echo getopts tail dirname pwd

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
echo SCRIPT_DIR: "$SCRIPT_DIR"

function usage() {
  echo -t token used to communicate with github actions.
  echo -h number of workflow_runs to pull artifacts from \(optional: defaults to \"20\" \).
  echo -a space seperated list of artifact names \(optional: defaults to \"unit-test-results codegen-unit-test-results\" \).
  echo -b branch to pull historical artifacts from \(optional: defaults to \"auto\" \).
  echo -w workflow file name of of workflow to pull artifact from \(optional: defaults to \"ci-test.yml\" \).
  echo -d target directory where incremental work and reports will be stored.
  echo -c allure2 configuration directory \(should contain an allure.yml and optionally a categories.json\).
  echo -m recompute reports, useful if report history needs a different transformations.
  echo -i if set, overrides typical historic artifact downloading, and lets you run a single report on downloaded artifacts.
  echo -? this message.
  echo output will files will be written to the -t target directory.
  echo
  echo This script expects a configured aws s3 endpoint to exist, and transform xml to be more junit-ish.
}

#Github access token
TOKEN=
#Number of historic unit test results to aquire.
HISTORY_COUNT=20
#Space seperated names of artifacts from each build we want.
ARTIFACTS="unit-test-results codegen-unit-test-results"
#Github slug for a repo
REPOSITORY="diem/diem"
#The name of the workflow file who's artifact's we'll aquire.
WORKFLOW_FILE="ci-test.yml"
#The branch who's history we want.
BRANCH="auto"
#Where all artifacts will be downloaded and processed in to a report
WORK_DIR=
#Should we reprocess xml test result, and then recompute reports? To be used when things go awry, or improve.
RECOMPUTE=false
#If set, lets you grab a specific workflow_run_id's artifacts for testing.
WORKFLOW_RUN_ID=

while getopts 'h:a:r:w:b:d:t:c:i:m' OPTION; do
  case "$OPTION" in
    h)
      HISTORY_COUNT="$OPTARG"
      ;;
    a)
      ARTIFACTS="$OPTARG"
      ;;
    r)
      REPOSITORY="$OPTARG"
      ;;
    w)
      WORKFLOW_FILE="$OPTARG"
      ;;
    b)
      BRANCH="$OPTARG"
      ;;
    d)
      WORK_DIR="$OPTARG"
      ;;
    i)
      WORKFLOW_RUN_ID="$OPTARG"
      ;;
    t)
      TOKEN="$OPTARG"
      ;;
    c)
      ALLURE_CONFIGURATION="$OPTARG"
      ;;
    m)
      RECOMPUTE=true
      ;;
    ?)
      usage
      exit 1
      ;;
  esac
done

function rcp_from() {
   code=$( aws s3 cp --recursive --quiet "s3://ci-artifacts.diem.com/testhistory/$1" "${2}${1}"; echo $? ) || true
   if [ "$code" == 1 ]; then
     echo Error writing interacting with files, this is not normal but s3 could be communicated with: "$1"
   fi
   if [ "$code" != 0 ] && [ "$code" != 1 ]; then
     echo Error communicating with s3, this is not normal: "$1"
     return 1
   fi
}
export -f rcp_from

function rcp_to() {
   parameters=()
   if [ -d "${2}${1}" ]; then
     parameters+=("--recursive")
   fi
   code=$( aws s3 cp "${parameters[@]}" --quiet "${2}${1}" "s3://ci-artifacts.diem.com/testhistory/$1"; echo $? ) || true
   if [ "$code" != 0 ] && [ "$code" != 1 ]; then
     echo Error communicating with s3, could not push report: "$1"
     return 1
   fi
}
export -f rcp_to

function transform_junit_xml() {
  xmlfile="$1"
  mv "${xmlfile}" "${xmlfile}_old"
  # use sed to add cdata elements wrapping inner text in <system-out></system-out> and <system-err></system-err> nodes
  # if files contains at least one sequence of "<system-out>"", but no sequence of ""<![CDATA["
  # This is fragile.   Should fix nextest to put all logs in text files like standard junit.
  if [ "$(grep -c '<system-out>' "${xmlfile}_old")" -ne 0 ] && [ "$(grep -c '<!\[CDATA\[' "${xmlfile}_old")" == 0 ]; then
    sed -i '.bk1' 's/<system-out>/<system-out><![CDATA[/g' "${xmlfile}_old"
    sed -i '.bk2' 's/<\/system-out>/]]><\/system-out>/g' "${xmlfile}_old"
    sed -i '.bk3' 's/<system-err>/<system-err><![CDATA[/g' "${xmlfile}_old"
    sed -i '.bk4' 's/<\/system-err>/]]><\/system-err>/g' "${xmlfile}_old"
  fi
  # remove console coloring characters
  sed -i '.bk5' -E "s/"$'\E'"\[([0-9]{1,3}((;[0-9]{1,3})*)?)?[m|K]//g" "${xmlfile}_old"

  #use xslt to wrap testsuites around individual tests (and move the timing appropriately), ignore any problems tidy has reports with character sets, setc.
  xsltproc "${SCRIPT_DIR}"/results-transformer/transform.xml "${xmlfile}_old" | (tidy -xml -i -q -w 1000 - || true) >> "${xmlfile}"
  rm "${xmlfile}_old"
}
export -f transform_junit_xml

EXTRA_ARGS=()
if [ "$RECOMPUTE" == "true" ]; then
   EXTRA_ARGS+=("-m")
fi
if [ -n "$WORKFLOW_RUN_ID" ]; then
   EXTRA_ARGS+=("-i" "$WORKFLOW_RUN_ID")
fi

./report.sh -t "$TOKEN" -h "$HISTORY_COUNT" -a "$ARTIFACTS" -b "$BRANCH" -w "$WORKFLOW_FILE" -r "$REPOSITORY" -c "$ALLURE_CONFIGURATION" -d "$WORK_DIR" "${EXTRA_ARGS[@]}"
