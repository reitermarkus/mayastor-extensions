#!/usr/bin/env bash

# On a new appTag, update the Chart.yaml which is used to publish the chart to the appropriate
# version and appVersion.
# For this first iteration version and appVersion in the Chart.yaml *MUST* point to the stable
# next release 2.0.0
# When a new appTag is pushed, if it's a prerelease and the prerelease prefix already exists,
# the version is incremented by 1 and the appVersion is set to the appTag.
# If the prerelease prefix is newer (eg: moving on from alpha to beta), then both version and appVersions
# are changed to the appTag.
# If the appTag is a stable release then both version and appVersions are changed to the appTag.

# Write output to error output stream.
echo_stderr() {
  echo -e "${1}" >&2
}

die()
{
  local _return="${2:-1}"
  echo_stderr "$1"
  exit "${_return}"
}

set -euo pipefail

# This uses the existing remote refs for the openebs/mayastor-extensions repo to find the latest 'release/x.y' branch.
# Requires a 'git fetch origin' (origin being the remote entry for openebs/mayastor-extensions) or equivalent, if not
# done already.
latest_release_branch() {
  cd "$ROOTDIR"

  local remote_url=""
  local openebs_remote=""
  for remote in $(git remote show); do
    remote_url=$(git ls-remote --get-url $remote)
    if [[ "$remote_url" =~ ([\/:]openebs\/mayastor-extensions)$ ]]; then
      openebs_remote=$remote
      break
    fi
  done
  if [ -z "$openebs_remote" ]; then
    die "failed to find git remote pointing to 'openebs/mayastor-extensions'"
  fi
  # The latest release branch name is required for generating the helm chart version/appVersion
  # for the 'main' branch only.
  # The 'git branch' command in the below lines checks remote refs for release/x.y branch entries.
  # Because the 'main' branch is not a significant branch for a user/contributor, this approach towards
  # finding the latest release branch assumes that this script is used when the 'openebs/mayastor-extensions'
  # repo is present amongst git remote refs. This happens automatically when the 'openebs/mayastor-extensions'
  # repo is cloned, and not a user/contributor's fork.
  local latest_release_branch=$(git branch \
    --all \
    --list "*${openebs_remote}/release/*.*" \
    --format '%(refname:short)' \
    --sort 'refname' \
    | tail -n 1)

  cd - >/dev/null

  echo "${latest_release_branch#*$openebs_remote/}"
}

main_branch_version_from_release_branch() {
  local release_branch=$1

  # Validate release branch name.
  if ! [[ "$release_branch" =~ ^(release\/[0-9]+\.[0-9]+)$ ]]; then
    die "'$release_branch' is not a valid release branch"
  fi

  # It is possible that this version isn't released, and may never see an actual release.
  # However, it is the latest possible release, and no newer version of a higher semver
  # values likely exists on that repo.
  # Adds a '.0' at the end to make the version semver compliant.
  local latest_version="${release_branch#*release/}".0

  local bumped_latest=""
  # Bump minor by default.
  if [ -n "$BUMP_MAJOR_FOR_MAIN" ]; then
    bumped_latest=$(semver bump major "$latest_version")
  else
    bumped_latest=$(semver bump minor "$latest_version")
  fi

  # Date-time appended to main tag, if present. Else, defaulting to 'main'.
  local penultimate_member=""
  if [ -n "$DATE_TIME" ]; then
    penultimate_member=$DATE_TIME
  else
    penultimate_member="main"
    echo_stderr "WARNING: No input timestamp for main branch helm chart, using 'main' instead"
  fi

  semver bump prerel 0-main-unstable-"$penultimate_member"-0 "$bumped_latest"
}

# Checks if version is semver and removes "v" from the beginning
version()
{
  version="$1"
  name="${2:-"The"}"
  if [ "$(semver validate "$version")" != "valid" ]; then
    die "$name version $version is not a valid semver!"
  fi
  release=$(semver get release "$version")
  prerel=$(semver get prerel "$version")
  if [ "$prerel" == "" ]; then
    echo "$release"
  else
    echo "$release-$prerel"
  fi
}

