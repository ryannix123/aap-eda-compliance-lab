# Installing AAP-with-EDA on OCP SNO

Automated install of the Ansible Automation Platform Operator and an
AAP-with-EDA instance on a Single Node OpenShift cluster (tested target:
**OCP 4.21 SNO**).

## What you get

The 2.7 operator deploys everything under one `AnsibleAutomationPlatform` CR and
a unified platform gateway:

- **Automation controller** — job templates, inventories, credentials
- **Event-Driven Ansible (EDA)** — rulebook activations (the point of this lab)
- **Automation hub** — local collection hosting (optional; needs RWX storage)
- **Platform gateway** — single UI/API, with Routes auto-created by the operator

## Prerequisites

- An OCP 4.21 SNO cluster, `oc` logged in as **cluster-admin**.
- Sizing: Red Hat's tested AAP-on-SNO "growth" topology is **16 CPU / 32 GB /
  128 GB disk / 3000 IOPS**. Your 24-core / 64 GB SNO clears this — just don't
  run the full AAP stack and the RHOAI/Granite GPU workload at full tilt
  simultaneously. The CR ships with reduced resource *requests* so pods schedule
  cleanly alongside OpenShift's own control plane.
- A **ReadWriteMany** storage class if you want automation hub. No RWX? Install
  with `-e hub_disabled=true` and pull collections from Galaxy instead.
- Control machine: `ansible-core`, the `kubernetes.core` collection, and the
  `kubernetes` Python package. Your kubeconfig is used for auth.

## Install

```bash
cd install/aap-operator/playbooks
ansible-galaxy collection install -r requirements.yml
pip install kubernetes

# With automation hub (set your RWX class):
ansible-playbook install_aap.yml -e rwx_storage_class=<your-rwx-class>

# Or without hub (no RWX storage needed):
ansible-playbook install_aap.yml -e hub_disabled=true
```

The playbook applies the operator subscription, waits for the CSV to succeed,
applies the AAP CR, waits for the gateway, then prints the **gateway URL,
username (`admin`), and the generated admin password**.

If the password isn't ready when the playbook finishes:

```bash
oc get secret aap-admin-password -n aap -o jsonpath='{.data.password}' | base64 -d ; echo
```

## Files

| File | Purpose |
|------|---------|
| `manifests/01-operator-subscription.yaml` | Namespace, OperatorGroup, Subscription (channel `stable-2.7`) |
| `manifests/02-aap-instance.yaml` | The `AnsibleAutomationPlatform` CR — EDA enabled, homelab-sized |
| `playbooks/install_aap.yml` | Applies everything, waits for readiness, prints access details |
| `playbooks/requirements.yml` | `kubernetes.core` collection |

## After install — wire up the compliance demo

1. **Projects** → add this Git repo, point at `compliance-demo/`.
2. **Credentials** → a Linux machine credential (SSH key/user for the Proxmox
   Linux VMs) and a Windows machine credential (WinRM user for `win2022-demo`).
   Optionally a ServiceNow credential for the audit step.
3. **Inventories** → import `compliance-demo/inventory/hosts.ini` (or recreate
   the `linux_fleet` / `windows_fleet` groups), attach the credentials.
4. **Job Template** → `SSHD Baseline - Remediate`, playbook
   `playbooks/remediate_sshd.yml`, inventory = `all`.
5. **Decision Environment** → one containing the `ansible.eda` collection.
6. **Rulebook Activation** → `rulebooks/sshd_drift_remediation.yml`, which calls
   the job template on each drift event. The operator exposes the EDA webhook as
   a Route — note its URL for your drift-signal `curl` and any Windows SIEM/WEF
   alerts.

See the repo root README for the full end-to-end demo flow.

## Uninstall

```bash
oc delete ansibleautomationplatform aap -n aap
oc delete subscription ansible-automation-platform-operator -n aap
oc delete operatorgroup aap-operator-group -n aap
# Then remove the CSV (name varies by version):
oc get csv -n aap   # find the aap-operator CSV
oc delete csv <aap-operator-csv-name> -n aap
oc delete namespace aap
```
