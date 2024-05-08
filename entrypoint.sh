#!/bin/sh -l

set -ex

if [ -n "$INPUT_PATH" ]; then
  # Allow user to change directories in which to run Fly commands.
  cd "$INPUT_PATH" || exit
fi

PR_NUMBER=$(jq -r .number /github/workflow/event.json)
if [ -z "$PR_NUMBER" ]; then
  echo "This action only supports pull_request actions."
  exit 1
fi

REPO_OWNER=$(jq -r .event.base.repo.owner /github/workflow/event.json)
REPO_NAME=$(jq -r .event.base.repo.name /github/workflow/event.json)
EVENT_TYPE=$(jq -r .action /github/workflow/event.json)

# Default the Fly app name to pr-{number}-{repo_owner}-{repo_name}
app="${INPUT_APP:-${FLY_APP:-pr-$PR_NUMBER-$REPO_OWNER-$REPO_NAME}}"
region="${INPUT_REGION:-${FLY_REGION:-iad}}"
org="${INPUT_ORG:-${FLY_ORG:-personal}}"
image="$INPUT_IMAGE"
config="$INPUT_CONFIG"
vm="${INPUT_VM:-shared-cpu-1x}"
ha="${INPUT_HA:-false}"

# Prepare the args
args=$(echo "$INPUT_ARGS" | sed '/^[[:space:]]*$/d' | sed 's/\(.*\)/ --build-arg \1 / ' | sed 's/^ *//')
args=$(echo "$args" | tr -d '\n')

if ! echo "$app" | grep "$PR_NUMBER"; then
  echo "For safety, this action requires the app's name to contain the PR number."
  exit 1
fi

# PR was closed - remove the Fly app if one exists and exit.
if [ "$EVENT_TYPE" = "closed" ]; then
  flyctl apps destroy "$app" -y || true
  exit 0
fi

# Ensure deployment is triggered if app is not available
if [ "$INPUT_UPDATE" = "false" ]; then
  if ! flyctl status --app "$app"; then
    INPUT_UPDATE="true"
  fi
fi

# Create Fly App
if ! flyctl status --app "$app"; then
  cp "$config" "$config.backup"
  flyctl launch --no-deploy --copy-config --name "$app" --image "$image" --regions "$region" --org "$org" --ha="$ha" --vm-size="$vm" $args
  cp "$config.backup" "$config"
fi

# Import secrets
if [ -n "$INPUT_SECRETS" ]; then
  echo $INPUT_SECRETS | tr " " "\n" | flyctl secrets import --app "$app"
fi

# Attach postgres cluster to the app if specified.
if [ -n "$INPUT_POSTGRES" ]; then
  flyctl postgres attach -a $app -y "$INPUT_POSTGRES" || true
fi

# Deploy the Fly App
if [ "$INPUT_UPDATE" != "false" ]; then
  flyctl deploy --config "$config" --app "$app" --image "$image" --regions "$region" --strategy immediate --ha="$ha" --vm-size="$vm" $args
fi

# Make some info available to the GitHub workflow.
fly status --app "$app" --json >status.json
hostname=$(jq -r .Hostname status.json)
appid=$(jq -r .ID status.json)
echo "app=$app" >> $GITHUB_OUTPUT
echo "hostname=$hostname" >> $GITHUB_OUTPUT
echo "url=https://$hostname" >> $GITHUB_OUTPUT
echo "id=$appid" >> $GITHUB_OUTPUT