# Get the expected Chart version for the given branch
# Example:
# For 'develop', the Chart should be x.0.0-develop
# For 'main', if DATE_TIME is not defined then chart should be v0.0.0-main
# Else for 'main', the Chart should be x.0.0-$date-$time, example: v0.0.0-2023-03-30-13-07-40
# For 'release/2.0' the Chart should be 2.0.0
branch_chart_version()
{
  RELEASE_V="${CHECK_BRANCH#release/}"
  if [ "$CHECK_BRANCH" == "develop" ]; then
    # Develop has no meaningful version
    echo "0.0.0"
  elif [ "$CHECK_BRANCH" == "main" ]; then
    if [ -z "$LATEST_RELEASE_BRANCH" ]; then
      LATEST_RELEASE_BRANCH=$(latest_release_branch)
    fi
    # The main branch helm chart appVersion should follow this format: <bumped-latest>-0-develop-unstable-<timestamp>-0
    # If there is no timestamp, then the version defaults to <bumped-latest>-0-develop-unstable-main-0
    # Here 'bumped-latest' is the version obtained when the latest release branch version is bumped
    # as per semver convention. It is by-default a minor version bump, but it could be a major one as well.
    main_branch_version_from_release_branch "$LATEST_RELEASE_BRANCH"
  elif [ "$RELEASE_V" != "${CHECK_BRANCH}" ]; then
    if [ "$(semver validate "$RELEASE_V")" == "valid" ]; then
      echo "$RELEASE_V"
    elif [ "$(semver validate "$RELEASE_V.0")" == "valid" ]; then
      echo "$RELEASE_V.0"
    else
      die "Cannot determine Chart version from branch: $CHECK_BRANCH"
    fi
  else
    die "Cannot determine Chart version from branch: $CHECK_BRANCH"
  fi
}

# Get the version non-numeric prerelease prefix, eg:
# version_prefix 2.0.1-alpha.1 -> 2.0.1-alpha
version_prefix()
{
  version=$(version "$1")
  bump=$(semver bump prerel "$version")
  common=$(grep -zPo '(.*).*\n\K\1' <<< "$version"$'\n'"$bump" | tr -d '\0')
  echo "$common"
}

index_yaml()
{
  if [ -n "$INDEX_FILE" ]; then
    cat "$INDEX_FILE"
  else
    git fetch "$INDEX_REMOTE" "$INDEX_BRANCH" --depth 1 2>/dev/null
    INDEX_FILE_YAML="$(git show "$INDEX_REMOTE"/"$INDEX_BRANCH":"$INDEX_BRANCH_FILE")"
    echo "$INDEX_FILE_YAML"
  fi
}

# yq-go eats up blank lines
# this function gets around that using diff with --ignore-blank-lines
yq_ibl() {
  set +e
  diff_out=$(diff -B <(yq '.' "$2") <(yq "$1" "$2"))
  error=$?
  if [ "$error" != "0" ] && [ "$error" != "1" ]; then
    exit "$error"
  fi
  if [ -n "$diff_out" ]; then
    echo "$diff_out" | patch --quiet "$2" -
  fi
  set -euo pipefail
}

help() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -d, --dry-run                                    Output actions that would be taken, but don't run them.
  -h, --help                                       Display this text.
  --check-chart           <branch>                 Check if the chart version/app version is correct for the branch.
  --develop-to-release                             Also upgrade the chart to the release version matching the branch.
  --develop-to-main                                Also upgrade the chart to the appropriate main branch chart version.
  --app-tag               <tag>                    The appVersion tag.
  --override-index        <latest_version>         Override the latest chart version from the published chart's index.
  --index-file            <index_yaml>             Use the provided index.yaml instead of fetching from the git branch.
  --override-chart        <version> <app_version>  Override the Chart.yaml version and app version.
  --date-time             <date-time>              The date-time in the format +"$DATE_TIME_FMT".
  --latest-release-branch <branch_name>            Set the name of the latest branch when working with the chart from
                                                   the main branch.
  --bump-major-for-main                            Bump latest released GitHub version tag major version for 'main'
                                                   branch, instead of the minor version.

