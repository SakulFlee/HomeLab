#!/usr/bin/env bash
# Mutation check for incus/apply.sh: revert each fix, run the suite that covers
# it, and REQUIRE a failure. A suite that passes tells you nothing unless it can
# fail, and three separate times in this change a fix was believed to be covered
# by a test that would not have noticed it going.
#
# The mutations live in apply-mutations.tsv rather than inline, because embedding
# python source in a shell heredoc meant every escaping mistake showed up as
# "site not found" -- indistinguishable from a real result, and it hid the cause
# of one for three runs. Tab-separated, one line per mutation, matched by
# SUBSTRING of a whole line. No regex, no quoting to get wrong.
#
#   label <TAB> suite <TAB> match <TAB> replacement <TAB> skip_next
#
# skip_next=1 deletes the following line, for the mutations that collapse a
# two-line continuation into one.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

APPLY_FILE=incus/apply.sh
SPECS=incus/apply-mutations.tsv
[[ -f $APPLY_FILE ]] || { echo "FATAL: $APPLY_FILE not found"; exit 99; }
[[ -f $SPECS ]] || { echo "FATAL: $SPECS not found"; exit 99; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp "$APPLY_FILE" "$WORK/good.sh"

suite_for() {
  case $1 in
    hooks)   echo apply-hooks-test.sh ;;
    forward) echo apply-forward-test.sh ;;
    *)       echo "apply-$1-test.sh" ;;
  esac
}

fails=0
total=0

while IFS=$'\t' read -r label kind match replace skip_next nth; do
  [[ -z ${label:-} || $label == label ]] && continue
  total=$((total + 1))
  suite=$(suite_for "$kind")
  printf '  %-38s ' "$label"

  if ! python3 incus/apply-mutate.py \
        "$WORK/good.sh" "$WORK/mut.sh" "$match" "$replace" "$skip_next" "${nth:-1}" \
        >"$WORK/why" 2>&1; then
    printf 'HARNESS ERROR -- %s\n' "$(head -3 "$WORK/why" | tr '\n' ' ')"
    fails=$((fails + 1))
    continue
  fi

  if cmp -s "$WORK/good.sh" "$WORK/mut.sh"; then
    printf 'HARNESS ERROR -- the mutation changed nothing\n'
    fails=$((fails + 1))
    continue
  fi

  # bash -n first: a mutation that does not even parse would "fail" the suite for
  # the wrong reason, which is the mistake this file exists to avoid.
  if ! bash -n "$WORK/mut.sh" 2>"$WORK/syn"; then
    printf 'HARNESS ERROR -- the mutation does not parse: %s\n' "$(head -1 "$WORK/syn")"
    fails=$((fails + 1))
    continue
  fi

  out="$WORK/out"
  if APPLY="$WORK/mut.sh" timeout 300 "./incus/$suite" >"$out" 2>&1; then
    printf 'NOT CAUGHT  <-- %s does not test this\n' "$suite"
    fails=$((fails + 1))
    continue
  fi

  # Distinguish a real catch (checks failed) from a crash (the suite gave up).
  # "Suite exited non-zero with no failing check" is not evidence of anything --
  # a FATAL guard firing counts the same as a broken test, and one mutation
  # earlier in this file was caught only that way.
  nfail=$(grep -c 'FAIL' "$out" || true)
  nfatal=$(grep -c 'FATAL' "$out" || true)
  if [[ $nfail -eq 0 ]]; then
    printf 'NOT CAUGHT (no failing check; %s FATAL) <-- exits non-zero for the wrong reason\n' "$nfatal"
    fails=$((fails + 1))
    continue
  fi
  printf 'caught (%d failing check(s)%s)\n' "$nfail" \
    "$([[ $nfatal -gt 0 ]] && printf ', %d FATAL' "$nfatal")"
done <"$SPECS"

echo
echo "  $total mutation(s), $fails not caught"
if [[ $fails -eq 0 ]]; then
  echo "every mutation is covered by a failing check"
else
  echo "the suites cannot be trusted until these are caught"
fi
exit $((fails > 0))
