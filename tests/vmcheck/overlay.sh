#!/bin/bash
set -euo pipefail

# Execute this code path on the host
if test -z "${INSIDE_VM:-}"; then
    . ${commondir}/libvm.sh
    vm_setup

    if ! vm_ssh_wait 30; then
      echo "ERROR: A running VM is required for 'make vmcheck'."
      exit 1
    fi

    set -x

    cd ${topsrcdir}

    # Use a lock in case we're called in parallel (make install might fail).
    # Plus, we can just share the same install tree, and sharing is caring!
    flock insttree.lock sh -ec \
      '[ ! -d insttree ] || exit 0
       DESTDIR=$(pwd)/insttree
       make install DESTDIR=${DESTDIR}
       for san in a t ub; do
         if eu-readelf -d ${DESTDIR}/usr/bin/rpm-ostree | \
              grep -q \"NEEDED.*lib${san}san\"; then
           echo \"Installing extra sanitizier: lib${san}san\"
           cp /usr/lib64/lib${san}san*.so.* ${DESTDIR}/usr/lib64
         fi
       done
       touch ${DESTDIR}/.completed'
    [ -f insttree/.completed ]

    vm_rsync

    $SSH "env INSIDE_VM=1 /var/roothome/sync/tests/vmcheck/overlay.sh"
    vm_reboot
    exit 0
fi

set -x

# And then this code path in the VM

commit=$(rpm-ostree status --json | \
  python -c '
import sys, json;
deployments = json.load(sys.stdin)["deployments"]
for deployment in deployments:
  if deployment["booted"]:
    print deployment["checksum"]
    exit()')

if [[ -z $commit ]] || ! ostree rev-parse $commit; then
  echo "Error while determining current commit" >&2
  exit 1
fi

cd /ostree/repo/tmp
rm vmcheck -rf
ostree checkout $commit vmcheck --fsync=0
# ✀✀✀ BEGIN hack for https://github.com/projectatomic/rpm-ostree/pull/693 ✀✀✀
rm -f vmcheck/usr/etc/{.pwd.lock,passwd-,group-,shadow-,gshadow-,subuid-,subgid-}
# ✀✀✀ END hack for https://github.com/projectatomic/rpm-ostree/pull/693 ✀✀✀
# Now, overlay our built binaries
rsync -rlv /var/roothome/sync/insttree/usr/ vmcheck/usr/
ostree refs --delete vmcheck || true
ostree commit -b vmcheck -s '' --tree=dir=vmcheck --link-checkout-speedup
ostree admin deploy vmcheck