Examples:
  $(basename "$0") --app-tag v2.0.0-alpha.0
EOF
}

SCRIPTDIR="$(dirname "$(realpath "${BASH_SOURCE[0]:-"$0"}")")"
ROOTDIR="$SCRIPTDIR/../.."
CHART_FILE=${CHART_FILE:-"$ROOTDIR/chart/Chart.yaml"}
CHART_VALUES=${CHART_VALUES:-"$ROOTDIR/chart/values.yaml"}
CHART_DOC=${CHART_DOC:-"$ROOTDIR/chart/doc.yaml"}
CHART_NAME="mayastor"
# Tag that has been pushed
APP_TAG=
# Check the Chart.yaml for the given branch
CHECK_BRANCH=
# Version from the Chart.yaml
CHART_VERSION=
# AppVersion from the Chart.yaml
CHART_APP_VERSION=
# Latest "most compatible" (matches CHART_VERSION Mmp) version from the Index
INDEX_LT_VERSION=
INDEX_REMOTE="${INDEX_REMOTE:-origin}"
INDEX_BRANCH="gh-pages"
INDEX_BRANCH_FILE="index.yaml"
INDEX_FILE=
DRY_RUN=
DEVELOP_TO_REL=
DEVELOP_TO_MAIN=
DATE_TIME_FMT="%Y-%m-%d-%H-%M-%S"
DATE_TIME=
IGNORE_INDEX_CHECK=
LATEST_RELEASE_BRANCH=
BUMP_MAJOR_FOR_MAIN=

# Check if all needed tools are installed
semver --version >/dev/null
yq --version >/dev/null

# Parse arguments
while [ "$#" -gt 0 ]; do
  case $1 in
    -d|--dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      help
      exit 0
      ;;
    -c|--check-chart)
      shift
      CHECK_BRANCH=$1
      shift
      ;;
    --develop-to-release)
      DEVELOP_TO_REL=1
      shift
      ;;
    --develop-to-main)
      DEVELOP_TO_MAIN=1
      shift
      ;;
    --app-tag)
      shift
      APP_TAG=$1
      shift
      ;;
    --override-index)
      shift
      INDEX_LT_VERSION=$1
      if [ -z "$INDEX_LT_VERSION" ]; then
        IGNORE_INDEX_CHECK="y"
      fi
      shift
      ;;
    --index-file)
      shift
      INDEX_FILE=$1
      shift
      ;;
    --override-chart)
      shift
      CHART_VERSION=$1
      shift
      CHART_APP_VERSION=$1
      shift
      ;;
    --date-time)
      shift
      DATE_TIME=$1
      shift
      ;;
    --latest-release-branch)
      shift
      LATEST_RELEASE_BRANCH=$1
      shift
      ;;
    --bump-major-for-main)
      BUMP_MAJOR_FOR_MAIN=1
      shift
      ;;
    *)
      help
      die "Unknown option: $1"
      ;;
  esac
done

if [ -n "$INDEX_FILE" ]; then
  test -f "$INDEX_FILE" || die "Index file ($INDEX_FILE) not found"
fi

if [ -z "$CHART_VERSION" ]; then
  CHART_VERSION=$(yq '.version' "$CHART_FILE")
fi
if [ -z "$CHART_APP_VERSION" ]; then
  CHART_APP_VERSION=$(yq '.appVersion' "$CHART_FILE")
fi

CHART_VERSION=$(version "$CHART_VERSION")
CHART_APP_VERSION=$(version "$CHART_APP_VERSION")

