# SSH Baseline Compliance — EDA Demo

A runnable companion to slide 9 of the *One Automation Plane* deck. It proves
the slide-6 thesis on real infrastructure: **drift in → remediation out → audit
logged**, with enforcement triggered by an *event* rather than a 30-minute
convergence window.

The same Ansible **role** runs identically on RHEL, Ubuntu, and SUSE — that's
the cross-platform, "one playbook set" claim from slide 5 made real.

## What's in here

```
sshd-compliance/
├── ansible.cfg
├── requirements.yml                      # ansible.eda, servicenow.itsm, ansible.posix
├── demo.sh                               # drives the 5 slide-9 beats on one host
├── inventory/hosts.ini                   # the linux_fleet group (RHEL/Ubuntu/SUSE)
├── roles/
│   └── enforce_sshd_baseline/            # the cross-platform hardening role
│       ├── defaults/main.yml             # Linux SSH baseline + Windows baseline
│       ├── tasks/main.yml                # OS dispatcher (Linux vs Windows)
│       ├── tasks/linux.yml               # OpenSSH baseline: detect + remediate
│       ├── tasks/windows.yml             # Windows registry/policy baseline
│       ├── handlers/main.yml             # safe sshd restart + Windows svc restart
│       └── meta/main.yml                 # supported platforms (incl. Windows)
├── playbooks/
│   └── remediate_sshd.yml                # what EDA fires: role + ServiceNow/audit log
└── rulebooks/
    ├── sshd_drift_remediation.yml        # AAP version (run_job_template)
    └── sshd_drift_remediation_standalone.yml  # laptop/SNO version (run_playbook)
```

## How it maps to the slide-9 storyboard

| Beat | What you show | Command |
|------|---------------|---------|
| 1 · Healthy baseline | Host enforced to the baseline, reports COMPLIANT | `./demo.sh baseline` |
| 2 · Inject drift | Flip `PermitRootLogin` to `yes`, restart sshd | `./demo.sh drift` |
| 3 · EDA detects | The rulebook fires on the change (or audit-scan it) | rulebook running, or `./demo.sh detect` |
| 4 · Auto-remediate | Baseline re-asserted in seconds | `./demo.sh remediate` |
| 5 · Log to ServiceNow | Incident opened + local JSON audit log appended | automatic in beat 4; `tail /var/log/sshd_compliance_audit.log` |

## Setup

```bash
# 1. Install the collections
ansible-galaxy collection install -r requirements.yml

# 2. (Optional) ServiceNow — export these so beat 5 opens a real incident.
#    If unset, the demo falls back to the local JSON audit log (say so on stage).
export SNOW_INSTANCE="https://devXXXXX.service-now.com"
export SNOW_USERNAME="ansible.automation"
export SNOW_PASSWORD="********"

# 3. Point inventory/hosts.ini at your RHEL/Ubuntu/SUSE hosts
#    (or leave the localhost line for a single-box demo).
```

## Running it

### Option A — scripted, one host (fastest for a live demo)

```bash
chmod +x demo.sh
./demo.sh baseline     # green
./demo.sh drift        # break it
./demo.sh detect       # prove the scan sees it (audit-only, no change)
./demo.sh remediate    # fix it + log the audit event
./demo.sh reset        # back to clean for the next run
```

### Option B — fully event-driven with `ansible-rulebook` (no controller)

```bash
# Terminal 1: start the rulebook listening for drift
ansible-rulebook -i inventory/hosts.ini \
  --rulebook rulebooks/sshd_drift_remediation_standalone.yml --verbose

# Terminal 2: cause drift — the rulebook auto-remediates within seconds
./demo.sh drift
# ...or trigger via an external "alert" without touching the host:
curl -X POST http://localhost:5000/endpoint \
  -H 'Content-Type: application/json' \
  -d '{"alert":"sshd_drift","host":"localhost","source":"siem-demo"}'
```

### Option C — in AAP (the production shape)

1. Add this repo as a **Project**.
2. Create a **Job Template** named `SSHD Baseline - Remediate` running
   `playbooks/remediate_sshd.yml` against the `linux_fleet` inventory, with a
   machine credential and (optionally) a ServiceNow credential.
3. Create a **Rulebook Activation** using
   `rulebooks/sshd_drift_remediation.yml` in a decision environment that has the
   `ansible.eda` collection. It calls the job template above on each rule match.
4. For periodic enforcement *alongside* EDA, also put the job template on a
   schedule — that's the slide-6 "scheduled + event-driven" belt-and-suspenders.

