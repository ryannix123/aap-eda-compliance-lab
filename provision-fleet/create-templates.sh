#!/usr/bin/env bash
#
# create-templates.sh  —  RUN THIS ON THE PROXMOX HOST (as root), ONE TIME.
#
# Downloads RHEL / Ubuntu / SUSE cloud images (qcow2) and converts each into a
# Proxmox VM *template* with a cloud-init drive attached. After this runs once,
# the Ansible playbook (provision_fleet.yml) clones these templates in seconds
# and cloud-init configures each clone — no installer, no ISOs.
#
# Idempotent: skips any template VMID that already exists.
#
# ---------------------------------------------------------------------------
# PREREQUISITES on the Proxmox host:
#   - A storage pool that supports images (default 'local-lvm' assumed below).
#   - 'local' storage for snippets (cloud-init) — enable "Snippets" content type
#     on the 'local' storage in the Proxmox UI: Datacenter > Storage > local > Edit.
#   - Internet egress to download the qcow2 images.
#
# RHEL NOTE: Red Hat's RHEL KVM guest image requires a (free) developer login to
# download. There is no anonymous direct URL. Two options:
#   (a) Manually download rhel-9.x-x86_64-kvm.qcow2 from
#       https://access.redhat.com/downloads (RHEL > KVM Guest Image), scp it to
#       the Proxmox host, and set RHEL_LOCAL_QCOW below to its path.
#   (b) Use CentOS Stream 9 / Rocky / Alma as a stand-in (anonymous URL works).
# This script downloads Ubuntu and SUSE automatically and uses the local RHEL
# file if you provide one; otherwise it skips RHEL with a clear message.
# ---------------------------------------------------------------------------

set -euo pipefail

# -------- tunables ----------------------------------------------------------
STORAGE="${STORAGE:-local-lvm}"        # where VM disks live
SNIPPET_STORAGE="${SNIPPET_STORAGE:-local}"  # where cloud-init snippets live
BRIDGE="${BRIDGE:-vmbr0}"              # your LAN bridge
IMG_DIR="${IMG_DIR:-/var/lib/vz/template/qcow}"   # scratch dir for downloads

# Template VMIDs (must be free; clones will use different IDs)
RHEL_TID="${RHEL_TID:-9000}"
UBUNTU_TID="${UBUNTU_TID:-9001}"
SUSE_TID="${SUSE_TID:-9002}"

# Cloud image URLs (override if you want specific point releases)
UBUNTU_URL="${UBUNTU_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"
SUSE_URL="${SUSE_URL:-https://download.opensuse.org/repositories/Cloud:/Images:/Leap_15.6/images/openSUSE-Leap-15.6.x86_64-NoCloud.qcow2}"
# RHEL-family image. Defaults to CentOS Stream 9 (anonymous download). The
# compliance role treats CentOS/Rocky/Alma/RHEL identically as os_family RedHat,
# so the demo behaves the same. To use a real RHEL image instead, download
# rhel-9.x-x86_64-kvm.qcow2 from access.redhat.com and set RHEL_LOCAL_QCOW.
CENTOS_URL="${CENTOS_URL:-https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2}"
RHEL_LOCAL_QCOW="${RHEL_LOCAL_QCOW:-}"

mkdir -p "$IMG_DIR"

banner() { printf '\n\033[1;31m==== %s ====\033[0m\n' "$1"; }

make_template() {
  local tid="$1" name="$2" qcow="$3"
  if qm status "$tid" &>/dev/null; then
    echo "VMID $tid ($name) already exists — skipping."
    return 0
  fi
  banner "Creating template $tid: $name"
  # Create the VM shell
  qm create "$tid" --name "$name" --memory 2048 --cores 2 \
    --net0 "virtio,bridge=${BRIDGE}" --ostype l26 --agent enabled=1
  # Import the qcow2 as the VM's disk
  qm importdisk "$tid" "$qcow" "$STORAGE"
  # Attach it as a scsi disk on a virtio-scsi controller
  qm set "$tid" --scsihw virtio-scsi-single \
    --scsi0 "${STORAGE}:vm-${tid}-disk-0"
  # Add a cloud-init drive
  qm set "$tid" --ide2 "${STORAGE}:cloudinit"
  # Boot from the imported disk; enable serial console (cloud images expect it)
  qm set "$tid" --boot order=scsi0 --serial0 socket --vga serial0
  # Convert to template
  qm template "$tid"
  echo "Template $tid ($name) ready."
}

# -------- Ubuntu ------------------------------------------------------------
banner "Downloading Ubuntu cloud image"
UBUNTU_QCOW="${IMG_DIR}/ubuntu-noble.img"
[ -f "$UBUNTU_QCOW" ] || wget -O "$UBUNTU_QCOW" "$UBUNTU_URL"
make_template "$UBUNTU_TID" "tmpl-ubuntu-2404" "$UBUNTU_QCOW"

# -------- SUSE --------------------------------------------------------------
banner "Downloading openSUSE Leap cloud image"
SUSE_QCOW="${IMG_DIR}/opensuse-leap.qcow2"
[ -f "$SUSE_QCOW" ] || wget -O "$SUSE_QCOW" "$SUSE_URL"
make_template "$SUSE_TID" "tmpl-suse-leap15" "$SUSE_QCOW"

# -------- RHEL family (CentOS Stream 9 by default) --------------------------
if [ -n "$RHEL_LOCAL_QCOW" ] && [ -f "$RHEL_LOCAL_QCOW" ]; then
  banner "Using local RHEL cloud image: $RHEL_LOCAL_QCOW"
  make_template "$RHEL_TID" "tmpl-rhel9" "$RHEL_LOCAL_QCOW"
else
  banner "Downloading CentOS Stream 9 cloud image (RHEL-family stand-in)"
  CENTOS_QCOW="${IMG_DIR}/centos-stream-9.qcow2"
  [ -f "$CENTOS_QCOW" ] || wget -O "$CENTOS_QCOW" "$CENTOS_URL"
  make_template "$RHEL_TID" "tmpl-centos9" "$CENTOS_QCOW"
  echo "Note: used CentOS Stream 9. The compliance role treats it as os_family"
  echo "RedHat, identical to RHEL. To use a real RHEL image, re-run with"
  echo "RHEL_LOCAL_QCOW=/path/to/rhel-9.x-kvm.qcow2"
fi

banner "Done. Templates created:"
qm list | awk 'NR==1 || /tmpl-/'
echo
echo "Next: run the Ansible playbook provision_fleet.yml to clone these into the demo VMs."
