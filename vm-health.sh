#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

usage() {
  printf 'Usage: %s [explain]\n' "${0##*/}" >&2
}

explain=false
if [[ $# -gt 1 ]]; then
  usage
  exit 2
fi
if [[ $# -eq 1 ]]; then
  if [[ $1 == explain ]]; then
    explain=true
  else
    usage
    exit 2
  fi
fi

if [[ ! -r /proc/stat || ! -r /proc/meminfo ]]; then
  printf 'Error: this script requires Linux /proc/stat and /proc/meminfo.\n' >&2
  exit 2
fi
command -v awk >/dev/null 2>&1 || {
  printf 'Error: awk is required.\n' >&2
  exit 2
}
command -v df >/dev/null 2>&1 || {
  printf 'Error: df is required.\n' >&2
  exit 2
}

cpu_snapshot() {
  awk '
    /^cpu / {
      total = 0
      for (i = 2; i <= 9; i++) total += $i
      printf "%.0f %.0f\n", total, $5 + $6
      exit
    }
  ' /proc/stat
}

read -r cpu_total_start cpu_idle_start < <(cpu_snapshot)
if [[ -z ${cpu_total_start:-} || -z ${cpu_idle_start:-} ]]; then
  printf 'Error: could not read CPU counters from /proc/stat.\n' >&2
  exit 2
fi

sleep 1

read -r cpu_total_end cpu_idle_end < <(cpu_snapshot)
if [[ -z ${cpu_total_end:-} || -z ${cpu_idle_end:-} ]]; then
  printf 'Error: could not read CPU counters from /proc/stat.\n' >&2
  exit 2
fi

cpu_usage=$(awk \
  -v total_start="$cpu_total_start" -v total_end="$cpu_total_end" \
  -v idle_start="$cpu_idle_start" -v idle_end="$cpu_idle_end" \
  'BEGIN {
    total_delta = total_end - total_start
    idle_delta = idle_end - idle_start
    if (total_delta <= 0 || idle_delta < 0 || idle_delta > total_delta) exit 1
    printf "%.6f", (total_delta - idle_delta) / total_delta * 100
  }') || {
  printf 'Error: CPU counters did not provide a valid utilization sample.\n' >&2
  exit 2
}

memory_usage=$(awk '
  /^MemTotal:/ { total = $2 }
  /^MemAvailable:/ { available = $2 }
  END {
    if (total <= 0 || available < 0 || available > total) exit 1
    printf "%.6f", (total - available) / total * 100
  }
' /proc/meminfo) || {
  printf 'Error: could not calculate memory utilization from /proc/meminfo.\n' >&2
  exit 2
}

disk_usage=$(df -Pk / | awk '
  NR == 2 {
    if ($2 <= 0 || $3 < 0 || $3 > $2) exit 1
    printf "%.6f", $3 / $2 * 100
    found = 1
  }
  END {
    if (!found) exit 1
  }
') || {
  printf 'Error: could not calculate disk utilization for /.\n' >&2
  exit 2
}

unhealthy_reasons=()
for metric in "CPU:$cpu_usage" "Memory:$memory_usage" "Disk (/):$disk_usage"; do
  name=${metric%%:*}
  value=${metric#*:}
  if awk -v value="$value" 'BEGIN { exit !(value > 60) }'; then
    unhealthy_reasons+=("$name utilization is above 60% (${value}%).")
  fi
done

if [[ ${#unhealthy_reasons[@]} -gt 0 ]]; then
  printf 'VM status: UNHEALTHY\n'
else
  printf 'VM status: HEALTHY\n'
fi
printf 'CPU utilization: %.1f%%\n' "$cpu_usage"
printf 'Memory utilization: %.1f%%\n' "$memory_usage"
printf 'Disk utilization (/): %.1f%%\n' "$disk_usage"

if [[ $explain == true ]]; then
  if [[ ${#unhealthy_reasons[@]} -gt 0 ]]; then
    printf 'Why: %s\n' "${unhealthy_reasons[@]}"
  else
    printf 'Why: CPU, memory, and disk utilization are all at or below 60%%.\n'
  fi
fi

if [[ ${#unhealthy_reasons[@]} -gt 0 ]]; then
  exit 1
fi