## Why this is the consolidation story, not just an SSH script

- **Cross-platform:** the role's `tasks/main.yml` dispatches by OS — `linux.yml`
  runs on RHEL, Ubuntu, and SUSE; `windows.yml` runs on Windows. Both share the
  same detect -> remediate -> report flow and the same audit fact, so one run of
  the playbook against the `all` inventory hardens every platform at once.
- **Same artifact, two triggers:** `remediate_sshd.yml` is what a *scheduled*
  AAP job runs **and** what *EDA* fires. Periodic + event-driven enforcement
  from one playbook.
- **Swap the target:** point the rulebook at a network or storage collection and
  the identical detect → remediate → log pattern enforces a switch ACL or a
  storage export. That's slide 5 + slide 9 combined — the whole pitch in one demo.

## Windows: same role, same story

The role auto-detects the OS in `tasks/main.yml` and runs `tasks/windows.yml`
on Windows hosts. It enforces a registry/policy baseline that mirrors the SSH
hardening intent:

| Control | Registry / mechanism | Desired |
|---------|----------------------|---------|
| RDP requires NLA | `...\WinStations\RDP-Tcp\UserAuthentication` | 1 |
| RDP min encryption = High | `...\WinStations\RDP-Tcp\MinEncryptionLevel` | 3 |
| SMBv1 server disabled | `...\LanmanServer\Parameters\SMB1` | 0 |
| LSA restrict anonymous | `...\Control\Lsa\RestrictAnonymous` | 1 |
| WinRM running + auto | service state | running |
| Firewall on all profiles | `community.windows.win_firewall` | enabled |

It uses the **exact same detect -> report -> (stop if audit-only) -> remediate**
flow as Linux and publishes the same platform-neutral `baseline_drift` fact, so
the ServiceNow incident / audit-log record looks identical no matter the OS.

The slide-9 storyboard maps cleanly to Windows: inject drift by flipping
`UserAuthentication` to 0 (NLA off) in the registry, then watch the role detect
and restore it. Because Windows has no journald/inotify, the live event source
is the **webhook** (rule 4 in the AAP rulebook), fed by Windows Event
Forwarding, a SIEM (Sentinel/Splunk), or Defender:

```bash
curl -X POST http://<eda-route>/endpoint \
  -H 'Content-Type: application/json' \
  -d '{"alert":"win_baseline_drift","host":"win2022-demo","control":"RDP_NLA_required","source":"sentinel"}'
```

**Windows prerequisites:** a Windows host reachable from the control node with
WinRM (5986/HTTPS) configured, or OpenSSH on Server 2022+. Credentials come from
an AAP machine credential — never from inventory. The Windows target is managed
*over the network*; nothing is installed on it beyond standard remote management.

## Running it through AAP on Single Node OpenShift

This is the production shape and works on an SNO homelab:

1. **Install AAP** via the *Ansible Automation Platform Operator* from
   OperatorHub on your SNO cluster. It deploys the controller, EDA controller,
   and automation hub as workloads. Size pod requests down for a homelab and
   avoid running it at the same time as heavy GPU workloads on the same node.
2. **Add this repo as a Project** (Git source).
3. **Install the collections** from `requirements.yml` (`ansible.eda`,
   `servicenow.itsm`, `ansible.windows`, `community.windows`, `ansible.posix`) —
   either bake them into a custom Execution Environment or sync them from a
   private Automation Hub.
4. **Create a Job Template** `SSHD Baseline - Remediate` running
   `playbooks/remediate_sshd.yml` against the `all` inventory (Linux + Windows),
   with a Linux machine credential **and** a Windows machine credential, plus an
   optional ServiceNow credential.
5. **Create a Rulebook Activation** using `rulebooks/sshd_drift_remediation.yml`
   in a decision environment that has `ansible.eda`. It calls the job template on
   each rule match. Expose the EDA **webhook via an OpenShift Route** so external
   alerts (and your `curl` test) can reach it.
6. **Optionally schedule** the job template too — scheduled enforcement plus
   event-driven enforcement is the slide-6 belt-and-suspenders.

> One run of the job template against the `all` inventory enforces RHEL, Ubuntu,
> SUSE, and Windows in a single pass — the consolidation thesis, demonstrated on
> your own cluster.

## Customising the baseline

Edit `roles/enforce_sshd_baseline/defaults/main.yml` — `sshd_baseline` is just a
list of `{key, value}` directives. In a real migration this is sourced from the
customer's CIS profile (today in Hiera; after migration in `group_vars` + Vault).
