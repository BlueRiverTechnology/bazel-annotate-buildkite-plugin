#!/opt/homebrew/bin/bash
#set -euo pipefail

#-------------------------------------------------------------------------------
# This library processes Bazel Event Protocol output and creates Buildkite
# annotations, with line-numbered debug output for each streamed event.
#-------------------------------------------------------------------------------

# Function to get a random quote for annotation footer
get_random_quote() {
  local quotes=(
    '"The best error message is the one that never shows up." - Thomas Fuchs'
    '"First, solve the problem. Then, write the code." - John Johnson'
    '"Make it work, make it right, make it fast." - Kent Beck'
    '"Programming isn'\''t about what you know; it'\''s about what you can figure out." - Chris Pine'
    '"The only way to learn a new programming language is by writing programs in it." - Dennis Ritchie'
    '"Testing can only prove the presence of bugs, not their absence." - Edsger W. Dijkstra'
    '"It'\''s not a bug – it'\''s an undocumented feature." - Anonymous'
    '"Good code is its own best documentation." - Steve McConnell'
    '"Any fool can write code that a computer can understand. Good programmers write code that humans can understand." - Martin Fowler'
    '"The sooner you start to code, the longer the program will take." - Roy Carlson'
    '"Optimism is an occupational hazard of programming; feedback is the treatment." - Kent Beck'
    '"Simplicity is the soul of efficiency." - Austin Freeman'
  )
  echo "${quotes[RANDOM % ${#quotes[@]}]}"
}

# Function to create a Buildkite annotation from the given Markdown content
create_annotation() {
  local style="$1"; local content="$2"
  local context="bazel-bep-results"
  local job="${BUILDKITE_LABEL:-Bazel Results}"
  local first="${BUILDKITE_PLUGIN_BAZEL_ANNOTATE_IS_FIRST_JOB:-true}"

  if [ -n "${BUILDKITE:-}" ] && command -v buildkite-agent &>/dev/null; then
    if [ "$first" != "true" ]; then
      content=$(printf "%s" "$content" | sed '1,3d')
      content=$'### 🧩 '"${job_name}"$'\n\n'"${content}"

$content"
    fi
    printf "%s" "$content" \
      | buildkite-agent annotate --style "$style" --append
    # mark header done
    if ! buildkite-agent meta-data exists "bazel-annotate-header-created" &>/dev/null; then
      buildkite-agent meta-data set "bazel-annotate-header-created" "true" || true
    fi
  else
    echo "Not running in Buildkite. Would annotate ($style):"
    printf "%s\n" "$content"
  fi
}

