#!/bin/bash
set -euo pipefail

# This library processes Bazel Event Protocol output and creates Buildkite annotations

# Function to get random quote for annotation footer
get_random_quote() {
  local quotes=(
    "\"The best error message is the one that never shows up.\" - Thomas Fuchs"
    "\"First, solve the problem. Then, write the code.\" - John Johnson"
    "\"Make it work, make it right, make it fast.\" - Kent Beck"
    "\"Programming isn't about what you know; it's about what you can figure out.\" - Chris Pine"
    "\"The only way to learn a new programming language is by writing programs in it.\" - Dennis Ritchie"
    "\"Testing can only prove the presence of bugs, not their absence.\" - Edsger W. Dijkstra"
    "\"It's not a bug – it's an undocumented feature.\" - Anonymous"
    "\"Good code is its own best documentation.\" - Steve McConnell"
    "\"Any fool can write code that a computer can understand. Good programmers write code that humans can understand.\" - Martin Fowler"
    "\"The sooner you start to code, the longer the program will take.\" - Roy Carlson"
    "\"Optimism is an occupational hazard of programming; feedback is the treatment.\" - Kent Beck"
    "\"Simplicity is the soul of efficiency.\" - Austin Freeman"
  )
  echo "${quotes[RANDOM % ${#quotes[@]}]}"
}

# Function to create a Buildkite annotation with the given style and content
create_annotation() {
  local style="$1"
  local content="$2"
  local context_id="bazel-bep-results"
  local job_name="${BUILDKITE_LABEL:-Unknown Job}"
  local is_first_job="${BUILDKITE_PLUGIN_BAZEL_ANNOTATE_IS_FIRST_JOB:-true}"

  if [ -n "${BUILDKITE:-}" ] && command -v buildkite-agent >/dev/null 2>&1; then
    if [ "$is_first_job" != "true" ]; then
      content=$(echo "$content" | sed '1,3d')
      content="### 🧩 ${job_name}\n\n${content}"
    fi
    printf "%s" "$content" | buildkite-agent annotate --style "$style" --context "$context_id" --append
    if ! buildkite-agent meta-data exists "bazel-annotate-header-created" 2>/dev/null; then
      buildkite-agent meta-data set "bazel-annotate-header-created" "true" || true
    fi
  else
    echo "Not running in Buildkite. Would create annotation with style '$style':"
    printf "%s" "$content"
  fi
}

