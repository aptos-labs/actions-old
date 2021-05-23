#!/bin/bash

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
check_command allure xsltproc echo getopts tail echo getopts

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

# Assumed location where the shell file was run from, used to look up get_artifacts shell script.
TOOLS_BASE="./"

# Number of prior historical runs to grab or build, so that those pushed contain fully populated historical graphs.
FETCH_COUNT=$((HISTORY_COUNT + HISTORY_EXTRA_REPORTS_NUMBER))


# STEP 1:   Gather all github artifacts we may need.
# Use get_artifact.sh to pull all xml artifacts that were successful from target workflow/branch/repo and unzip them.
# This is our source of truth
# Remote historic reports copied in will be based of the information found here.
"${TOOLS_BASE}"get_artifacts/get_artifacts.sh -d "${ARTIFACTS_DIR}" -a "$ARTIFACTS" -w "$WORKFLOW_FILE" -b "$BRANCH" -r "$REPOSITORY" -h "$FETCH_COUNT" -t "$TOKEN" -i "$WORKFLOW_RUN_ID" -z -s


# The pushlist, determines which report directories get pushed back to aws, if greater than 1, you probably may want to set RECOMPUTE to true.
# Used in step 6 bellow, kept here so it's easy to compare with prior lists, and kept in sync.
PUSH_LIST=$(find "$ARTIFACTS_DIR" -maxdepth 1 -mindepth 1 -type d | sed 's/.*\///' | sort -n | tail -"${HISTORY_COUNT}" )
# Notice the process list is greater than the asked for history count, since each report contains up to HISTORY_EXTRA_REPORTS_NUMBER prior historical runs.
PROCESS_LIST=$(find "$ARTIFACTS_DIR" -maxdepth 1 -mindepth 1 -type d | sed 's/.*\///' | sort -n | tail -${FETCH_COUNT} )

echo Process list "${PROCESS_LIST}"


# STEP 2:  Download existing reports, if any, from the remote copy source.
# Get the sub dirs (one per job number) and sort them in numeric order.
set +x

#Uncomment when can list files in s3.
#for dir in $PROCESS_LIST; do
#  echo Fetching remote reports for: "$dir"
#  rcp_from "$ARTIFACT_FILE_PATH""$dir" "$REPORT_ROOT"
#done

# If anything in this script is _ever_ used to modify the original test reports in 3rd party storage access by rcp_from and rcp_to
# we can rerun step 1 here to overwrite the modifid artifacts.


# Get the sub dirs (one per job number) and sort them in numeric order -- we will get requested history + HISTORY_EXTRA_REPORTS_NUMBER,
# So that if we need to recreate older reports they will have the needed history, we will never push back these older
# Reports to remote storage, just the one explicitly requested.
for dir in $PROCESS_LIST; do
  echo Processesing: "$dir"

  #STEP 3:  Generate, or regerate reports, if requested.

  # Make working dir to hold xslt and regex junit.xml
  work_dir="${ARTIFACTS_DIR}/${dir}"/transformed_junitxml/

  if [ ! -d "$work_dir" ] || [ "$RECOMPUTE" == "true" ]; then
    rm -rf "${work_dir}"
    mkdir -p "${work_dir}"
    # copy all xml files from subdir (unzipped artifacts) to working dirs, some jobs will not produce artifacts.
    cp "${ARTIFACTS_DIR}/${dir}"/artifacts/*/*.xml "${work_dir}" 2>/dev/null || true
    # gather and transform the unit test xml files with xslt, and sed to remove busted characters.
    for xmlfile in "${work_dir}"*.xml; do
      if [ -f "${xmlfile}" ]; then

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
        xsltproc "${TOOLS_BASE}"/results-transformer/transform.xml "${xmlfile}_old" | (tidy -xml -i -q -w 1000 - || true) >> "${xmlfile}"
        rm "${xmlfile}_old"
      fi
    done

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
      echo "\"url\":\"./${WORKFLOW_ID}/report\",";
      echo "\"reportUrl\":\"../../${WORKFLOW_ID}/report\",";
      echo "\"buildUrl\":\"https://github.com/${REPOSITORY}/actions/runs/${WORKFLOW_ID}\",";
      echo "\"buildName\":\"GitHub Actions Run #${WORKFLOW_ID}\",\"buildOrder\":\"${INPUT_GITHUB_RUN_NUM}\"}";
    } >> "$work_dir"/executor.json

    # Copy allure configuration in to place.
    # Allure.yml determines which allure reports to generate (aka, what plugins to run.)
    cp "${ALLURE_CONFIGURATION}"/allure.yml "${work_dir}"

    # Categories groups test success and failures, but test result, and regex over contents.
    cp "${ALLURE_CONFIGURATION}"/categories.json "${work_dir}"
  fi


  # Step 5:  Generate report if missing, or asked to recompute.
  report_dir="${ARTIFACTS_DIR}/${dir}"/report/
  if [ ! -d "$report_dir" ] || [ "$RECOMPUTE" == "true" ]; then
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

# STEP 6:  Push all regenerated reports existing reports, if any, from the remote copy source.
# Get the sub dirs (one per job number) and sort them in numeric order.
#for dir in $PUSH_LIST; do
#  echo Fetching remote reports for: "$dir"
#  rcp_to "$ARTIFACT_FILE_PATH""$dir" "$REPORT_ROOT"
#done

#STEP 7:  Create a redirecting index.html file pointing to the latest report to be generated.
LATEST=$(find "$ARTIFACTS_DIR" -maxdepth 1 -mindepth 1 -type d | sed 's/.*\///' | sort -n | tail -1 )
{
  echo "<!DOCTYPE html>"
  echo "<meta charset=\"utf-8\">"
  echo "<meta http-equiv=\"refresh\" content=\"0; URL=./${LATEST}/report/index.html\">"
  echo "<meta http-equiv=\"Pragma\" content=\"no-cache\">"
  echo "<meta http-equiv=\"Expires\" content=\"0\">"
}  > "${ARTIFACTS_DIR}"/index.html
rcp_to "$ARTIFACT_FILE_PATH"/index.html "$REPORT_ROOT"