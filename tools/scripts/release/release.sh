#!/usr/bin/env bash
set -ex

if [[ -z $GITHUB_USERNAME ]]; then
  echo "Please set your github username"
  exit 1
fi

owner="build-trust"
release_name="release_$(date +'%d-%m-%Y')_$(date +'%s')"

if [[ -z $RECENT_FAILURE ]]; then
  RECENT_FAILURE=false
fi

function approve_deployment() {
  set -e
  local repository="$1"
  local run_id="$2"
  local runner=$(date +'%s')

  # completed waiting queued in_progress
  while true; do
    status=$(gh api -H "Accept: application/vnd.github+json" /repos/$owner/$repository/actions/runs/$run_id | jq -r '.status')
    if [[ $status == "completed" ]]; then
      echo "Run ID $run_id completed"
      return
    elif [[ $status == "waiting" ]]; then
      # Get actions that need to be approved
      pending_deployments=$(gh api -H "Accept: application/vnd.github+json" /repos/$owner/$repository/actions/runs/$run_id/pending_deployments)
      pending_length=$(echo "$pending_deployments" | jq '. | length')

      environments=""
      for (( c=0; c<$pending_length; c++ )); do
        environment=$(echo "$pending_deployments" | jq -r ".[$c].environment.id" )
        environments="$environments $environment"
      done

      if [[ ! -z $environments ]]; then
        jq -n  "{environment_ids: [$environments], state: \"approved\", comment: \"Ship It\"}" | gh api \
          --method POST \
          -H "Accept: application/vnd.github+json" \
          /repos/$owner/$repository/actions/runs/$run_id/pending_deployments --input -
      fi
      sleep 120
    else
      sleep 120
      continue
    fi
  done
}

function ockam_bump() {
  set -e
  gh workflow run create-release-pull-request.yml --ref develop\
    -F branch_name="$release_name" -F git_tag="$GIT_TAG" -F modified_release="$MODIFIED_RELEASE"\
    -F release_version="$RELEASE_VERSION" -F bumped_dep_crates_version="$BUMPED_DEP_CRATES_VERSION"\
    -R $owner/ockam

  workflow_file_name="create-release-pull-request.yml"
  # Sleep for 10 seconds to ensure we are not affected by Github API downtime.
  sleep 10
  # Wait for workflow run
  run_id=$(gh run list --workflow="$workflow_file_name" -b develop -u $GITHUB_USERNAME -L 1 -R $owner/ockam --json databaseId | jq -r .[0].databaseId)

  approve_deployment "ockam" $run_id &
  gh run watch $run_id --exit-status -R $owner/ockam

  # Merge PR to a new branch to kickstart workflow
  gh pr create --title "Ockam Release $(date +'%d-%m-%Y')" --body "Ockam release"\
    --base develop -H ${release_name} -r mrinalwadhwa -R $owner/ockam
}

function ockam_crate_release() {
  set -e
  gh workflow run publish-crates.yml --ref develop \
    -F release_branch="$release_name" -F git_tag="$GIT_TAG" -F exclude_crates="$EXCLUDE_CRATES" \
    -F recent_failure="$RECENT_FAILURE" -R $owner/ockam
  # Sleep for 10 seconds to ensure we are not affected by Github API downtime.
  sleep 10
  # Wait for workflow run
  run_id=$(gh run list --workflow=publish-crates.yml -b develop -u $GITHUB_USERNAME -L 1 -R $owner/ockam --json databaseId | jq -r .[0].databaseId)

  approve_deployment "ockam" $run_id &
  gh run watch $run_id --exit-status -R $owner/ockam
}

function release_ockam_binaries() {
  set -e
  gh workflow run release-binaries.yml --ref develop -F git_tag="$GIT_TAG" -F release_branch="$release_name" -R $owner/ockam
  # Wait for workflow run
  sleep 10
  run_id=$(gh run list --workflow=release-binaries.yml -b develop -u $GITHUB_USERNAME -L 1 -R $owner/ockam --json databaseId | jq -r .[0].databaseId)

  approve_deployment "ockam" $run_id &
  gh run watch $run_id --exit-status -R $owner/ockam
}

