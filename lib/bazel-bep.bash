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

  local success_count=0 fail_count=0 skip_count=0 cached_count=0
  local build_start_time=0 build_end_time=0
  local -A seen_tests
  local -a successful_targets slowest_tests slowest_times
  local failure_details=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == *'"aborted"'* && "$line" == *'"SKIPPED"'* ]] && continue

    # Avoid parsing invalid JSON lines
    ! jq -e '.' <<<"$line" >/dev/null 2>&1 && continue

    # Fast path for build time
    jq -e '.id.buildStarted? != null' <<<"$line" >/dev/null && build_start_time=$(jq -r '.buildStarted.startTimeMillis // 0' <<<"$line")
    jq -e '.id.buildFinished? != null' <<<"$line" >/dev/null && build_end_time=$(jq -r '.buildFinished.finishTimeMillis // 0' <<<"$line")

    # Target completed
    if jq -e '.id.targetCompleted? != null' <<<"$line" >/dev/null; then
      local label=$(jq -r '.id.targetCompleted.label // "unknown"' <<<"$line")
      local success=$(jq -r '.completed.success // "false"' <<<"$line")
      local is_cached=false

      if jq -e '.completed.outputGroup?[]?.fileSets?[]?.id? != null' <<<"$line" >/dev/null \
        && ! jq -e '.completed.actionExecuted? != null' <<<"$line" >/dev/null; then
        is_cached=true
        ((cached_count++))
      fi

      if [[ "$success" == "true" ]]; then
        ((success_count++))
        successful_targets+=("$label")
      else
        ((fail_count++))
        local errors=$(jq -r '.completed.failureDetail.message // "Unknown error"' <<<"$line")
        failure_details+="### ❌ Failed: $label\n\n\`\`\`diff\n- ERROR: $errors\n\`\`\`\n\n"
        if grep -qE "no such target|no such package|Package is considered deleted" <<<"$errors"; then
          local detail=$(grep -oE "'[^']*'|Package [^:]*" <<<"$errors" | head -1)
          failure_details+="**🔍 Possible Fix:** $detail might be missing, renamed, or deleted.\n\n"
        fi
      fi
    fi

    # Target skipped
    jq -e '.id.targetSkipped? != null' <<<"$line" >/dev/null && ((skip_count++))

    # Configured but not yet seen
    if jq -e '.id.configured? != null' <<<"$line" >/dev/null; then
      local label=$(jq -r '.id.configured.targetLabel // "unknown"' <<<"$line")
      [[ " ${successful_targets[*]} " != *" $label "* ]] && ((success_count++)) && successful_targets+=("$label")
    fi

    # Test results
    if jq -e '.id.testResult? != null' <<<"$line" >/dev/null; then
      local test_label=$(jq -r '.id.testResult.label // "unknown"' <<<"$line")
      [[ -n "${seen_tests[$test_label]+x}" ]] && continue
      seen_tests["$test_label"]=1

      local test_status=$(jq -r '.testResult.status // "UNKNOWN"' <<<"$line")
      local test_time=$(jq -r '.testResult.testActionDurationMillis // 0' <<<"$line")
      ((test_time == 0)) && test_time=1000
      local secs=$(bc <<<"scale=2; $test_time/1000")

      [[ "$test_status" == "PASSED" ]] && ((success_count++)) && successful_targets+=("$test_label (test)")
      [[ "$test_status" == "FLAKY" ]] && ((success_count++)) && successful_targets+=("$test_label (⚠️ flaky)")
      [[ "$test_status" != "PASSED" && "$test_status" != "FLAKY" ]] && ((fail_count++))

      slowest_tests+=("$test_label")
      slowest_times+=("$secs")

      if [[ "$test_status" != "PASSED" ]]; then
        local test_errors="No detailed logs available"
        jq -e '.testResult.testActionOutput? != null' <<<"$line" >/dev/null && \
          test_errors=$(jq -r '.testResult.testActionOutput[]? | .name + ": " + .uri' <<<"$line")
        local emoji="❌"
        [[ "$test_status" == "FLAKY" ]] && emoji="⚠️"
        [[ "$test_status" == "TIMEOUT" ]] && emoji="⏱️"
        failure_details+="### $emoji Failed Test: $test_label ($test_status in ${secs}s)\n\n\`\`\`diff\n- $test_errors\n\`\`\`\n\n"
        if jq -e '.testResult.testActionOutput[]? | select(.name == "test.log")' <<<"$line" >/dev/null; then
          local log_uri=$(jq -r '.testResult.testActionOutput[] | select(.name == "test.log") | .uri' <<<"$line")
          failure_details+="[View Full Test Log]($log_uri)\n\n"
        fi
      fi
    fi
  done < "$BEP_FILE"

  local duration=0
  ((build_end_time > 0 && build_start_time > 0)) && duration=$(( (build_end_time - build_start_time) / 1000 ))

  local style="info"
  [[ $fail_count -gt 0 ]] && style="error"

  local summary="### ${BUILDKITE_LABEL:-Bazel Results}\n\n"
  ((duration > 0)) && summary+="