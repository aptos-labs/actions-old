#!/bin/bash
function echoerr() {
  cat <<< "$@" 1>&2;
}

#Check prerequists.
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
  echoerr -t token used to communicate with github actions.
  echoerr -h number of workflow_runs to pull artifacts from.
  echoerr -a space seperated list of artifact names.
  echoerr -b optional branch to pull historical artifacts from.
  echoerr -w workflow file name of of workflow to pull artifact from.
  echoerr -d target directory where subdirectories for jobs will be created and artifacts will be unzip to.
  echoerr -i the single job to artifacts from.  Overrides -b,-w, and -h
  echoerr -z decompress and delete the original downloaded artifacts?
  echoerr -? this message.
  echoerr output will written in to the -t target directory.
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
  echoerr target directory must be sepecified.
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

# Retry seems to add a lot of time overhead.  Need to look in to this more.
# curl_attri=("--retry" "3")
curl_attri=('-H' 'Accept: application/vnd.github.v3+json')
if [ -n "$TOKEN" ]; then
  curl_attri+=('-H' "authorization: Bearer ${TOKEN}")
fi
echoerr Curl Parameters: "${curl_attri[@]}"


# Conditionally retrieves the artifacts from a single jobs, the input parameter which must correspond to a numeric workflow_run_id in github actions
# and stores the desired artifacts, contained in a list called "ARTIFACTS", in a subdirectory of TARGET_DIR, equal to the workflow_run_id/artifact_name.
# Artifacts are always zips.   The zip file is downloaded and optionally unziped in to the job's sub directory in the TARGET_DIR, and then deleted.
# Should the <job dir>/<artifact_name> already exist, no downloads are attempted, as the assumption would be this function has already populated the
# artifacts in to the job dir.
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
getArtifactsFromJob() {
  jobId=$1;
  echoerr getting artifacts for jobId "$jobId"
  artifact_info="$(curl "${curl_attri[@]}" "https://api.github.com/repos/${REPO}/actions/runs/${jobId}/artifacts"  2>/dev/null)"
  for artifact_name in "${ARTIFACTS[@]}"; do
    if [ ! -d "${TARGET_DIR}/${jobId}/${artifact_name}" ]; then
      mkdir -p "${TARGET_DIR}/${jobId}/${artifact_name}"
      download_url_str="$(echo "$artifact_info" | jq '.artifacts[] | select(.name=="'"${artifact_name}"'") .archive_download_url')"
      if [ -n "$download_url_str" ] && [ "$download_url_str" != "null" ]; then
        download_url="${download_url_str//\"/}"
        curl -L "${curl_attri[@]}" "$download_url" -o "${TARGET_DIR}/${jobId}/${artifact_name}/${artifact_name}.zip" 2>/dev/null
        if [ "$DECOMPRESS" = "true" ]; then
          unzip -q "${TARGET_DIR}/${jobId}/${artifact_name}/${artifact_name}.zip" -d "${TARGET_DIR}/${jobId}/${artifact_name}/"
          rm "${TARGET_DIR}/${jobId}/${artifact_name}/${artifact_name}.zip"
        fi
      else
        echoerr Artifact not found on workflow run: "${jobId}" with contents:
        echoerr "$artifact_info"
      fi
    fi
  done
  echoerr fetched:
  echoerr "$(ls -d "${TARGET_DIR}/${jobId}/"*/*)"
}

#
# Given a REPO, WORKFLOW and (optional) BRANCH, get HISTORY number of prior run artifacts return output workflow_run_ids, one per line.
#
getWorkflow_Run_Ids() {
  #Always using temp files for curl output to prevent shell mangling.
  tmpfile=$(mktemp /tmp/get_reports.XXXXXX)
  PARAMETERS=
  if [ -n "$BRANCH" ]; then
    PARAMETERS="branch=${BRANCH}&"
  fi
  curl "${curl_attri[@]}" "https://api.github.com/repos/${REPO}/actions/workflows/${WORKFLOW}/runs?${PARAMETERS}status=completed&per_page=${HISTORY}" 2>/dev/null > "$tmpfile"
  workflow_ids="$(jq '.workflow_runs[].id' < "$tmpfile")"
  echo "${workflow_ids}"
}

workflow_run_ids=
if [ -n "$WORKFLOW_RUN_ID" ]; then
  workflow_run_ids="$WORKFLOW_RUN_ID"
else
  workflow_run_ids=$(getWorkflow_Run_Ids)
fi
echoerr Workflow Ids:
echoerr "$workflow_run_ids"
echo "$workflow_run_ids" | while read -r line; do
  getArtifactsFromJob "$line"
done
