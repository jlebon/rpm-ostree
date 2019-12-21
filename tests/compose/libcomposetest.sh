dn=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../common/libtest.sh
. "${dn}/../common/libtest.sh"

export repo=$PWD/repo
export treefile=$PWD/config/manifest.json
treeref=$(jq -r .ref < "${treefile}"); export treeref

# ensures workdir sticks around so we can debug if needed
export RPMOSTREE_PRESERVE_TMPDIR=1

pyedit() {
    local f=$1; shift
    # this is a bit underhanded; we read it in as yaml, since it can read json
    # too, but serialize back as json (which is also valid yaml). that way we
    # can use all these functions transparently with yaml and json treefiles
    cat >pyedit.py <<EOF
import sys, json, yaml
tf=yaml.safe_load(sys.stdin)
${1}
json.dump(tf, sys.stdout)
EOF
    python3 ./pyedit.py < "${f}" > "${f}.new"
    rm -f ./pyedit.py
    mv "${f}"{.new,}
}

treefile_pyedit() {
    pyedit "${treefile}" "$@"
}

treefile_set() {
    treefile_pyedit "tf['""$1""'] = $2"
}

treefile_del() {
    treefile_pyedit "
try:
  del tf['$1']
except KeyError:
  pass"
}

treefile_set_ref() {
    treefile_set ref "$@"
    rpm-ostree compose tree --print-only "${treefile}" > tmp.json
    treeref=$(jq -r .ref < tmp.json); export treeref
    rm tmp.json
}

treefile_append() {
    treefile_pyedit "
if '$1' not in tf:
  tf['$1'] = $2
else:
  tf['$1'] += $2"
}

# for tests that need direct control on rpm-ostree
export compose_base_argv="\
    --unified-core \
    --repo=${repo} \
    --cachedir=${test_tmpdir}/cache \
    --ex-lockfile=config/manifest-lock.x86_64.json \
    --ex-lockfile=config/manifest-lock.overrides.x86_64.yaml"

# and create this now for tests which only use `compose_base_argv`
mkdir -p cache

runcompose() {
  # keep this function trivial and the final command runasroot to mostly steer
  # clear of huge footgun of set -e not working in function calls in if-stmts
  runasroot rpm-ostree compose tree ${compose_base_argv} \
    --write-composejson-to=compose.json "${treefile}" "$@"
}

# NB: One difference from cosa here is we don't use `sudo`. I think there's an
# issue with sudo under parallel not getting signals propagated from the
# controlling terminal? Anyway, net result is we can end up with a bunch of
# rpm-ostree processes leaking in the background still running. So for now, one
# has to run this testsuite as root, or use unprivileged. XXX: to investigate.

runasroot() {
    if has_privileges; then
        "$@"
    else
        runvm "$@"
    fi
}

# The two functions below were taken and adapted from coreos-assembler. We
# should look into sharing this code more easily.

_privileged=
has_privileges() {
    if [ -z "${_privileged:-}" ]; then
        if [ -n "${FORCE_UNPRIVILEGED:-}" ]; then
            echo "Detected FORCE_UNPRIVILEGED; using virt"
            _privileged=0
        elif ! capsh --print | grep -q 'Bounding.*cap_sys_admin'; then
            echo "Missing CAP_SYS_ADMIN; using virt"
            _privileged=0
        elif [ "$(id -u)" != "0" ]; then
            echo "Not running as root; using virt"
            _privileged=0
        else
            _privileged=1
        fi
    fi
    [ ${_privileged} == 1 ]
}