#-------------------------------------------------------------------------------
# Main processing function
#-------------------------------------------------------------------------------
process_bep() {
  local BEP="$1"
  echo "Processing BEP file: $BEP"

  # Guard: file exists
  [[ ! -s "$BEP" ]] && { echo "⚠ Skipping: $BEP is missing or empty"; return; }

  # Initialize counters & containers
  declare -A seen_tests
  declare -a successful_targets=() slowest_tests=() slowest_times=()
  local build_start=0 build_end=0
  local success_count=0 fail_count=0 skip_count=0 cached_count=0
  local failure_details=""

  # Stream & tag only the events we need, one JSON-per-line
  jq -rc '
    select(
      (.aborted?.reason != "SKIPPED") and
      (
        .id.buildStarted? or
        .id.buildFinished? or
        .id.targetCompleted? or
        .id.configured? or
        .id.targetSkipped? or
        .id.testResult?
      )
    )
    | {
        type: (
          if .id.buildStarted? then "buildStarted"
          elif .id.buildFinished? then "buildFinished"
          elif .id.targetCompleted? then "targetCompleted"
          elif .id.configured? then "configured"
          elif .id.targetSkipped? then "skipped"
          else "testResult" end
        ),
        label: (
          .id.testResult.label // .id.targetCompleted.label //
          .id.targetSkipped.label // .id.configured.targetLabel // "unknown"
        ),
        success: (.completed.success // false),
        cached: (
          (.completed.outputGroup? // [])
          | any(.name == "bazel-out")
          and (.completed.actionExecuted == null)
        ),
        status: .testResult.status,
        time: (.testResult.testActionDurationMillis // 0),
        log: (
          .testResult.testActionOutput[]?
          | select(.name == "test.log")
          | .uri
        ),
        start: .buildStarted.startTimeMillis,
        end: .buildFinished.finishTimeMillis
      }
  ' "$BEP" \
  | {
      while IFS= read -r evt; do

        type=$(jq -r '.type' <<<"$evt")
        label=$(jq -r '.label' <<<"$evt")

        case "$type" in
          buildStarted)
            build_start=$(jq -r '.start' <<<"$evt") ;;
          buildFinished)
            build_end=$(jq -r '.end' <<<"$evt") ;;
          targetCompleted)
            local ok=$(jq -r '.success' <<<"$evt")
            local cached=$(jq -r '.cached' <<<"$evt")
            if [[ "$ok" == true ]]; then
              ((success_count++))
              successful_targets+=("$label")
              [[ "$cached" == true ]] && ((cached_count++))
            else
              ((fail_count++))
            fi
            ;;
          configured)
            if [[ ! " ${successful_targets[*]} " =~ [[:space:]]${label}[[:space:]] ]]; then
              ((success_count++))
              successful_targets+=("$label")
            fi
            ;;
          skipped)
            ((skip_count++)) ;;
          testResult)
            local status=$(jq -r '.status' <<<"$evt")
            local dur_ms=$(jq -r '.time'   <<<"$evt")
            local loguri=$(jq -r '.log // empty' <<<"$evt")

            # dedupe
            [[ -n "${seen_tests[$label]:-}" ]] && continue
            seen_tests["$label"]=1

            # record slowest
            local dur_s=$(bc <<<"scale=2; $dur_ms/1000")
            slowest_tests+=("$label")
            slowest_times+=("$dur_s")

            if [[ "$status" == "PASSED" || "$status" == "FLAKY" ]]; then
              ((success_count++))
              if [[ "$status" == "FLAKY" ]]; then
                successful_targets+=("$label (⚠️ flaky)")
              else
                successful_targets+=("$label (test)")
              fi
            else
              ((fail_count++))
              emoji="❌"
              [[ "$status" == "TIMEOUT" ]] && emoji="⏱️"

              failure_details+="### $emoji $label failed ($status in ${dur_s}s)
\`\`\`diff
- Log: ${loguri:-Not available}
\`\`\`

"
            fi
            ;;
        esac
      done

      # After loop, build the Markdown summary
      local summary="### Bazel Results

"
      if (( build_end > 0 && build_start > 0 )); then
        summary+="**⏱️ Duration:** $(( (build_end - build_start)/1000 ))s | "
      fi
      summary+="**Status:** ✅ $success_count"
      (( cached_count > 0 )) && summary+=" | 🔄 $cached_count cached"
      (( fail_count   > 0 )) && summary+=" | ❌ $fail_count failed"
      (( skip_count   > 0 )) && summary+=" | ⏭️ $skip_count skipped"
      summary+="

"

      # slowest tests
      if (( ${#slowest_tests[@]} )); then
        summary+="<details><summary><strong>⏱️ Test Durations</strong> (${#slowest_tests[@]})</summary>

"
        for i in "${!slowest_tests[@]}"; do
          summary+="- \`${slowest_tests[i]}\`: ${slowest_times[i]}s
"
          (( i == 9 )) && { summary+="- _...and $(( ${#slowest_tests[@]}-10)) more_\n"; break; }
        done
        summary+="</details>

"
      fi

      # successful targets
      if (( ${#successful_targets[@]} )); then
        mapfile -t sorted < <(printf '%s\n' "${successful_targets[@]}" | sort)
        summary+="<details><summary><strong>✅ Successfully Built</strong> (${#sorted[@]})</summary>

"
        for tgt in "${sorted[@]}"; do
          summary+="- \`$tgt\`
"
        done
        summary+="</details>

"
      fi

      # failures
      if [[ -n "$failure_details" ]]; then
        summary+="<details open><summary><strong>❌ Failure Details</strong> ($fail_count)</summary>

$failure_details</details>"
      fi

      # annotate
      if (( fail_count == 0 )); then
        echo "No failures — skipping annotation."
        exit 0
      fi
      create_annotation "error" "$summary"
    }
}