if [ -n "$CHECK_BRANCH" ]; then
  # It's ok to leave out the timestamp for a --check-chart, but not for a --develop-to-main.
  if [ -n "$DEVELOP_TO_MAIN" ] && [ -z "$DATE_TIME" ]; then
    die "ERROR: No date-time input for main branch helm chart version"
  fi
  APP_TAG=$(branch_chart_version "$CHECK_BRANCH")
else
  if [ -z "$APP_TAG" ]; then
    die "--app-tag not specified"
  fi
  APP_TAG=$(version "$APP_TAG")
fi

echo "APP_TAG: $APP_TAG"
echo "CHART_VERSION: $CHART_VERSION"
echo "CHART_APP_VERSION: $CHART_APP_VERSION"

if [ "$CHECK_BRANCH" = "main" ]; then
  allowed_diff=("" "major" "minor" "patch" "prerelease")
else
  # Allow only for a semver difference of at most patch
  allowed_diff=("" "patch" "prerelease")
fi


diff="$(semver diff "$CHART_VERSION" "$CHART_APP_VERSION")"
if ! [[ " ${allowed_diff[*]} " =~ " $diff " ]]; then
  die "Difference($diff) between CHART_VERSION($CHART_VERSION) CHART_APP_VERSION($CHART_APP_VERSION) not allowed!"
fi

if [ -n "$CHECK_BRANCH" ]; then
  if [ "$(semver get prerel "$APP_TAG")" != "" ]; then
    if [ ! "$CHECK_BRANCH" == "main" ]; then
        die "Script expects Branch Name($APP_TAG) to point to a stable release"
    fi
  fi
  if [ -n "$DEVELOP_TO_MAIN" ]; then
    # Verify if develop.
    if [ "$CHART_VERSION" = "0.0.0" ]; then
      newChartVersion="$APP_TAG"
      newChartAppVersion="$APP_TAG"
      echo "NEW_CHART_VERSION: $newChartVersion"
      echo "NEW_CHART_APP_VERSION: $newChartAppVersion"

      if [ -z "$DRY_RUN" ]; then
        sed -i "s/^version:.*$/version: $newChartVersion/" "$CHART_FILE"
        sed -i "s/^appVersion:.*$/appVersion: \"$newChartAppVersion\"/" "$CHART_FILE"
        # Set image tag to empty because main branch uses repoTags.
        yq_ibl '.image.tag |= ""' "$CHART_VALUES"
        # always pull since image changes with commits to the branch
        yq_ibl ".image.pullPolicy |= \"IfNotPresent\"" "$CHART_VALUES"
        yq_ibl ".chart.version |= \"$newChartVersion\"" "$CHART_DOC"
      fi
    else
      die "ERROR: source chart is not from develop branch"
    fi
    exit 0
  elif [ -n "$DEVELOP_TO_REL" ]; then
    if [ "$CHART_VERSION" == "0.0.0" ]; then
      newChartVersion="$APP_TAG"
      newChartAppVersion="$APP_TAG"
      echo "NEW_CHART_VERSION: $newChartVersion"
      echo "NEW_CHART_APP_VERSION: $newChartAppVersion"

      if [ -z "$DRY_RUN" ]; then
        sed -i "s/^version:.*$/version: $newChartVersion/" "$CHART_FILE"
        sed -i "s/^appVersion:.*$/appVersion: \"$newChartAppVersion\"/" "$CHART_FILE"
        # point image tag to the release branch images
        yq_ibl ".image.tag |= \"${CHECK_BRANCH////-}\"" "$CHART_VALUES"
        # always pull since image changes with commits to the branch
        yq_ibl ".image.pullPolicy |= \"Always\"" "$CHART_VALUES"
        yq_ibl ".chart.version |= \"$newChartVersion\"" "$CHART_DOC"
      fi
    else
      die "ERROR: source chart is not from develop branch"
    fi
    exit 0
  fi
fi

