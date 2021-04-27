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
check_command jq curl zip echo getopts

function usage() {
  echo -t token used to communicate with github actions.
  echo -h number of workflow_runs to pull artifacts from.
  echo -a space seperated list of artifact names.
  echo -b optional branch to pull historical artifacts from.
  echo -w workflow file name of of workflow to pull artifact from.
  echo -d target directory where subdirectories for jobs will be created and artifacts will be unzip to.
  echo -i the single workflow_run from which to download artifacts.  Overrides -b, -w, and -h
  echo -z decompress and delete the original downloaded artifacts.
  echo -? this message.
  echo output will files will be written to the -t target directory.
}

TOKEN=
HISTORY=
ARTIFACTS=
REPO=
WORKFLOW=
BRANCH=
TARGET_DIR=
WORKFLOW_RUN_ID=
DECOMPRESS=false


while getopts 'h:a:r:w:b:i:t:d:z' OPTION; do
  case "$OPTION" in
    h)
      HISTORY="$OPTARG"
      ;;
    a)
      IFS=' ' read -ra ARTIFACTS <<< "$OPTARG"
      ;;
    r)
      REPO="$OPTARG"
      ;;
    w)
      WORKFLOW="$OPTARG"
      ;;
    b)
      BRANCH="$OPTARG"
      ;;
    i)
      WORKFLOW_RUN_ID="$OPTARG"
      ;;
    d)
      TARGET_DIR="$OPTARG"
      ;;
    z)
      DECOMPRESS="true"
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

if [[ -z "${TARGET_DIR}" ]]; then
  echoerr target directory must be specified.
  usage
  exit 1
fi

if [[ -z "${WORKFLOW_RUN_ID}" ]]; then
  if [[ -z "${BRANCH}" ]] || [[ -z "${WORKFLOW}" ]]; then
    echoerr 'You must either specify a workflow_run_id (-i), or a branch (-b) and a workflow file (-w).'
    usage
    exit 1
  fi
fi

curl_attri=("--retry" "3")
curl_attri+=("--silent")
curl_attri+=("--show-error")
curl_attri+=('-H' 'Accept: application/vnd.github.v3+json')
if [ -n "$TOKEN" ]; then
  curl_attri+=('-H' "authorization: Bearer ${TOKEN}")
fi
echoerr Curl Parameters: "${curl_attri[@]}"

# Conditionally retrieves the artifacts from a single workflow run specified by the input parameter which must correspond to a numeric
# workflow_run_id in github actions.  The desired artifacts, named in a list called "ARTIFACTS" are stored in a subdirectory of TARGET_DIR,
# equal to the TARGET_DIR/${workflow_run_id}/${artifact_name}.
#
# Since artifacts are always zips, the zip file is downloaded and optionally unzipped in to the artifact's directory
# (again, TARGET_DIR/${workflow_run_id}/${artifact_name} ), and then deleted.
#
# Should the subfolder TARGET_DIR/${workflow_run_id}/${artifact_name} already exist, no downloads are attempted, as the assumption would
# be this function has already populated the artifacts in to the TARGET_DIR/${workflow_run_id}/${artifact_name} directory either as a zip
# or as unzipped files.
#
# INPUT:
#  Parameter 1:  A number workflow_run_id
#
# ENVIRONMENT:
#  TARGET_DIR: A root dir for creation of sub directories for each job
#  ARTIFACTS: A bash array of artifact names to download from github artifacts workflows for this job.
#  REPO: Github slug corresponding to a repository
#  UNZIP: unzip and delete the downloaded artifact?
#
# SIDE EFFECTS:
#  The ${TARGET_DIR}/${Parameter 1} dir id populated with the unzipped contents of the artifacts from the job.
#
function get_artifacts_from_workflow() {
  workflow_run_id=$1;
  echoerr getting artifacts for jobId "$workflow_run_id"
  artifact_info="$( curl "${curl_attri[@]}" "https://api.github.com/repos/${REPO}/actions/runs/${workflow_run_id}/artifacts" )"
  for artifact_name in "${ARTIFACTS[@]}"; do
    if [ ! -d "${TARGET_DIR}/${workflow_run_id}/${artifact_name}" ]; then
      mkdir -p "${TARGET_DIR}/${workflow_run_id}/${artifact_name}"
      download_url_str="$(echo "$artifact_info" | jq '.artifacts[] | select(.name=="'"${artifact_name}"'") .archive_download_url')"
      if [ -n "$download_url_str" ] && [ "$download_url_str" != "null" ]; then
        download_url="${download_url_str//\"/}"
        curl -L "${curl_attri[@]}" "$download_url" -o "${TARGET_DIR}/${workflow_run_id}/${artifact_name}/${artifact_name}.zip"
        if [ "$DECOMPRESS" = "true" ]; then
          unzip -q "${TARGET_DIR}/${workflow_run_id}/${artifact_name}/${artifact_name}.zip" -d "${TARGET_DIR}/${workflow_run_id}/${artifact_name}/"
          rm "${TARGET_DIR}/${workflow_run_id}/${artifact_name}/${artifact_name}.zip"
        fi
      else
        echoerr Artifact not found on workflow run: "${workflow_run_id}" with contents:
        echoerr "$artifact_info"
      fi
    fi
  done
  echoerr fetched:
  echoerr "$(ls -d "${TARGET_DIR}/${workflow_run_id}/"*/*)"
}

# Given a REPO, WORKFLOW and (optional) BRANCH, get the latest workflow_run_ids as text output of the lenth specified by HISTORY, one per line.
#
function get_workflow_run_ids() {
  # Always using temp files for curl output to prevent shell mangling of new lines in user comments on prs.
  # That data will come back in this request and due to end of line transformatsions break multiline strings in json parsing via jq.
  tmpfile=$(mktemp /tmp/get_reports.XXXXXX)
  PARAMETERS=
  if [ -n "$BRANCH" ]; then
    PARAMETERS="branch=${BRANCH}&"
  fi
  curl "${curl_attri[@]}" "https://api.github.com/repos/${REPO}/actions/workflows/${WORKFLOW}/runs?${PARAMETERS}status=completed&per_page=${HISTORY}" > "$tmpfile"
  workflow_ids="$(jq '.workflow_runs[].id' < "$tmpfile")"
  echo "${workflow_ids}"
  rm "$tmpfile"
}

workflow_run_ids=
if [ -n "$WORKFLOW_RUN_ID" ]; then
  workflow_run_ids="$WORKFLOW_RUN_ID"
else
  workflow_run_ids=$(get_workflow_run_ids)
fi
echoerr Workflow Run Ids:
echoerr "$workflow_run_ids"
echo "$workflow_run_ids" | while read -r line; do
  get_artifacts_from_workflow "$line"
done
