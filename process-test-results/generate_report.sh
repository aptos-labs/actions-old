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
check_command allure xsltproc echo getopts

function usage() {
  echoerr "fix it up."
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
#Should we want to process a single workflow run, we would pass the id rather than the BRANCH, WORKFLOW_FILE, and REPOSITORY
WORKFLOW_RUN_ID=

while getopts 'h:a:r:w:b:i:t:d:z' OPTION; do
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
    i)
      WORKFLOW_RUN_ID="$OPTARG"
      ;;
    d)
      WORK_DIR="$OPTARG"
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

ARTIFACTS_DIR="$WORK_DIR"/history;
mkdir -p "$ARTIFACTS_DIR"

TOOLS_BASE="./"

#Make environment file
ALLURE_CONFIG="$WORK_DIR"/allure_config/
mkdir -p "$ALLURE_CONFIG"
ENV_FILE="$ALLURE_CONFIG"/environment.properties
echo "REPOSITORY=${REPOSITORY}" >> "$ENV_FILE"
echo "BRANCH=${BRANCH}" >> "$ENV_FILE"
echo "WORKFLOW_FILE=${WORKFLOW_FILE}" >> "$ENV_FILE"
echo "ARTIFACTS=${ARTIFACTS}" >> "$ENV_FILE"
echo "WORKFLOW_RUN_ID=${WORKFLOW_RUN_ID}" >> "$ENV_FILE"
echo "HISTORY_COUNT=${HISTORY_COUNT}" >> "$ENV_FILE"

#Make executor json
EXECUTOR_FILE="$ALLURE_CONFIG"/executor.json

echo '{"name":"Test History: ${REPOSITORY}/${BRANCH}/${WORKFLOW_FILE}","type":"github","reportName":"Test History: ${REPOSITORY}/${BRANCH}/${WORKFLOW_FILE}",' > "$EXECUTOR_FILE"
echo "\"url\":\"${GITHUB_PAGES_WEBSITE_URL}\"," >> "$EXECUTOR_FILE"
echo "\"reportUrl\":\"${GITHUB_PAGES_WEBSITE_URL}/${INPUT_GITHUB_RUN_NUM}/\"," >> "$EXECUTOR_FILE"
echo "\"buildUrl\":\"https://github.com/${INPUT_GITHUB_REPO}/actions/runs/${INPUT_GITHUB_RUN_ID}\"," >> "$EXECUTOR_FILE"
echo "\"buildName\":\"GitHub Actions Run #${INPUT_GITHUB_RUN_ID}\",\"buildOrder\":\"${INPUT_GITHUB_RUN_NUM}\"}" >> "$EXECUTOR_FILE"

#use get_artifact.sh to pull all xml artifacts.
"${TOOLS_BASE}"get_artifacts/get_artifacts.sh -d "${ARTIFACTS_DIR}" -a "$ARTIFACTS" -w "$WORKFLOW_FILE" -b "$BRANCH" -r "$REPOSITORY" -h "$HISTORY_COUNT" -i "$WORKFLOW_RUN_ID" -t "$TOKEN" -z

set -x
LAST_HISTORY=
for dir in $(find "$ARTIFACTS_DIR" -maxdepth 1 -mindepth 1 -type d | sed 's/.*\///' | sort -n); do
  echo Processesing: "$dir"
  # Make working dir
  work_dir="${ARTIFACTS_DIR}/${dir}"/work/
  rm -rf "${work_dir}"
  mkdir -p "${work_dir}"
  report_dir="${ARTIFACTS_DIR}/${dir}"/report/
  rm -rf "${report_dir}"
  mkdir -p "${report_dir}"
  # copy all xml files from subdir (unzipped artifacts) to working dirs, some jobs will not produce artifacts.
  cp "${ARTIFACTS_DIR}/${dir}"/*/*.xml "${work_dir}" || true
  # gather and transform the unit test xml files.
  for xmlfile in "${work_dir}"*.xml; do
    mv "${xmlfile}" "${xmlfile}_old"
    xsltproc "${TOOLS_BASE}"/results-transformer/transform.xml "${xmlfile}_old" | tidy -xml -i -q -w 1000 - >> "${xmlfile}"
    rm "${xmlfile}_old"
  done
  cp -r "${TOOLS_BASE}"allure-configuration/ "${work_dir}"
  # generate an allure report for this build to get the history json file.
  if [ -n "${LAST_HISTORY}" ]; then
    cp -r "${LAST_HISTORY}" "${work_dir}"history
  fi
  allure -v generate --config "${work_dir}"/allure.yml --clean "${work_dir}" --output "${report_dir}"
  LAST_HISTORY="${report_dir}"history
  #rm -rf "${work_dir}"
done