diff="$(semver diff "$APP_TAG" "$CHART_APP_VERSION")"
if ! [[ " ${allowed_diff[*]} " =~ " $diff " ]]; then
  die "Difference($diff) between APP_TAG($APP_TAG) CHART_APP_VERSION($CHART_APP_VERSION) not allowed!"
fi

[ -n "$CHECK_BRANCH" ] && exit 0

if [ "$(semver get prerel "$CHART_VERSION")" != "" ]; then
  die "Script expects CHART_VERSION($CHART_VERSION) to point to the future stable release"
fi
if [ "$(semver get prerel "$CHART_APP_VERSION")" != "" ]; then
  die "Script expects CHART_APP_VERSION($CHART_APP_VERSION) to point to the future stable release"
fi

if [ -z "$IGNORE_INDEX_CHECK" ]; then
  if [ -z "$INDEX_LT_VERSION" ]; then
    INDEX_FILE_YAML=$(index_yaml)
    len_versions="$(echo "$INDEX_FILE_YAML" | yq ".entries.${CHART_NAME} | length")"
    INDEX_VERSIONS=""
    if [ "$len_versions" != "0" ]; then
      INDEX_VERSIONS="$(echo "$INDEX_FILE_YAML" | yq ".entries.${CHART_NAME}[].version")"
    fi
  else
    INDEX_VERSIONS="$INDEX_LT_VERSION"
    INDEX_LT_VERSION=
  fi

  version_prefix=$(version_prefix "$APP_TAG")
  INDEX_CHART_VERSIONS=$(echo "$INDEX_VERSIONS" | grep "$version_prefix" || echo)
  if [ "$INDEX_CHART_VERSIONS" != "" ]; then
    INDEX_LT_VERSION=$(echo "$INDEX_CHART_VERSIONS" | sort -r | head -n1)
  fi

  if [ "$(echo "$INDEX_VERSIONS" | grep -x "$APP_TAG" || echo)" == "$APP_TAG" ] && [ "$(semver get prerel "$APP_TAG")" == "" ]; then
    die "A stable chart version $APP_TAG matching the app tag is already in the index. What should I do?"
  fi

  if [ -n "$INDEX_LT_VERSION" ]; then
    INDEX_LT_VERSION=$(version "$INDEX_LT_VERSION" "Latest index")
    # If the latest index that matches ours is a release
    if [ "$(semver get prerel "$INDEX_LT_VERSION")" == "" ]; then
      die "A stable chart version $INDEX_LT_VERSION is already in the index. What should I do?"
    fi
  fi
fi

if [ "$(semver get prerel "$APP_TAG")" == "" ]; then
  # It's the stable release!
  newChartVersion="$APP_TAG"
  newChartAppVersion="$APP_TAG"
else
  if [ "$INDEX_LT_VERSION" == "" ]; then
    # The first pre-release starts with the app tag
    newChartVersion="$APP_TAG"
  else
    # if the app tag is newer than the index, bump the index to the app tag
    if [ "$(semver compare "$INDEX_LT_VERSION" "$APP_TAG")" == "-1" ]; then
      newChartVersion="$APP_TAG"
    else
      newChartVersion=$(semver bump prerel "$INDEX_LT_VERSION")
    fi
  fi

  newChartAppVersion="$APP_TAG"
fi

echo "NEW_CHART_VERSION: $newChartVersion"
echo "NEW_CHART_APP_VERSION: $newChartAppVersion"

if [ -z "$DRY_RUN" ]; then
  sed -i "s/^version:.*$/version: $newChartVersion/" "$CHART_FILE"
  sed -i "s/^appVersion:.*$/appVersion: \"$newChartAppVersion\"/" "$CHART_FILE"
  yq_ibl ".image.tag |= \"v$newChartAppVersion\"" "$CHART_VALUES"
  # tags are stable so we don't need to pull always
  yq_ibl ".image.pullPolicy |= \"IfNotPresent\"" "$CHART_VALUES"
  yq_ibl ".chart.version |= \"$newChartVersion\"" "$CHART_DOC"
fi
