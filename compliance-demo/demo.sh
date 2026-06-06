#!/usr/bin/env bash
#
# demo.sh — drives the slide-9 storyboard end to end on a single host.
# Intended for a quick live run on the SNO homelab or a demo VM.
#
# Usage:
#   ./demo.sh baseline    # Beat 1: enforce baseline, show host green
#   ./demo.sh drift       # Beat 2: inject drift (PermitRootLogin yes)
#   ./demo.sh detect      # Beat 3: audit-only scan, prove drift is seen
#   ./demo.sh remediate   # Beat 4: re-assert baseline, show green again
#   ./demo.sh reset       # Clean up so you can re-run from scratch
#
# Beat 5 (ServiceNow / audit log) happens automatically inside `remediate`
# via the playbook's post_tasks. Tail /var/log/sshd_compliance_audit.log to show it.

set -euo pipefail
SSHD_CONFIG="${SSHD_CONFIG:-/etc/ssh/sshd_config}"
PLAYBOOK="playbooks/remediate_sshd.yml"

banner() { printf '\n\033[1;31m==== %s ====\033[0m\n' "$1"; }

case "${1:-}" in
  baseline)
    banner "BEAT 1 — Enforce baseline (host should end COMPLIANT)"
    ansible-playbook "$PLAYBOOK"
    ;;
  drift)
    banner "BEAT 2 — Inject drift: PermitRootLogin yes"
    sudo sed -i 's/^#\?\s*PermitRootLogin.*/PermitRootLogin yes/' "$SSHD_CONFIG"
    sudo systemctl restart sshd 2>/dev/null || sudo systemctl restart ssh
    echo "Drift injected. Current setting:"
    grep -i '^PermitRootLogin' "$SSHD_CONFIG" || true
    ;;
  detect)
    banner "BEAT 3 — Audit-only scan (reports drift, changes nothing)"
    ansible-playbook "$PLAYBOOK" -e sshd_check_only=true
    ;;
  remediate)
    banner "BEAT 4 + 5 — Remediate and log the audit event"
    ansible-playbook "$PLAYBOOK"
    banner "Audit log (Beat 5 evidence)"
    sudo tail -n 3 /var/log/sshd_compliance_audit.log 2>/dev/null || echo "(no log yet)"
    ;;
  reset)
    banner "RESET — restore a clean compliant baseline for a fresh run"
    ansible-playbook "$PLAYBOOK"
    sudo truncate -s 0 /var/log/sshd_compliance_audit.log 2>/dev/null || true
    echo "Reset complete."
    ;;
  *)
    echo "Usage: $0 {baseline|drift|detect|remediate|reset}"
    exit 1
    ;;
esac