runvm() {
    local vmpreparedir=tmp/supermin.prepare
    local vmbuilddir=tmp/supermin.build

    # just build it once (unlike in cosa where these dirs hang out, these test
    # dirs are ephemeral -- we could probably share across tests too really...)
    if [ ! -d "${vmbuilddir}" ]; then
        rm -rf "${vmpreparedir}" "${vmbuilddir}"
        mkdir -p "${vmpreparedir}" "${vmbuilddir}"

        qemu-img create -f qcow2 tmp/cache.qcow2 8G
        LIBGUESTFS_BACKEND=direct virt-format --filesystem=xfs -a tmp/cache.qcow2

        # we just import the strict minimum here that rpm-ostree needs
        local rpms="rpm-ostree bash rpm-build coreutils selinux-policy-targeted dhcp-client util-linux"
        # shellcheck disable=SC2086
        supermin --prepare --use-installed -o "${vmpreparedir}" $rpms

        # the reason we do a heredoc here is so that the var substition takes
        # place immediately instead of having to proxy them through to the VM
        cat > "${vmpreparedir}/init" <<EOF
#!/bin/bash
set -xeuo pipefail
export PATH=/usr/sbin:$PATH

mount -t proc /proc /proc
mount -t sysfs /sys /sys
mount -t devtmpfs devtmpfs /dev

LANG=C /sbin/load_policy -i

# load kernel module for 9pnet_virtio for 9pfs mount
/sbin/modprobe 9pnet_virtio

# need fuse module for rofiles-fuse/bwrap during post scripts run
/sbin/modprobe fuse

# set up networking
/usr/sbin/dhclient eth0

# set the umask so that anyone in the group can rwx
umask 002

# automatically proxy all rpm-ostree specific variables
$(env | grep ^RPMOSTREE | xargs -r echo export)

# we only need two dirs
mkdir -p "${fixtures}" "${test_tmpdir}"
mount -t 9p -o ro,trans=virtio,version=9p2000.L cache "${fixtures}"
mount -t 9p -o rw,trans=virtio,version=9p2000.L testdir "${test_tmpdir}"
mount /dev/sdb1 "${test_tmpdir}/cache"
cd "${test_tmpdir}"

# hack for non-unified mode
rm -rf cache/workdir && mkdir cache/workdir

rc=0
sh -x tmp/cmd.sh || rc=\$?
echo \$rc > tmp/cmd.sh.rc
if [ -b /dev/sdb1 ]; then
    /sbin/fstrim -v cache
fi
/sbin/reboot -f
EOF
      chmod a+x "${vmpreparedir}"/init
      (cd "${vmpreparedir}" && tar -czf init.tar.gz --remove-files init)
      supermin --build "${vmpreparedir}" --size 5G -f ext2 -o "${vmbuilddir}"
    fi

    echo "$@" > tmp/cmd.sh

    #shellcheck disable=SC2086
    qemu-kvm \
        -nodefaults -nographic -m 1536 -no-reboot -cpu host \
        -kernel "${vmbuilddir}/kernel" \
        -initrd "${vmbuilddir}/initrd" \
        -netdev user,id=eth0,hostname=supermin \
        -device virtio-net-pci,netdev=eth0 \
        -device virtio-scsi-pci,id=scsi0,bus=pci.0,addr=0x3 \
        -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci,rng=rng0 \
        -drive if=none,id=drive-scsi0-0-0-0,snapshot=on,file="${vmbuilddir}/root" \
        -device scsi-hd,bus=scsi0.0,channel=0,scsi-id=0,lun=0,drive=drive-scsi0-0-0-0,id=scsi0-0-0-0,bootindex=1 \
        -drive if=none,id=drive-scsi0-0-0-1,discard=unmap,file=tmp/cache.qcow2 \
        -device scsi-hd,bus=scsi0.0,channel=0,scsi-id=0,lun=1,drive=drive-scsi0-0-0-1,id=scsi0-0-0-1 \
        -virtfs local,id=cache,path="${fixtures}",security_model=none,mount_tag=cache \
        -virtfs local,id=testdir,path="${test_tmpdir}",security_model=none,mount_tag=testdir \
        -serial stdio -append "root=/dev/sda console=ttyS0 selinux=1 enforcing=0 autorelabel=1"

    if [ ! -f tmp/cmd.sh.rc ]; then
        fatal "Couldn't find rc file, something went terribly wrong!"
    fi
    return "$(cat tmp/cmd.sh.rc)"
}
