set -euo pipefail

: "${PAYLOAD_NAME:?Set the Unity artifact name}"
: "${PAYLOAD_STEP:?Set the Unity artifact upload step name}"

workflow_run="repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
payload_prefix="${PAYLOAD_NAME%-$GITHUB_RUN_ATTEMPT}-"
deadline=$((SECONDS + 7800))
printf 'Waiting for %s from this workflow run.\n' "$PAYLOAD_NAME"

while ((SECONDS < deadline)); do
  if artifacts="$(gh api --method GET "$workflow_run/artifacts" -f name="$PAYLOAD_NAME" -F per_page=100)"; then
    artifact_id="$(jq -er --arg name "$PAYLOAD_NAME" '.artifacts[] | select(.name == $name and .expired == false) | .id' <<< "$artifacts")" || artifact_id=
    if [[ "$artifact_id" =~ ^[1-9][0-9]*$ ]]; then
      printf 'artifact-id=%s\n' "$artifact_id" >> "$GITHUB_OUTPUT"
      exit 0
    fi
  fi

  if jobs="$(gh api "$workflow_run/jobs?filter=latest&per_page=100")"; then
    producer="$(jq -c '[.jobs[] | select(.name | endswith(" / Build Android and export iOS") or . == "Build Android and export iOS")] | first // empty' <<< "$jobs")"
    if [[ -n "$producer" ]] && jq -e --arg step "$PAYLOAD_STEP" 'any(.steps[]?; .name == $step and .status == "completed" and .conclusion != "success")' <<< "$producer" >/dev/null; then
      echo "::error::Unity finished without saving the required $PAYLOAD_NAME artifact. See the Unity job."
      exit 1
    fi

    if [[ -n "$producer" ]] && jq -e --arg step "$PAYLOAD_STEP" 'any(.steps[]?; .name == $step and .status == "completed" and .conclusion == "success")' <<< "$producer" >/dev/null; then
      producer_attempt="$(jq -er '.run_attempt' <<< "$producer")"
      if [[ "$producer_attempt" =~ ^[1-9][0-9]*$ && "$producer_attempt" -lt "$GITHUB_RUN_ATTEMPT" ]]; then
        PAYLOAD_NAME="$payload_prefix$producer_attempt"
      fi
    fi
    if [[ -n "$producer" ]] && jq -e --arg step "$PAYLOAD_STEP" '.status == "completed" and (all(.steps[]?; .name != $step))' <<< "$producer" >/dev/null; then
      echo "::error::The Unity job ended before producing $PAYLOAD_NAME."
      exit 1
    fi
  fi
  sleep 20
done

echo "::error::Timed out waiting for $PAYLOAD_NAME."
exit 1
