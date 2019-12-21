#!/bin/bash
set -euo pipefail

# freeze on a specific commit for tests for reproducibility and since it should
# always work to target older treefiles
FEDORA_COREOS_CONFIG_COMMIT=088fc2dec535aca392958e9c30c17cf19ef4b568

dn=$(cd "$(dirname "$0")" && pwd)
topsrcdir=$(cd "$dn/.." && pwd)
commondir=$(cd "$dn/common" && pwd)
export topsrcdir commondir

# shellcheck source=common/libtest-core.sh
. "${commondir}/libtest-core.sh"

read -r -a tests <<< "$(filter_tests "${topsrcdir}/tests/compose")"
if [ ${#tests[*]} -eq 0 ]; then
  echo "No tests selected; mistyped filter?"
  exit 0
fi

JOBS=${JOBS:-$(ncpus)}

# re-use the same FCOS config and RPMs if it already exists
if [ ! -d compose-cache ]; then
  mkdir -p compose-cache

  # first, download all the RPMs into a directory
  echo "Caching test fixtures in compose-cache/"

  # Really want to use cosa fetch for this and just share the pkgcache repo.
  # Though for now we still need to support non-unified mode. Once we don't, we
  # can clean this up.
  pushd compose-cache
  git clone https://github.com/coreos/fedora-coreos-config config
  pushd config
  git checkout "${FEDORA_COREOS_CONFIG_COMMIT}"
  # we flatten the treefile to make it easier to manipulate in tests (we have
  # lots of tests that check for include logic already)
  rpm-ostree compose tree --print-only manifest.yaml > manifest.json
  rm manifest.yaml
  mv manifests/{passwd,group} .
  rm -rf manifests/
  popd

  mkdir cachedir
  # we just need a repo so we can download stuff (but see note above about
  # sharing pkgcache repo in the future)
  ostree init --repo=repo --mode=archive
  rpm-ostree compose tree --unified-core --download-only-rpms --repo=repo \
    config/manifest.json --cachedir cachedir \
    --ex-lockfile config/manifest-lock.x86_64.json \
    --ex-lockfile config/manifest-lock.overrides.x86_64.yaml
  rm -rf repo
  (cd cachedir && createrepo_c .)
  echo -e "[cache]\nbaseurl=$(pwd)/cachedir\ngpgcheck=0" > config/cache.repo
  pushd config
  python3 -c '
import sys, json
y = json.load(sys.stdin)
y["repos"] = ["cache"]
json.dump(y, sys.stdout)' < manifest.json > manifest.json.new
  mv manifest.json{.new,}
  git add .
  git -c user.email="composetest@localhost.com" -c user.name="composetest" \
    commit -am 'modifications for tests'
  popd
  popd
fi

echo "Running ${#tests[*]} tests ${JOBS} at a time"

outputdir="${topsrcdir}/compose-logs"
fixtures="$(pwd)/compose-cache"
echo "Test results outputting to ${outputdir}/"

echo -n "${tests[*]}" | parallel -d' ' -j "${JOBS}" --line-buffer \
  "${topsrcdir}/tests/compose/runtest.sh" "${outputdir}" "${fixtures}"
