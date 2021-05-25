#!/bin/bash
#
#  Please keep this file free from any diem specific code, or unit test transformation.
#  diem-report.sh is where that code may exist.
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
check_command allure echo getopts tail dirname pwd

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
echo SCRIPT_DIR: "$SCRIPT_DIR"

HISTORY_EXTRA_REPORTS_NUMBER=19

function usage() {
  echo -t token used to communicate with github actions.
  echo -h number of workflow_runs to pull artifacts from \(${HISTORY_EXTRA_REPORTS_NUMBER} more will be pulled and processed to generate full history if needed\).
  echo -a space seperated list of artifact names.
  echo -b branch to pull historical artifacts from.
  echo -w workflow file name of of workflow to pull artifact from.
  echo -d target directory where incremental work and reports will be stored.
  echo -c allure2 configuration directory \(should contain an allure.yml and optionally a categories.json\).
  echo -m recompute reports, useful if report history needs a different transformations.
  echo -i if set, overrides typical historic artifact downloading, and lets you run a single report on downloaded artifacts.
  echo -? this message.
  echo output will files will be written to the -t target directory.
  echo
  echo This script support three functions users may choose to supply, but does not require them.
  echo
  echo rcp_from and rcp_to, these copy files to and from a remote store.  They must support two inputs.
  echo Input one: a sub path that must be mirrored locally or remotely.
  echo Input two: the local path containing the subpath.
  echo For instance: rcp_to local/dir/path/to/mirror/with/files/ /home/dir/ would expect to find files here to copy:
  echo /home/dir/local/dir/path/to/mirror/with/files/
  echo
  echo transform_junit_xml supports one input, and expects any preprocessing to a junit xml result file to occur to that file in place.
  echo the target file may be delete/moved/recreated/etc.
}

#Github access token
TOKEN=
#Number of historic unit test results to aquire.
HISTORY_COUNT=
#Space seperated names of artifacts from each build we want.
ARTIFACTS=
#Github slug for a repo
REPOSITORY=
#The name of the workflow file who's artifact's we'll aquire.
WORKFLOW_FILE=
#The branch who's history we want.
BRANCH=
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

# Where all work will be done locally.
REPORT_ROOT="${WORK_DIR}/history/"

# Where this projects work will occur inside the REPORT_ROOT.
# Important so that final location doesn't have conflicts between projects/branches/workflows
ARTIFACT_FILE_PATH="${REPOSITORY}/${BRANCH}/${WORKFLOW_FILE}/"

# All work for this run will occur in this directory.
# however, all pushes/pulls from the remote site will be relative to the REPORT_ROOT above
ARTIFACTS_DIR="${REPORT_ROOT}${ARTIFACT_FILE_PATH}"
mkdir -p "$ARTIFACTS_DIR"

# Number of prior historical runs to grab or build, so that those pushed contain fully populated historical graphs.
FETCH_COUNT=$((HISTORY_COUNT + HISTORY_EXTRA_REPORTS_NUMBER))


# STEP 1:   Gather all github artifacts we may need.
# Use get_artifact.sh to pull all xml artifacts that were successful from target workflow/branch/repo and unzip them.
# This is our source of truth
# Remote historic reports copied in will be based of the information found here.
"${SCRIPT_DIR}"/../get-artifacts/get_artifacts.sh -d "${ARTIFACTS_DIR}" -a "$ARTIFACTS" -w "$WORKFLOW_FILE" -b "$BRANCH" -r "$REPOSITORY" -h "$FETCH_COUNT" -t "$TOKEN" -i "$WORKFLOW_RUN_ID" -z -s


# The pushlist, determines which report directories get pushed back to aws, if greater than 1, you probably may want to set RECOMPUTE to true.
# Used in step 6 bellow, kept here so it's easy to compare with prior lists, and kept in sync.
PUSH_LIST=$(find "$ARTIFACTS_DIR" -maxdepth 1 -mindepth 1 -type d | sed 's/.*\///' | sort -n | tail -"${HISTORY_COUNT}" )
# Notice the process list is greater than the asked for history count, since each report contains up to HISTORY_EXTRA_REPORTS_NUMBER prior historical runs.
PROCESS_LIST=$(find "$ARTIFACTS_DIR" -maxdepth 1 -mindepth 1 -type d | sed 's/.*\///' | sort -n | tail -${FETCH_COUNT} )

echo Process list:
echo "${PROCESS_LIST}"


# STEP 2:  Download existing reports, if any, from the remote copy source.
# Get the sub dirs (one per job number) and sort them in numeric order.
set +x

# If a supplied shell function exists called `rcp_from` it will be called with the two parameters.
# The name of the remote path to look for to attempt to download, and the local path leading to
# a mirrored local location of that remote path.
if [ "$( type rcp_from 2>&1 > /dev/null ; echo $? )" = "0" ]; then
  for dir in $PROCESS_LIST; do
    echo Fetching remote reports for: "$dir"
    rcp_from "$ARTIFACT_FILE_PATH""$dir" "$REPORT_ROOT"
  done
fi

# If anything in this script is _ever_ used to modify the original test reports in 3rd party storage access by rcp_from and rcp_to
# we can rerun step 1 here to overwrite the modifid artifacts.

# The reports we will push to remote storage via rcp_to.
REPORTS_TO_PUBLISH=()