function release_ockam_package() {
  set -e
  tag="$1"
  file_and_sha="$2"
  is_release="$3"


  gh workflow run ockam-package.yml --ref develop -F tag="$tag" -F binaries_sha="$file_and_sha" -F is_release=$is_release  -R $owner/ockam
  # Wait for workflow run
  sleep 10
  run_id=$(gh run list --workflow=ockam-package.yml -b develop -u $GITHUB_USERNAME -L 1 -R $owner/ockam --json databaseId | jq -r .[0].databaseId)

  approve_deployment "ockam" $run_id &
  gh run watch $run_id --exit-status -R $owner/ockam
}

function homebrew_repo_bump() {
  set -e
  tag=$1
  file_and_sha=$2

  gh workflow run create-release-pull-request.yml --ref main -F binaries="$file_and_sha" -F branch_name="$release_name" -F tag=$tag -R $owner/homebrew-ockam
  # Wait for workflow run
  sleep 10
  run_id=$(gh run list --workflow=create-release-pull-request.yml -b main -u $GITHUB_USERNAME -L 1 -R $owner/homebrew-ockam --json databaseId | jq -r .[0].databaseId)

  approve_deployment "homebrew-ockam" $run_id &
  gh run watch $run_id --exit-status -R $owner/homebrew-ockam

  # Create PR to kickstart workflow
  gh pr create --title "Ockam Release $(date +'%d-%m-%Y')" --body "Ockam release"\
    --base main -H ${release_name} -r mrinalwadhwa -R $owner/homebrew-ockam
}

function terraform_repo_bump() {
  set -e
  gh workflow run create-release-pull-request.yml --ref main -R $owner/terraform-provider-ockam -F tag=$1 -F branch_name=$release_name
  # Wait for workflow run
  sleep 10
  run_id=$(gh run list --workflow=create-release-pull-request.yml -b main -u $GITHUB_USERNAME -L 1 -R $owner/terraform-provider-ockam  --json databaseId | jq -r .[0].databaseId)

  approve_deployment "terraform-provider-ockam" $run_id &
  gh run watch $run_id --exit-status -R $owner/terraform-provider-ockam

  # Create PR to kickstart workflow
  gh pr create --title "Ockam Release $(date +'%d-%m-%Y')" --body "Ockam release"\
    --base main -H ${release_name} -r mrinalwadhwa -R $owner/terraform-provider-ockam
}

function terraform_binaries_release() {
  set -e
  gh workflow run release.yml --ref main -R $owner/terraform-provider-ockam -F tag=$1
  # Wait for workflow run
  sleep 10
  run_id=$(gh run list --workflow=release.yml -b main -u $GITHUB_USERNAME -L 1 -R $owner/terraform-provider-ockam  --json databaseId | jq -r .[0].databaseId)

  approve_deployment "terraform-provider-ockam" $run_id &
  gh run watch $run_id --exit-status -R $owner/terraform-provider-ockam
}

function delete_ockam_draft_package() {
  set -e
  versions=$(gh api -H "Accept: application/vnd.github+json" /orgs/build-trust/packages/container/ockam/versions)
  version_length=$(echo "$versions" | jq '. | length')

  for (( c=0; c<$version_length; c++ )); do
    id=$(echo "$versions" | jq -r ".[$c].id")

    tags=$(echo "$versions" | jq ".[$c].metadata.container.tags")
    tags_length=$(echo "$tags" | jq ". | length")

    for (( d=0; d<$tags_length; d++ )); do
      tag_name=$(echo "$tags" | jq -r ".[$d]")

      if [[ $tag_name == *"-draft"* ]]; then
        echo -n | gh api \
          --method DELETE \
          -H "Accept: application/vnd.github+json" \
          /orgs/$owner/packages/container/ockam/versions/$id --input -
        break
      fi
    done
  done
}

function dialog_info() {
  echo -e "\033[01;33m$1\033[00m"
  read -p ""
}

