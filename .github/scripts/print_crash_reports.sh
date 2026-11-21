#!/usr/bin/env bash
set +e

for dir in "$HOME/Library/Logs/DiagnosticReports" /Library/Logs/DiagnosticReports; do
  [ -d "$dir" ] || continue
  find "$dir" -maxdepth 2 -type f \( -iname '*constellar*' -o -iname '*Runner*' \) -mmin -240 2>/dev/null | while read -r report; do
    printf '=== CRASH REPORT: %s ===\n' "$report"
    head -c 60000 "$report"
    printf '\n=== END CRASH REPORT ===\n'
  done
done
exit 0