# Get the sub dirs (one per job number) and sort them in numeric order -- we will get requested history + HISTORY_EXTRA_REPORTS_NUMBER,
# So that if we need to recreate older reports they will have the needed history, we will never push back these older
# Reports to remote storage, just the one explicitly requested.
for dir in $PROCESS_LIST; do
  echo Processesing: "$dir"

  #STEP 3:  Generate, or regerate reports, if requested.

  # Make working dir to hold possible transformation of xml files.
  work_dir="${ARTIFACTS_DIR}${dir}"/transformed_junitxml/

  if [ ! -d "$work_dir" ] || [ "$RECOMPUTE" == "true" ]; then
    rm -rf "${work_dir}"
    mkdir -p "${work_dir}"
    # copy all xml files from subdir (unzipped artifacts) to working dirs, some jobs will not produce artifacts.
    cp "${ARTIFACTS_DIR}${dir}"/artifacts/*/*.xml "${work_dir}" 2>/dev/null || true

    # gather and transform the unit test xml files with a shell function of transform_junit_xml, should it exist.
    if [ "$( type transform_junit_xml 2>&1 > /dev/null ; echo $? )" = "0" ]; then
      for xmlfile in "${work_dir}"*.xml; do
        if [ -f "${xmlfile}" ]; then
          transform_junit_xml "${xmlfile}"
        fi
      done
    fi

    # STEP 4: Set up extra allure 2 input for report generation.
    # environment properties to display in a report.
    {
      echo "REPOSITORY=${REPOSITORY}";
      echo "BRANCH=${BRANCH}";
      echo "WORKFLOW_FILE=${WORKFLOW_FILE}";
      echo "ARTIFACTS=${ARTIFACTS}";
    }  >> "$work_dir"environment.properties

    WORKFLOW_ID="$dir"
    # Make executor.json, determines links between reports, to original job
    {
      echo '{"name":"Test History: '"${REPOSITORY}/${BRANCH}/${WORKFLOW_FILE}"'","type":"github","reportName":"Test History: '"${REPOSITORY}/${BRANCH}/${WORKFLOW_FILE}"'",';
      echo "\"url\":\"./${WORKFLOW_ID}/report/index.html\",";
      echo "\"reportUrl\":\"../../${WORKFLOW_ID}/report/index.html\",";
      echo "\"buildUrl\":\"https://github.com/${REPOSITORY}/actions/runs/${WORKFLOW_ID}\",";
      echo "\"buildName\":\"GitHub Actions Run #${WORKFLOW_ID}\",\"buildOrder\":\"${INPUT_GITHUB_RUN_NUM}\"}";
    } >> "$work_dir"executor.json

    # Copy allure configuration in to place.
    # Allure.yml determines which allure reports to generate (aka, what plugins to run.)
    cp "${ALLURE_CONFIGURATION}"/allure.yml "${work_dir}"

    # Categories groups test success and failures, but test result, and regex over contents.
    cp "${ALLURE_CONFIGURATION}"/categories.json "${work_dir}"
  fi

  # Step 5:  Generate report if missing, or asked to recompute.
  report_dir="${ARTIFACTS_DIR}${dir}"/report/
  if [ ! -d "$report_dir" ] || [ "$RECOMPUTE" == "true" ] ; then
    REPORTS_TO_PUBLISH+=("$dir")
    rm -rf "${report_dir}"
    mkdir -p "${report_dir}"

    # Copy history from prior run of this loop (if it exists)
    if [ -n "${LAST_HISTORY}" ] && [ -d "${LAST_HISTORY}" ]; then
      cp -r "${LAST_HISTORY}" "${work_dir}"history
    fi

    # generate an allure report for this build to get the history json file.
    # Disable allure analytics to save time.
    ALLURE_NO_ANALYTICS=1 allure generate --config "${work_dir}"/allure.yml --clean "${work_dir}" --output "${report_dir}"
    LAST_HISTORY="${report_dir}"history
  else
    LAST_HISTORY="${report_dir}"history
  fi
done

#STEP 6:  Create a redirecting index.html file pointing to the latest report.
LATEST=$(find "$ARTIFACTS_DIR" -maxdepth 1 -mindepth 1 -type d | sed 's/.*\///' | sort -n | tail -1 )
{
  echo "<!DOCTYPE html>"
  echo "<meta charset=\"utf-8\">"
  echo "<meta http-equiv=\"refresh\" content=\"0; URL=./${LATEST}/report/index.html\">"
  echo "<meta http-equiv=\"Pragma\" content=\"no-cache\">"
  echo "<meta http-equiv=\"Expires\" content=\"0\">"
}  > "${ARTIFACTS_DIR}"index.html

# If a supplied shell function exists called `rcp_from` it will be called with the two parameters.
# The name of the remote path to look for to push the local files to, and the local path leading to
# a mirrored local location of that remote path.
if [ "$( type rcp_to 2>&1 > /dev/null ; echo $? )" = "0" ]; then
  # STEP 7:  Push all generated reports, if any, from the remote copy source.
  # Get the sub dirs (one per job number) and sort them in numeric order.
  for dir in $PUSH_LIST; do
    if [[ $(echo "${REPORTS_TO_PUBLISH[@]}" | grep -q "$dir"; echo $?) == 0 ]]; then
      echo Pushing report to remote storage: "$dir"
      rcp_to "$ARTIFACT_FILE_PATH""$dir" "$REPORT_ROOT"
    else
      echo Not pushing report to remote storage since it was not regenerated: "$dir"
    fi
  done
  rcp_to "$ARTIFACT_FILE_PATH"index.html "$REPORT_ROOT"
fi