function success_info() {
  echo -e "\033[01;32m$1\033[00m"
}

#------------------------------------------------------------------------------------------------------------------------------------------------------------------#

if [[ -z $SKIP_OCKAM_BUMP || $SKIP_OCKAM_BUMP == false ]]; then
  ockam_bump
  success_info "Crate bump pull request created.... Starting Ockam crates.io publish."
fi

if [[ -z $SKIP_OCKAM_BINARY_RELEASE || $SKIP_OCKAM_BINARY_RELEASE == false ]]; then
  release_ockam_binaries
  success_info "Draft release has been created.... Starting Homebrew release."
fi

# Get latest tag
if [[ -z $LATEST_TAG_NAME ]]; then
  latest_tag_name=$(gh api -H "Accept: application/vnd.github+json" /repos/$owner/ockam/releases | jq -r .[0].tag_name)
  if [[ $latest_tag_name != *"ockam_v"* ]]; then
    echo "Invalid Git Tag gotten"
  fi

  success_info "Latest tag is $latest_tag_name press enter if correct"
else
  latest_tag_name="$LATEST_TAG_NAME"
fi

# Get File hash from draft release
file_and_sha=""

temp_dir=$(mktemp -d)
pushd $temp_dir
gh release download $latest_tag_name -R $owner/ockam

# TODO Ensure that SHA are cosign verified
while read -r line; do
  file=($line)
  if [[ ${file[1]} == *".so"* || ${file[1]} == *".sig"* ]]; then
    continue
  fi

  file_and_sha="$file_and_sha ${file[1]}:${file[0]}"
done < sha256sums.txt
popd
rm -rf /tmp/$release_name

echo "File and hash are $file_and_sha"

if [[ -z $SKIP_OCKAM_PACKAGE_DRAFT_RELEASE || $SKIP_OCKAM_PACKAGE_DRAFT_RELEASE  == false ]]; then
  release_ockam_package $latest_tag_name "$file_and_sha" false
  success_info "Ockam package draft release successful.... Starting Homebrew release"
fi

# Homebrew Release
if [[ -z $SKIP_HOMEBREW_BUMP || $SKIP_HOMEBREW_BUMP == false ]]; then
  homebrew_repo_bump $latest_tag_name "$file_and_sha"
  success_info "Homebrew release successful.... Starting Terraform Release"
fi

if [[ -z $SKIP_TERRAFORM_BUMP || $SKIP_TERRAFORM_BUMP == false ]]; then
  terraform_repo_bump $latest_tag_name
fi

if [[ -z $SKIP_TERRAFORM_BINARY_RELEASE || $SKIP_TERRAFORM_BINARY_RELEASE == false ]]; then
  terraform_binaries_release $latest_tag_name
fi

dialog_info "Please vet ockam, docker, homebrew and terraform release... Press Enter to merge all changes."

# Release Ockam Github release
if [[ -z $SKIP_OCKAM_DRAFT_RELEASE || $SKIP_OCKAM_DRAFT_RELEASE == false ]]; then
  gh release edit $latest_tag_name --draft=false -R $owner/ockam
fi

# Release Terraform Github release
if [[ -z $SKIP_TERRAFORM_DRAFT_RELEASE || $SKIP_TERRAFORM_DRAFT_RELEASE == false ]]; then
  terraform_tag=${latest_tag_name:6}
  gh release edit $terraform_tag --draft=false -R $owner/terraform-provider-ockam
fi

# Release Ockam package
if [[ -z $SKIP_OCKAM_PACKAGE_RELEASE || $SKIP_OCKAM_PACKAGE_RELEASE  == false ]]; then
  release_ockam_package $latest_tag_name "$file_and_sha" true
  success_info "Ockam package release successful."
fi

delete_ockam_draft_package

if [[ -z $SKIP_CRATES_IO_PUBLISH || $SKIP_CRATES_IO_PUBLISH == false ]]; then
  ockam_crate_release
  success_info "Crates.io publish successful.... Starting Ockam binary release."
fi

success_info "Release Done 🚀🚀🚀"
exit 0
