#!/usr/bin/env bash
set -euo pipefail

# generate-report.sh — Generate an HTML benchmark report with Tailwind CSS + Chart.js.
#
# Usage: ./scripts/generate-report.sh <results-dir>
#
# Reads JSON result files from <results-dir> and emits:
#   <results-dir>/report.html  — full HTML report
#   <results-dir>/index.html   — redirect to report.html (for GitHub Pages)

RESULTS_DIR="${1:?Usage: generate-report.sh <results-dir>}"
REPORT_FILE="${RESULTS_DIR}/report.html"
INDEX_FILE="${RESULTS_DIR}/index.html"

# Helper: format seconds with 2 decimal places.
fmt_s() { printf "%.2f" "$1"; }

# Helper: compute delta and improvement percentage.
compute_delta() {
  local base="$1" patch="$2"
  echo | awk -v b="${base}" -v p="${patch}" '{
    delta = p - b
    if (b != 0) pct = ((b - p) / b) * 100
    else pct = 0
    printf "%.2f %.1f", delta, pct
  }'
}

# Collect metadata.
RUNNER="$(uname -m) / $(uname -s)"
REPORT_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

BUILD_INFO="${RESULTS_DIR}/build-info.json"
BASELINE_BRANCH="" BASELINE_SHA="" PATCHED_BRANCH="" PATCHED_SHA=""
if [[ -f "${BUILD_INFO}" ]]; then
  BASELINE_BRANCH=$(jq -r '.baseline_branch' "${BUILD_INFO}")
  BASELINE_SHA=$(jq -r '.baseline_sha' "${BUILD_INFO}")
  PATCHED_BRANCH=$(jq -r '.patched_branch' "${BUILD_INFO}")
  PATCHED_SHA=$(jq -r '.patched_sha' "${BUILD_INFO}")
fi

# Detect baseline/patched pairs.
shopt -s nullglob
BASELINE_FILES=("${RESULTS_DIR}"/baseline-*.json)
shopt -u nullglob

