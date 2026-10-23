#!/bin/bash
# Runs every deploy-tooling harness in the repo. One command = one gate:
#   tests/run-all.sh
# (cfg-backup, ioncube-mirror, post-swap-smoke, retro-swapbak, restore).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
rc=0
for t in cfg-backup-test.sh ioncube-mirror-test.sh smoke-test.sh \
         retro-test.sh restore-test.sh cvecheck-test.sh; do
  echo "===== $t ====="
  if ! "$HERE/$t"; then rc=1; fi
  echo
done
if [ "$rc" -eq 0 ]; then
  echo "ALL DEPLOY-TOOLING TESTS PASSED"
else
  echo "SOME DEPLOY-TOOLING TESTS FAILED"
fi
exit "$rc"
