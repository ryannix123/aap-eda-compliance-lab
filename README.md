# AAP + EDA Compliance Lab

<!--
  NOTE: The banner image below is hot-linked from a Medium/Miro CDN URL.
  Before making this repo fully public, replace it with an image you own or
  are licensed to use (commit it under docs/img/ and reference it relatively),
  and add proper attribution if it comes from a third party. Hot-linked CDN
  URLs can break without warning and may carry licensing restrictions.
-->
![Ansible Automation Platform](https://miro.medium.com/v2/resize:fit:1400/format:webp/0*mgINP92VblNMKmS3.jpg)

A complete, runnable homelab that demonstrates **continuous, event-driven
security compliance** with Red Hat Ansible Automation Platform — enforcing a
hardening baseline across **RHEL, Ubuntu, SUSE, and Windows** from a single
control plane, and **auto-remediating drift the instant it happens** with
Event-Driven Ansible (EDA).

It's the practical answer to a common question: *"We use Puppet to manage Linux
and Windows — what does moving to Ansible actually look like, and how do we keep
Puppet's continuous-enforcement behavior?"* The answer here is EDA, demonstrated
end to end.

> Built as a reference architecture for a real customer evaluation. It pairs a
> one-platform consolidation story with working code you can stand up yourself.

## What it shows

- **One role, every platform.** A single Ansible role detects the OS and enforces
  an equivalent baseline on Linux (OpenSSH hardening) and Windows (RDP/registry
  security policy). One job run hardens the whole fleet.
- **Drift in → remediation out → audit logged.** Change a hardened setting and an
  EDA rulebook fires within seconds, restores the baseline, and writes an audit
  record (ServiceNow incident, with a local JSON log fallback).
- **Event-driven, not interval-based.** No 30-minute convergence window — a
  monitoring alert, file change, service restart, or webhook triggers remediation
  immediately. This is the capability people miss when leaving an agent-based
  config tool, and EDA restores (and upgrades) it.

## The homelab topology

A two-box split on a flat home VLAN. AAP runs on OpenShift; the managed hosts are
ordinary VMs reached over SSH/WinRM across the LAN.

```
                      Flat home VLAN
   ┌─────────────────────────────────────────────────────────┐
   │                                                           │
   │   ┌───────────────────────────┐     ┌──────────────────┐ │
   │   │  OCP 4.21 SNO box          │     │  Proxmox box     │ │
   │   │  24 core / 64 GB / 3060Ti  │     │  10 core / 64 GB │ │
   │   │                            │     │  1 TB NVMe       │ │
   │   │  ┌──────────────────────┐  │     │                  │ │
   │   │  │ AAP Operator (2.7)   │  │ SSH │  rhel9-demo      │ │
   │   │  │  • controller        │──┼─────┼─▶ ubuntu-demo    │ │
   │   │  │  • EDA               │  │WinRM│  suse-demo       │ │
   │   │  │  • hub + gateway     │  │─────┼─▶ win2022-demo   │ │
   │   │  └──────────────────────┘  │     │                  │ │
   │   │     ▲ EDA webhook Route    │     │  (drift signals  │ │
   │   │     └──────────────────────┼─────┼───  POST back)   │ │
   │   └───────────────────────────┘     └──────────────────┘ │
   └─────────────────────────────────────────────────────────┘
```

- **SNO box** runs the AAP control plane (and your RHOAI/Granite GPU work).
- **Proxmox box** runs the four managed-host VMs the role targets.
- **Flat VLAN** means SSH (22), WinRM (5986), and the EDA webhook Route (443) all
  just work in both directions — no routing or firewall plumbing required.

## Repository layout

```
aap-eda-compliance-lab/
├── README.md                          ← you are here
├── install/aap-operator/              ← stand up AAP-with-EDA on OCP SNO
│   ├── README.md
│   ├── manifests/                     ← operator Subscription + AAP CR (EDA on)
│   └── playbooks/install_aap.yml      ← automated install + access details
├── compliance-demo/                   ← the cross-platform compliance content
│   ├── README.md                      ← demo flow, slide-9 storyboard mapping
│   ├── roles/enforce_sshd_baseline/   ← OS-dispatching role (linux.yml/windows.yml)
│   ├── playbooks/remediate_sshd.yml   ← what EDA fires: enforce + audit log
│   ├── rulebooks/                      ← EDA rulebooks (AAP + standalone)
│   ├── inventory/hosts.ini            ← linux_fleet + windows_fleet
│   └── demo.sh                        ← drives the 5-beat live demo
└── docs/
    └── proxmox-build-sheet.md         ← build the 4 managed-host VMs
```

## Quick start

Three phases. Do them in order.

### 1. Build the managed-host fleet (Proxmox)
Follow [`docs/proxmox-build-sheet.md`](docs/proxmox-build-sheet.md) to create and
prep `rhel9-demo`, `ubuntu-demo`, `suse-demo`, and `win2022-demo`, then fill in
their IPs in `compliance-demo/inventory/hosts.ini`.

### 2. Install AAP-with-EDA (OCP SNO)
```bash
cd install/aap-operator/playbooks
ansible-galaxy collection install -r requirements.yml && pip install kubernetes
ansible-playbook install_aap.yml -e rwx_storage_class=<your-rwx-class>
# (no RWX storage? add -e hub_disabled=true)
```
See [`install/aap-operator/README.md`](install/aap-operator/README.md) for
details and post-install wiring (Project, credentials, Job Template, Rulebook
Activation).

### 3. Run the compliance demo
Wire the Project/Job Template/Rulebook Activation per the install README, then
follow the five-beat storyboard in
[`compliance-demo/README.md`](compliance-demo/README.md):

```
baseline → inject drift → EDA detects → auto-remediate → audit logged
```

For a controller-free dry run on a single host, `compliance-demo/demo.sh` walks
the same five beats with plain `ansible-playbook` + `ansible-rulebook`.

## Requirements at a glance

- OCP 4.21 SNO, `oc` as cluster-admin; tested AAP-on-SNO floor is 16 CPU / 32 GB
  / 128 GB / 3000 IOPS (your 24-core / 64 GB box clears it).
- Proxmox host with capacity for four small VMs (~22 GB RAM total; see build sheet).
- Collections: `kubernetes.core` (install), and `ansible.eda`, `servicenow.itsm`,
  `ansible.windows`, `community.windows`, `ansible.posix` (demo) — see the
  respective `requirements.yml` files.
- Red Hat subscriptions for the RHEL VM and AAP.

## A note on accuracy & versions

Resource minimums, operator channels, and CR fields shift between AAP/OCP
releases. This lab targets **AAP Operator 2.7** (channel `stable-2.7`) and
**OCP 4.21**. Before a production build, re-check the current values in the
[AAP on OpenShift install docs](https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.7/html-single/installing_on_openshift_container_platform/index).

Note that **as of AAP 2.7, Red Hat no longer ships the RPM installer** — the
only supported install paths are the containerized installer and the OpenShift
operator (used here). Anyone still on an RPM-based AAP must migrate. That's a
useful nudge in a consolidation conversation: "stay where you are" isn't a
long-term option for legacy installs either.

## Roadmap: Automation Orchestrator (Technology Preview)

This lab runs entirely on **generally available** AAP 2.7 capabilities —
controller, EDA, and hub. The natural next step Red Hat has announced is the
**Automation Orchestrator**, introduced as a **technology preview** at Red Hat
Summit (May 2026) and slated to become available later in 2026 (roadmapped for
Q3, separate from the 2.7 platform GA). It is **not** part of the GA 2.7
operator install, so it is intentionally **not** wired into this lab.

What it is, and why it matters here:

- **A multi-mode workflow canvas.** The Orchestrator lets you design workflows
  that combine *deterministic* automation (run a playbook), *event-driven*
  automation (react to a signal — exactly what the EDA rulebook in this lab
  does), and *AI-driven* steps (an agent investigates and recommends) on a
  single canvas. If you've used a visual workflow builder like n8n, the canvas
  will feel familiar — but the purpose is narrower and more governed.
- **Governance is the point.** Whether an action originates from a human, an
  event, or an AI agent, it flows through the *same* RBAC checks, approval
  gates, and audit trail. Red Hat positions it as a "trusted execution layer"
  that routes AI-agent intent through human-approved, validated playbooks rather
  than letting agents act directly.
- **This lab is the foundation it builds on.** The detect → event → remediate →
  audit pattern demonstrated here is precisely the kind of governed, event-driven
  workflow the Orchestrator is designed to compose with AI-driven steps. Stand
  up this lab today; the Orchestrator becomes the layer that unifies it with
  agentic workflows when it ships.

> Status caveat: technology-preview features are not supported for production and
> may change before GA. Treat this section as forward-looking context for the
> consolidation story, not as something deployable from this repo today. Verify
> current status in the
> [AAP 2.7 release notes](https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.7).

## License

MIT — see [LICENSE](LICENSE). These are personal projects and reference material,
not official Red Hat products or supported configurations.
