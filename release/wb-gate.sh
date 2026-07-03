#!/bin/bash
# Gate: new launcher elf vs reference (stock-bak or known-good).
# Args: READELF NM provided via env. Pairs read from /gate dir.
# Usage inside container: bash /gate/wb-gate.sh <platform> <minui|minarch> <is_minui:0|1>
set -u
RE="${READELF:?}"; NM="${NM:?}"
G=/gate
plat="$1"; kind="$2"; ismin="$3"
new="$G/$plat.$kind.new"; ref="$G/$plat.$kind.ref"
fail=0
echo "===== $plat $kind ====="

i_new=$("$RE" -l "$new" 2>/dev/null | sed -n 's/.*program interpreter: \(.*\)\]/\1/p')
i_ref=$("$RE" -l "$ref" 2>/dev/null | sed -n 's/.*program interpreter: \(.*\)\]/\1/p')
echo "interp new=[$i_new] ref=[$i_ref]"
[ "$i_new" = "$i_ref" ] || { echo "  FAIL interp mismatch"; fail=1; }

n_need=$("$RE" -d "$new" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | sort -u)
r_need=$("$RE" -d "$ref" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | sort -u)
echo "NEEDED new: $(echo $n_need)"
echo "NEEDED ref: $(echo $r_need)"
extra=$(comm -23 <(echo "$n_need") <(echo "$r_need"))
if [ -n "$extra" ]; then echo "  FAIL NEEDED not subset, extra: $(echo $extra)"; fail=1; else echo "  NEEDED subset OK"; fi

g_new=$("$RE" -V "$new" 2>/dev/null | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -V | tail -1)
g_ref=$("$RE" -V "$ref" 2>/dev/null | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -V | tail -1)
echo "GLIBC max new=$g_new ref=$g_ref"
if [ -n "$g_new" ]; then
  hi=$(printf '%s\n%s\n' "$g_new" "$g_ref" | sort -V | tail -1)
  [ "$hi" = "$g_ref" ] || { echo "  FAIL GLIBC new>ref"; fail=1; }
  [ -z "$g_ref" ] && { echo "  FAIL ref has no GLIBC ver but new does"; fail=1; }
  echo "  GLIBC floor OK"
else
  echo "  new has no GLIBC versioned syms (static-ish) OK"
fi

if [ "$ismin" = "1" ]; then
  if "$NM" "$new" 2>/dev/null | grep -q ' Lodor_drawList$\| Lodor_drawList'; then
    echo "  Lodor_drawList PRESENT"
  else
    echo "  FAIL Lodor_drawList missing"; fail=1
  fi
fi

if [ "$fail" = "0" ]; then echo "RESULT $plat $kind: PASS"; else echo "RESULT $plat $kind: FAIL"; fi
exit $fail