# Optimized BEP processor
process_bep() {
  local BEP_FILE="$1"
  [[ ! -f "$BEP_FILE" || ! -s "$BEP_FILE" ]] && echo "⚠ Skipping annotation: BEP file missing or empty: $BEP_FILE" && return 0

  jq -c '
    select(
      (.id.testResult? != null) or
      (.id.targetCompleted? != null) or
      (.id.configured? != null) or
      (.id.buildStarted? != null) or
      (.id.buildFinished? != null) or
      (.id.targetSkipped? != null)
    )
  ' build_events.json > filtered_bep.json


  BEP_FILE="filtered_bep.json"

  local success_count=0 fail_count=0 skip_count=0 cached_count=0
  local build_start_time=0 build_end_time=0
  local -A seen_tests
  local -a successful_targets slowest_tests slowest_times
  local failure_details=""

  while IFS= read -r json; do
    local kind
    kind=$(jq -r 'keys_unsorted[0]' <<< "$json")

    case "$kind" in
      id)
        if jq -e '.buildStarted != null' <<< "$json" >/dev/null; then
          build_start_time=$(jq -r '.buildStarted.startTimeMillis // 0' <<< "$json")
        elif jq -e '.buildFinished != null' <<< "$json" >/dev/null; then
          build_end_time=$(jq -r '.buildFinished.finishTimeMillis // 0' <<< "$json")
        elif jq -e '.targetSkipped != null' <<< "$json" >/dev/null; then
          ((skip_count++))
        elif jq -e '.targetCompleted != null' <<< "$json" >/dev/null; then
          local label=$(jq -r '.id.targetCompleted.label // "unknown"' <<< "$json")
          local success=$(jq -r '.completed.success // "false"' <<< "$json")
          if jq -e '.completed.outputGroup?[]?.fileSets?[]?.id? != null' <<< "$json" >/dev/null 2>&1 && \
             ! jq -e '.completed.actionExecuted? != null' <<< "$json" >/dev/null 2>&1; then
            ((cached_count++))
          fi
          if [[ "$success" == "true" ]]; then
            ((success_count++))
            successful_targets+=("$label")
          else
            ((fail_count++))
            local errors=$(jq -r '.completed.failureDetail.message // "Unknown error"' <<< "$json")
            failure_details+=$'### ❌ Failed: '"$label"$'\n\n```diff\n- ERROR: '"$errors"$'\n```\n\n'
            if grep -qE "no such target|no such package|Package is considered deleted" <<< "$errors"; then
              local detail=$(grep -oE "'[^']*'|Package [^:]*" <<< "$errors" | head -1)
              failure_details+=$'**🔍 Possible Fix:** '"$detail"$' might be missing, renamed, or deleted.\n\n'
            fi
          fi
        elif jq -e '.configured != null' <<< "$json" >/dev/null; then
          local label=$(jq -r '.id.configured.targetLabel // "unknown"' <<< "$json")
          [[ " ${successful_targets[*]} " != *" $label "* ]] && ((success_count++)) && successful_targets+=("$label")
        elif jq -e '.testResult != null' <<< "$json" >/dev/null; then
          local test_label=$(jq -r '.id.testResult.label // "unknown"' <<< "$json")
          [[ -n "${seen_tests[$test_label]+x}" ]] && continue
          seen_tests["$test_label"]=1

          local test_status=$(jq -r '.testResult.status // "UNKNOWN"' <<< "$json")
          local test_time=$(jq -r '.testResult.testActionDurationMillis // 0' <<< "$json")
          ((test_time == 0)) && test_time=1000
          local secs=$(bc <<<"scale=2; $test_time/1000")

          [[ "$test_status" == "PASSED" ]] && ((success_count++)) && successful_targets+=("$test_label (test)")
          [[ "$test_status" == "FLAKY" ]] && ((success_count++)) && successful_targets+=("$test_label (⚠️ flaky)")
          [[ "$test_status" != "PASSED" && "$test_status" != "FLAKY" ]] && ((fail_count++))

          slowest_tests+=("$test_label")
          slowest_times+=("$secs")

          if [[ "$test_status" != "PASSED" ]]; then
            local test_errors="No detailed logs available"
            jq -e '.testResult.testActionOutput? != null' <<< "$json" >/dev/null 2>&1 && \
              test_errors=$(jq -r '.testResult.testActionOutput[]? | .name + ": " + .uri' <<< "$json")
            local emoji="❌"
            [[ "$test_status" == "FLAKY" ]] && emoji="⚠️"
            [[ "$test_status" == "TIMEOUT" ]] && emoji="⏱️"
            failure_details+=$'### '"$emoji"$' Failed Test: '"$test_label"$' ('"$test_status"$') in '"${secs}s"$'\n\n```diff\n- '"$test_errors"$'\n```\n\n'
            if jq -e '.testResult.testActionOutput[]? | select(.name == "test.log")' <<< "$json" >/dev/null 2>&1; then
              local log_uri=$(jq -r '.testResult.testActionOutput[] | select(.name == "test.log") | .uri' <<< "$json")
              failure_details+=$'[View Full Test Log]('"$log_uri"$')\n\n'
            fi
          fi
        fi
        ;;
    esac
  done < <(jq -c 'select((.aborted?.reason != "SKIPPED") and (.id != null))' "$BEP_FILE")

  local duration=0
  ((build_end_time > 0 && build_start_time > 0)) && duration=$(( (build_end_time - build_start_time) / 1000 ))

  local style="info"
  [[ $fail_count -gt 0 ]] && style="error"

  local summary="### ${BUILDKITE_LABEL:-Bazel Results}\n\n"
  ((duration > 0)) && summary+="**⏱️ Duration:** ${duration}s | "
  summary+="**Status:** ✅ $success_count"
  ((cached_count > 0)) && summary+=" | 🔄 $cached_count cached"
  ((fail_count > 0)) && summary+=" | ❌ $fail_count failed"
  ((skip_count > 0)) && summary+=" | ⏭️ $skip_count skipped"
  summary+="\n\n"

if ((${#slowest_tests[@]})); then
  summary+="<details><summary><strong>⏱️ Test Durations</strong> (${#slowest_tests[@]} tests)</summary>\n\n"
  for i in $(seq 0 $((${#slowest_tests[@]} - 1))); do
    summary+="- \`${slowest_tests[$i]}\`: ${slowest_times[$i]}s\n"
    [[ $i -ge 9 ]] && {
      [[ ${#slowest_tests[@]} -gt 10 ]] && summary+="- _...and $((${#slowest_tests[@]} - 10)) more_\n"
      break
    }
  done
  summary+="</details>\n"
fi

if ((${#successful_targets[@]})); then
  mapfile -t successful_targets < <(printf "%s\n" "${successful_targets[@]}" | sort)
  summary+="\n<details><summary><strong>✅ Successfully Built</strong> (${#successful_targets[@]} targets)</summary>\n\n"
  for t in "${successful_targets[@]}"; do summary+="- \`$t\`\n"; done
  summary+="</details>\n"
fi


[[ -n "$failure_details" ]] && summary+="\n<details open><summary><strong>❌ Failure Details</strong> ($fail_count failures)</summary>\n\n$failure_details</details>\n"
summary+="\n\n---\n\n"

[[ $fail_count -eq 0 ]] && echo "No failures found in BEP — skipping annotation." && return 0
create_annotation "$style" "$summary"
}