HAS_PAIRS=false
if [[ ${#BASELINE_FILES[@]} -gt 0 ]]; then
  HAS_PAIRS=true
fi

# Check for any failed runs.
FAILED_RUNS=()
shopt -s nullglob
ALL_JSON_FILES=("${RESULTS_DIR}"/*.json)
shopt -u nullglob
for f in "${ALL_JSON_FILES[@]}"; do
  [[ "$(basename "$f")" == "build-info.json" ]] && continue
  EXIT_CODE=$(jq -r '.exit_code // 0' "$f")
  if [[ "${EXIT_CODE}" != "0" ]]; then
    LABEL=$(jq -r '.label // "unknown"' "$f")
    FAILED_RUNS+=("${LABEL} (exit ${EXIT_CODE})")
  fi
done
HAS_FAILURES=false
if [[ ${#FAILED_RUNS[@]} -gt 0 ]]; then
  HAS_FAILURES=true
fi

# ── Begin HTML ───────────────────────────────────────────────────────

cat > "${REPORT_FILE}" <<'HTMLHEAD'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Kurtosis Benchmark Report</title>
  <script src="https://cdn.tailwindcss.com"></script>
  <script src="https://cdn.jsdelivr.net/npm/chart.js@4"></script>
  <style>
    details summary { cursor: pointer; }
    details summary::-webkit-details-marker { display: none; }
    details summary::marker { display: none; content: ""; }
    .chevron { transition: transform 0.2s; }
    details[open] .chevron { transform: rotate(90deg); }
  </style>
</head>
<body class="bg-gray-50 text-gray-900 min-h-dvh">
  <div class="mx-auto max-w-6xl px-4 py-8">
HTMLHEAD

# ── Header ───────────────────────────────────────────────────────────

cat >> "${REPORT_FILE}" <<EOF
    <div class="mb-8">
      <h1 class="text-3xl/10 font-bold tracking-tight">Kurtosis Benchmark Report</h1>
      <p class="mt-1 text-sm/6 text-gray-500">${REPORT_DATE}</p>
    </div>

    <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4 mb-8">
      <div class="bg-white shadow-xs rounded-sm p-4">
        <div class="text-xs font-medium text-gray-500 uppercase tracking-wide">Runner</div>
        <div class="mt-1 text-sm/6 font-medium">${RUNNER}</div>
      </div>
EOF

if [[ -n "${BASELINE_BRANCH}" ]]; then
  cat >> "${REPORT_FILE}" <<EOF
      <div class="bg-white shadow-xs rounded-sm p-4">
        <div class="text-xs font-medium text-gray-500 uppercase tracking-wide">Baseline</div>
        <div class="mt-1 text-sm/6 font-medium">${BASELINE_BRANCH}</div>
        <code class="text-xs text-gray-400">${BASELINE_SHA}</code>
      </div>
      <div class="bg-white shadow-xs rounded-sm p-4">
        <div class="text-xs font-medium text-gray-500 uppercase tracking-wide">Patched</div>
        <div class="mt-1 text-sm/6 font-medium">${PATCHED_BRANCH}</div>
        <code class="text-xs text-gray-400">${PATCHED_SHA}</code>
      </div>
EOF
fi

# Count total configs/runs.
TOTAL_RUNS=${#ALL_JSON_FILES[@]}
# Subtract build-info.json.
TOTAL_RUNS=$((TOTAL_RUNS - 1))
cat >> "${REPORT_FILE}" <<EOF
      <div class="bg-white shadow-xs rounded-sm p-4">
        <div class="text-xs font-medium text-gray-500 uppercase tracking-wide">Total Runs</div>
        <div class="mt-1 text-sm/6 font-medium">${TOTAL_RUNS}</div>
      </div>
    </div>
EOF

# ── Failure banner ───────────────────────────────────────────────────

if [[ "${HAS_FAILURES}" == "true" ]]; then
  FAILED_LIST=""
  for fr in "${FAILED_RUNS[@]}"; do
    FAILED_LIST="${FAILED_LIST}<li class=\"font-mono\">${fr}</li>"
  done
  cat >> "${REPORT_FILE}" <<EOF
    <div class="bg-red-50 border border-red-200 rounded-sm p-5 mb-8">
      <h2 class="text-base/6 font-semibold text-red-800">Benchmark Failures Detected</h2>
      <p class="mt-1 text-sm/6 text-red-700">One or more runs exited non-zero. Results are <strong>not valid</strong> for comparison — a failed run terminates early, appearing artificially faster.</p>
      <ul class="mt-2 text-sm/6 text-red-700 list-disc pl-5">${FAILED_LIST}</ul>
    </div>
EOF
fi

# ── Comparison mode ──────────────────────────────────────────────────

if [[ "${HAS_PAIRS}" == "true" ]]; then

  # Collect all pair data for the chart + table.
  CHART_LABELS="" CHART_BASE="" CHART_PATCH=""
  TABLE_ROWS=""
  PAIRS=()
  PAIR_IDX=0

  for baseline_file in "${BASELINE_FILES[@]}"; do
    base_name=$(basename "${baseline_file}" .json)
    suffix="${base_name#baseline-}"
    patched_file="${RESULTS_DIR}/patched-${suffix}.json"
    [[ ! -f "${patched_file}" ]] && continue

    PAIRS+=("${suffix}")

    CONFIG=$(jq -r '.config' "${baseline_file}" | xargs basename | sed 's/\.yaml$//')
    PKG_LABEL="${suffix##*-}"
    BASE_DUR=$(jq -r '.duration_seconds' "${baseline_file}")
    PATCH_DUR=$(jq -r '.duration_seconds' "${patched_file}")
    BASE_EXIT=$(jq -r '.exit_code // 0' "${baseline_file}")
    PATCH_EXIT=$(jq -r '.exit_code // 0' "${patched_file}")
    BASE_SVCS=$(jq -r '.num_services // "?"' "${baseline_file}")
    PATCH_SVCS=$(jq -r '.num_services // "?"' "${patched_file}")
    BASE_CMD=$(jq -r '.command // ""' "${baseline_file}")
    PATCH_CMD=$(jq -r '.command // ""' "${patched_file}")
    read -r DELTA PCT <<< "$(compute_delta "${BASE_DUR}" "${PATCH_DUR}")"

    BASE_FMT=$(fmt_s "${BASE_DUR}")
    PATCH_FMT=$(fmt_s "${PATCH_DUR}")

    # Chart data (comma-separated).
    [[ ${PAIR_IDX} -gt 0 ]] && { CHART_LABELS+=","; CHART_BASE+=","; CHART_PATCH+=","; }
    CHART_LABELS+="\"${CONFIG} / ${PKG_LABEL}\""
    CHART_BASE+="${BASE_DUR}"
    CHART_PATCH+="${PATCH_DUR}"

    # Improvement badge.
    if awk "BEGIN { exit (${PCT} > 0) ? 0 : 1 }"; then
      PCT_CLASSES="bg-emerald-100 text-emerald-800"
    else
      PCT_CLASSES="bg-red-100 text-red-800"
    fi

    # Exit code badges.
    BASE_EXIT_BADGE=""
    PATCH_EXIT_BADGE=""
    if [[ "${BASE_EXIT}" != "0" ]]; then
      BASE_EXIT_BADGE="<span class=\"ml-1.5 inline-block px-1.5 py-0.5 rounded-xs text-xs font-medium bg-red-100 text-red-700\">exit ${BASE_EXIT}</span>"
    fi
    if [[ "${PATCH_EXIT}" != "0" ]]; then
      PATCH_EXIT_BADGE="<span class=\"ml-1.5 inline-block px-1.5 py-0.5 rounded-xs text-xs font-medium bg-red-100 text-red-700\">exit ${PATCH_EXIT}</span>"
    fi

    TABLE_ROWS+="
            <tr class=\"border-b border-gray-100 group\">
              <td class=\"py-3.5 pr-4\">
                <div class=\"font-medium\">${CONFIG}</div>
                <div class=\"text-xs text-gray-400\">${PKG_LABEL}</div>
              </td>
              <td class=\"py-3.5 pr-4 text-right font-mono\">${BASE_FMT}s${BASE_EXIT_BADGE}</td>
              <td class=\"py-3.5 pr-4 text-right font-mono\">${PATCH_FMT}s${PATCH_EXIT_BADGE}</td>
              <td class=\"py-3.5 pr-4 text-right font-mono\">${DELTA}s</td>
              <td class=\"py-3.5 pr-4 text-right\"><span class=\"inline-block px-2 py-0.5 rounded-xs text-xs font-semibold ${PCT_CLASSES}\">${PCT}%</span></td>
              <td class=\"py-3.5 pr-4 text-right text-xs text-gray-400\">${BASE_SVCS} / ${PATCH_SVCS}</td>
            </tr>"

    # Run details accordion row.
    if [[ -n "${BASE_CMD}" || -n "${PATCH_CMD}" ]]; then
      # Normalize command paths for display.
      DISPLAY_BASE_CMD=$(echo "${BASE_CMD}" | sed 's|[^ ]*/kurtosis|kurtosis|')
      DISPLAY_PATCH_CMD=$(echo "${PATCH_CMD}" | sed 's|[^ ]*/kurtosis|kurtosis|')
      TABLE_ROWS+="
            <tr class=\"border-b border-gray-50\">
              <td colspan=\"6\" class=\"px-0 py-0\">
                <details>
                  <summary class=\"flex items-center gap-2 px-4 py-2 text-xs text-gray-400 hover:text-gray-600 hover:bg-gray-50\">
                    <svg class=\"chevron size-3 shrink-0\" fill=\"none\" viewBox=\"0 0 24 24\" stroke=\"currentColor\" stroke-width=\"2\"><path d=\"M9 5l7 7-7 7\"/></svg>
                    Run details
                  </summary>
                  <div class=\"px-4 pb-3 grid grid-cols-1 md:grid-cols-2 gap-3\">
                    <div>
                      <div class=\"text-xs font-medium text-gray-500 mb-1\">Baseline command</div>
                      <code class=\"block text-xs bg-gray-900 text-gray-100 p-2.5 rounded-xs overflow-x-auto whitespace-pre\">${DISPLAY_BASE_CMD}</code>
                    </div>
                    <div>
                      <div class=\"text-xs font-medium text-gray-500 mb-1\">Patched command</div>
                      <code class=\"block text-xs bg-gray-900 text-gray-100 p-2.5 rounded-xs overflow-x-auto whitespace-pre\">${DISPLAY_PATCH_CMD}</code>
                    </div>
                  </div>
                </details>
              </td>
            </tr>"
    fi

    PAIR_IDX=$((PAIR_IDX + 1))
  done

  # ── Wall Clock chart + table ──

  cat >> "${REPORT_FILE}" <<EOF
    <div class="bg-white shadow-xs rounded-sm p-6 mb-6">
      <h2 class="text-lg/7 font-semibold mb-6">Wall Clock Comparison</h2>
      <div class="h-64 mb-6">
        <canvas id="wallClockChart"></canvas>
      </div>
      <div class="overflow-x-auto">
        <table class="w-full text-sm/6">
          <thead>
            <tr class="border-b border-gray-200 text-left text-gray-500 text-xs uppercase tracking-wide">
              <th class="pb-2.5 pr-4 font-medium">Config</th>
              <th class="pb-2.5 pr-4 font-medium text-right">Baseline</th>
              <th class="pb-2.5 pr-4 font-medium text-right">Patched</th>
              <th class="pb-2.5 pr-4 font-medium text-right">Delta</th>
              <th class="pb-2.5 pr-4 font-medium text-right">Improvement</th>
              <th class="pb-2.5 pr-4 font-medium text-right">Services</th>
            </tr>
          </thead>
          <tbody>${TABLE_ROWS}
          </tbody>
        </table>
      </div>
    </div>
    <script>
      new Chart(document.getElementById('wallClockChart'), {
        type: 'bar',
        data: {
          labels: [${CHART_LABELS}],
          datasets: [
            { label: 'Baseline', data: [${CHART_BASE}], backgroundColor: 'rgba(96,165,250,0.8)', borderRadius: 3 },
            { label: 'Patched', data: [${CHART_PATCH}], backgroundColor: 'rgba(52,211,153,0.8)', borderRadius: 3 }
          ]
        },
        options: {
          responsive: true, maintainAspectRatio: false,
          plugins: { legend: { position: 'bottom', labels: { usePointStyle: true, pointStyle: 'rectRounded', padding: 20 } } },
          scales: { y: { beginAtZero: true, title: { display: true, text: 'Seconds' }, grid: { color: 'rgba(0,0,0,0.04)' } }, x: { grid: { display: false } } }
        }
      });
    </script>
EOF

  # ── Phase Breakdown sections (accordions) ──

  PHASE_IDX=0
  for suffix in "${PAIRS[@]}"; do
    baseline_file="${RESULTS_DIR}/baseline-${suffix}.json"
    patched_file="${RESULTS_DIR}/patched-${suffix}.json"

    CONFIG=$(jq -r '.config' "${baseline_file}" | xargs basename | sed 's/\.yaml$//')
    PKG_LABEL="${suffix##*-}"

    BASE_PHASES=$(jq -r '.apic_phases // {} | keys[]' "${baseline_file}" 2>/dev/null || true)
    PATCH_PHASES=$(jq -r '.apic_phases // {} | keys[]' "${patched_file}" 2>/dev/null || true)
    ALL_PHASES=$(printf '%s\n%s\n' "${BASE_PHASES}" "${PATCH_PHASES}" | sort -u | grep -v '^$' || true)
    [[ -z "${ALL_PHASES}" ]] && continue

    # Find max phase value for bar scaling + collect chart data.
    MAX_VAL="0"
    PHASE_CHART_LABELS="" PHASE_CHART_BASE="" PHASE_CHART_PATCH=""
    PHASE_TABLE_ROWS=""
    PHASE_ITEM_IDX=0

    while IFS= read -r phase; do
      BASE_VAL=$(jq -r --arg p "${phase}" '.apic_phases[$p] // 0' "${baseline_file}")
      PATCH_VAL=$(jq -r --arg p "${phase}" '.apic_phases[$p] // 0' "${patched_file}")
      MAX_VAL=$(awk -v m="${MAX_VAL}" -v b="${BASE_VAL}" -v p="${PATCH_VAL}" 'BEGIN {
        v = (b > p) ? b : p; if (v > m) print v; else print m
      }')
    done <<< "${ALL_PHASES}"

    # Only chart the top phases (> 0.5s in either run) to avoid clutter.
    while IFS= read -r phase; do
      BASE_VAL=$(jq -r --arg p "${phase}" '.apic_phases[$p] // 0' "${baseline_file}")
      PATCH_VAL=$(jq -r --arg p "${phase}" '.apic_phases[$p] // 0' "${patched_file}")
      read -r DELTA _ <<< "$(compute_delta "${BASE_VAL}" "${PATCH_VAL}")"

      BASE_FMT=$(fmt_s "${BASE_VAL}")
      PATCH_FMT=$(fmt_s "${PATCH_VAL}")

      # Bar widths.
      if awk "BEGIN { exit (${MAX_VAL} > 0) ? 0 : 1 }"; then
        BASE_PCT=$(awk -v v="${BASE_VAL}" -v m="${MAX_VAL}" 'BEGIN { printf "%.1f", (v / m) * 100 }')
        PATCH_PCT=$(awk -v v="${PATCH_VAL}" -v m="${MAX_VAL}" 'BEGIN { printf "%.1f", (v / m) * 100 }')
      else
        BASE_PCT="0"
        PATCH_PCT="0"
      fi

      # Add to chart data if significant.
      IS_SIG=$(awk -v b="${BASE_VAL}" -v p="${PATCH_VAL}" 'BEGIN { print (b >= 0.5 || p >= 0.5) ? "1" : "0" }')
      if [[ "${IS_SIG}" == "1" ]]; then
        [[ ${PHASE_ITEM_IDX} -gt 0 ]] && { PHASE_CHART_LABELS+=","; PHASE_CHART_BASE+=","; PHASE_CHART_PATCH+=","; }
        # Escape quotes in phase name.
        SAFE_PHASE=$(echo "${phase}" | sed 's/"/\\"/g')
        PHASE_CHART_LABELS+="\"${SAFE_PHASE}\""
        PHASE_CHART_BASE+="${BASE_VAL}"
        PHASE_CHART_PATCH+="${PATCH_VAL}"
        PHASE_ITEM_IDX=$((PHASE_ITEM_IDX + 1))
      fi

      PHASE_TABLE_ROWS+="
              <tr class=\"border-b border-gray-50\">
                <td class=\"py-2 pr-4 text-xs\">${phase}</td>
                <td class=\"py-2 pr-4 text-right font-mono text-xs\">${BASE_FMT}s</td>
                <td class=\"py-2 pr-4 text-right font-mono text-xs\">${PATCH_FMT}s</td>
                <td class=\"py-2 pr-4 text-right font-mono text-xs\">${DELTA}s</td>
                <td class=\"py-2\">
                  <div class=\"flex flex-col gap-0.5\">
                    <div class=\"h-2 rounded-xs bg-blue-400\" style=\"width:${BASE_PCT}%\"></div>
                    <div class=\"h-2 rounded-xs bg-emerald-400\" style=\"width:${PATCH_PCT}%\"></div>
                  </div>
                </td>
              </tr>"
    done <<< "${ALL_PHASES}"

    cat >> "${REPORT_FILE}" <<EOF
    <details class="bg-white shadow-xs rounded-sm mb-4 group">
      <summary class="flex items-center justify-between p-5 hover:bg-gray-50">
        <div class="flex items-center gap-3">
          <svg class="chevron size-4 text-gray-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path d="M9 5l7 7-7 7"/></svg>
          <h2 class="text-base/6 font-semibold">APIC Phase Breakdown: ${CONFIG} / ${PKG_LABEL}</h2>
        </div>
        <div class="flex items-center gap-1.5 text-xs text-gray-400">
          <div class="size-2.5 rounded-xs bg-blue-400"></div> Baseline
          <div class="ml-2 size-2.5 rounded-xs bg-emerald-400"></div> Patched
        </div>
      </summary>
      <div class="px-5 pb-5">
        <div class="h-56 mb-5">
          <canvas id="phaseChart${PHASE_IDX}"></canvas>
        </div>
        <div class="overflow-x-auto">
          <table class="w-full text-sm/6">
            <thead>
              <tr class="border-b border-gray-200 text-left text-gray-500 text-xs uppercase tracking-wide">
                <th class="pb-2 pr-4 font-medium">Phase</th>
                <th class="pb-2 pr-4 font-medium text-right">Baseline</th>
                <th class="pb-2 pr-4 font-medium text-right">Patched</th>
                <th class="pb-2 pr-4 font-medium text-right">Delta</th>
                <th class="pb-2 font-medium" style="min-width:180px">Comparison</th>
              </tr>
            </thead>
            <tbody>${PHASE_TABLE_ROWS}
            </tbody>
          </table>
        </div>
      </div>
    </details>
    <script>
      new Chart(document.getElementById('phaseChart${PHASE_IDX}'), {
        type: 'bar',
        data: {
          labels: [${PHASE_CHART_LABELS}],
          datasets: [
            { label: 'Baseline', data: [${PHASE_CHART_BASE}], backgroundColor: 'rgba(96,165,250,0.8)', borderRadius: 3 },
            { label: 'Patched', data: [${PHASE_CHART_PATCH}], backgroundColor: 'rgba(52,211,153,0.8)', borderRadius: 3 }
          ]
        },
        options: {
          indexAxis: 'y',
          responsive: true, maintainAspectRatio: false,
          plugins: { legend: { position: 'bottom', labels: { usePointStyle: true, pointStyle: 'rectRounded', padding: 20 } } },
          scales: { x: { beginAtZero: true, title: { display: true, text: 'Seconds' }, grid: { color: 'rgba(0,0,0,0.04)' } }, y: { grid: { display: false } } }
        }
      });
    </script>
EOF
    PHASE_IDX=$((PHASE_IDX + 1))
  done

else
  # ── Fallback: simple table (no baseline/patched pairs) ──

  cat >> "${REPORT_FILE}" <<'EOF'
    <div class="bg-white shadow-xs rounded-sm p-6 mb-6">
      <h2 class="text-lg/7 font-semibold mb-4">Timing Summary</h2>
      <div class="overflow-x-auto">
        <table class="w-full text-sm/6">
          <thead>
            <tr class="border-b border-gray-200 text-left text-gray-500 text-xs uppercase tracking-wide">
              <th class="pb-2.5 pr-4 font-medium">Run</th>
              <th class="pb-2.5 pr-4 font-medium">Config</th>
              <th class="pb-2.5 pr-4 font-medium">Image Mode</th>
              <th class="pb-2.5 pr-4 font-medium text-right">Duration (s)</th>
              <th class="pb-2.5 pr-4 font-medium text-right">New Images</th>
              <th class="pb-2.5 font-medium text-right">Services</th>
            </tr>
          </thead>
          <tbody>
EOF

  shopt -s nullglob
  JSON_FILES=("${RESULTS_DIR}"/*.json)
  shopt -u nullglob

  for result_file in "${JSON_FILES[@]}"; do
    [[ "$(basename "${result_file}")" == "build-info.json" ]] && continue
    LABEL=$(jq -r '.label // "unknown"' "${result_file}")
    CONFIG=$(basename "$(jq -r '.config // "unknown"' "${result_file}")")
    MODE=$(jq -r '.image_download_mode // "unknown"' "${result_file}")
    DURATION=$(jq -r '.duration_seconds // 0' "${result_file}")
    IMAGES=$(jq -r '.new_images_pulled // 0' "${result_file}")
    SERVICES=$(jq -r '.num_services // "0"' "${result_file}")
    cat >> "${REPORT_FILE}" <<EOF
            <tr class="border-b border-gray-100">
              <td class="py-3 pr-4 font-medium">${LABEL}</td>
              <td class="py-3 pr-4">${CONFIG}</td>
              <td class="py-3 pr-4">${MODE}</td>
              <td class="py-3 pr-4 text-right font-mono">${DURATION}</td>
              <td class="py-3 pr-4 text-right font-mono">${IMAGES}</td>
              <td class="py-3 text-right font-mono">${SERVICES}</td>
            </tr>
EOF
  done

  cat >> "${REPORT_FILE}" <<'EOF'
          </tbody>
        </table>
      </div>
    </div>
EOF
fi

# ── Footer ───────────────────────────────────────────────────────────

cat >> "${REPORT_FILE}" <<EOF
    <footer class="text-center text-xs text-gray-400 py-8 border-t border-gray-100 mt-8">
      Generated by kt-speed-tests &middot; ${REPORT_DATE}
    </footer>
  </div>
</body>
</html>
EOF

# ── index.html redirect ─────────────────────────────────────────────

cat > "${INDEX_FILE}" <<'EOF'
<!DOCTYPE html>
<html><head><meta http-equiv="refresh" content="0;url=report.html"></head><body></body></html>
EOF

echo "Report written to ${REPORT_FILE}"
echo "Index redirect written to ${INDEX_FILE}"
