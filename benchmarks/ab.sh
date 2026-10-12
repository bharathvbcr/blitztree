#!/bin/zsh
# Interleaved A/B runner with min-of-N and median reporting.
#
#   env [BZ_*=...] zsh benchmarks/ab.sh ROUNDS OUT.tsv METRIC... -- ARM=BINARY... -- ARGS...
#
#   METRIC  name:sed-regex, e.g. 'walk:.*walk ([0-9.]+)s.*': the first capture group of
#           the first matching line of a run's stdout+stderr is that run's sample.
#   ARM     label=path of the executable. The same binary under two labels is the
#           A/A control. Each round runs every arm once; the starting arm rotates
#           from round to round, so no arm always runs first or last.
#   ARGS    passed to every binary unchanged.
#
# Raw samples go to OUT.tsv as `metric<TAB>arm<TAB>round<TAB>value`; the summary
# (min, median, max per metric and arm) is printed. Run it with the machine as quiet
# as it gets and state the load average next to the numbers (uptime).
set -u
rounds=$1; out=$2; shift 2
metrics=(); arms=()
while [[ $# -gt 0 && $1 != -- ]]; do metrics+=("$1"); shift; done
shift
while [[ $# -gt 0 && $1 != -- ]]; do arms+=("$1"); shift; done
shift
args=("$@")
: > "$out"
n=${#arms[@]}
for ((r = 0; r < rounds; r++)); do
  for ((k = 0; k < n; k++)); do
    arm=${arms[$(( (r + k) % n + 1 ))]}
    label=${arm%%=*}; bin=${arm#*=}
    text=$("$bin" "${args[@]}" 2>&1)
    for m in "${metrics[@]}"; do
      name=${m%%:*}; re=${m#*:}
      v=$(print -r -- "$text" | sed -n -E "s/${re}/\1/p" | head -1)
      [[ -n $v ]] && print -r -- "$name"$'\t'"$label"$'\t'"$r"$'\t'"$v" >> "$out"
    done
  done
done
awk -F'\t' '
  { key = $1 "\t" $2; n[key]++; v[key, n[key]] = $4 + 0 }
  END {
    for (key in n) {
      m = n[key]
      for (i = 1; i <= m; i++) a[i] = v[key, i]
      for (i = 2; i <= m; i++) { x = a[i]; j = i - 1; while (j > 0 && a[j] > x) { a[j + 1] = a[j]; j-- } a[j + 1] = x }
      med = (m % 2) ? a[(m + 1) / 2] : (a[m / 2] + a[m / 2 + 1]) / 2
      printf "%-28s n=%-3d min %-12.6g median %-12.6g max %-12.6g\n", key, m, a[1], med, a[m]
    }
  }' "$out" | sort
