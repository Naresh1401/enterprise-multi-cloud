#!/usr/bin/env bash
# Lists every resource a deployment target would create, from the dev plan in its
# tests/plan.tftest.hcl, which runs against mock providers: no cloud account or credentials
# needed, only OpenTofu.
#
#   scripts/inventory.sh            # all six targets
#   scripts/inventory.sh aws gke    # some of them
#
# The AKS dry run leaves out the nodes' AcrPull role assignment, which reads an identity AKS
# only fills in after the cluster exists (see infra/aks/tests/plan.tftest.hcl).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

folders=("$@")
if [ "${#folders[@]}" -eq 0 ]; then folders=(aws eks gcp gke azure aks); fi

for folder in "${folders[@]}"; do
  echo "== infra/${folder}"
  (
    cd "infra/${folder}"
    tofu init -backend=false -input=false >/dev/null
    tofu test -verbose -no-color -filter=tests/plan.tftest.hcl
  ) | awk '
    /^  run "/ { runs++; next }
    runs == 1 && match($0, /^ +# .* will be (created|read during apply)$/) {
      line = $0
      sub(/^ +# /, "", line)
      sub(/ will be (created|read during apply)$/, "", line)
      print "  " line
    }
  '
done
