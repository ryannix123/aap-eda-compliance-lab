# Provision the Demo Fleet on Proxmox

Stand up the RHEL / Ubuntu / SUSE demo VMs with **cloud images + cloud-init**,
driven by Ansible over the **Proxmox API** — no ISOs, no clicking through
installers. The Windows VM is built by hand once (see below).

> This is itself a Day-0 automation demo: the same Ansible that *manages* the
> fleet also *creates* it. Worth showing the customer.

## How it works

1. **One time, on the Proxmox host:** `create-templates.sh` downloads each cloud
   image (qcow2) and converts it into a Proxmox VM **template** with a cloud-init
   drive.
2. **Repeatable, from your control node:** `provision_fleet.yml` clones each
   template into a demo VM, cloud-inits it (hostname, static IP, user, your SSH
   key), starts it, and waits for SSH.

## Part 1 — One-time Proxmox setup

### 1a. Authentication — password is simplest for a lab

You do **not** need to create an API token. The provisioning playbook can
authenticate with your existing Proxmox root password over the API:

```
-e proxmox_api_user='root@pam' -e proxmox_api_password='yourRootPassword'
```

That's the zero-setup path and it's fine for a homelab. (There's a chicken-and-egg
reason the token can't be auto-created: you'd need API access to create the
credential that grants API access. Password auth sidesteps it entirely.)

**Optional, better practice** — if you'd rather use a scoped, revocable token:

1. **Datacenter → Permissions → Users → Add:** e.g. `automation@pve`.
2. **Datacenter → Permissions → API Tokens → Add:** token id e.g. `ansible`;
   uncheck "Privilege Separation" for a lab. **Copy the secret — shown once.**
3. **Datacenter → Permissions → Add → User/Token Permission:** grant
   `PVEVMAdmin` (or `Administrator` for a lab) on path `/`.

Then pass `-e proxmox_api_user='automation@pve' -e proxmox_api_token_id='ansible'
-e proxmox_api_token_secret='...'` instead of the password.

### 1b. Enable Snippets storage (for cloud-init)

**Datacenter → Storage → `local` → Edit →** add **Snippets** to the content
types. Cloud-init needs somewhere to write its config.

### 1c. Create the templates

`scp create-templates.sh` to the Proxmox host and run it **as root**:

```bash
# Ubuntu + SUSE download automatically. Adjust storage/bridge if yours differ.
STORAGE=local-lvm BRIDGE=vmbr0 ./create-templates.sh
```

**RHEL image:** Red Hat's KVM guest image requires a login, so there's no
anonymous URL. Either:
- Download `rhel-9.x-x86_64-kvm.qcow2` from
  [access.redhat.com](https://access.redhat.com/downloads) (RHEL → KVM Guest
  Image), `scp` it to the host, and re-run:
  ```bash
  RHEL_LOCAL_QCOW=/root/rhel-9.6-x86_64-kvm.qcow2 ./create-templates.sh
  ```
- Or substitute **CentOS Stream 9 / Rocky / Alma** (anonymous download) as the
  RHEL-family target — the compliance role treats all of them as `RedHat`
  os_family, so the demo works identically.

The script is idempotent — re-running skips templates that already exist. It
creates VMIDs 9000 (RHEL), 9001 (Ubuntu), 9002 (SUSE) by default.

## Part 2 — Provision the fleet (Ansible)

On your control node:

```bash
cd provision-fleet
ansible-galaxy collection install -r requirements.yml
pip install proxmoxer requests

ansible-playbook provision_fleet.yml \
  -e proxmox_api_host=192.168.1.5 \
  -e proxmox_node=pve \
  -e proxmox_api_user='root@pam' \
  -e proxmox_api_password='PASTE-ROOT-PASSWORD' \
  -e ssh_pubkey="$(cat ~/.ssh/id_ed25519.pub)" \
  -e net_gw=192.168.1.1
```

(Swap the password line for `-e proxmox_api_token_id=... -e proxmox_api_token_secret=...`
if you created a token in 1a instead.)

Adjust the IPs/VMIDs in the playbook's `fleet:` var to match your VLAN. By
default it creates:

| VM | VMID | IP | from template |
|----|------|----|---------------|
| rhel9-demo  | 201 | 192.168.1.11 | 9000 |
| ubuntu-demo | 202 | 192.168.1.12 | 9001 |
| suse-demo   | 203 | 192.168.1.13 | 9002 |

The playbook clones, cloud-inits, starts, and waits for SSH on each. When it
finishes, the three Linux VMs are reachable as user `ansible` with your key.

> **Secrets:** pass the token secret and SSH key with `-e` at runtime, or better,
> store them in an Ansible Vault file. Never commit them. The `.gitignore`
> already excludes vault files and keys.

## Part 3 — The Windows VM (build once, by hand)

Windows doesn't have a turnkey cloud-image/cloud-init path like the Linux
distros, so for a single demo box it's faster to build it once manually:

1. Download the **Windows Server 2022 evaluation ISO** (Microsoft Evaluation
   Center) and the **VirtIO drivers ISO** (Fedora project) — Proxmox needs
   VirtIO for disk/network.
2. Create a VM (4 vCPU / 8 GB / 80 GB), attach both ISOs, install Windows,
   load the VirtIO storage driver during setup.
3. After install, follow `../docs/proxmox-build-sheet.md` → "Windows VM" section
   to enable WinRM over HTTPS for Ansible.

(If you end up rebuilding Windows often, the scalable path is an
`autounattend.xml` answer file baked into a template — but that's overkill for
one demo box.)

## After provisioning

Put the four IPs into `../compliance-demo/inventory/hosts.ini`, then run the
smoke test from the build sheet:

```bash
ansible linux_fleet -m ansible.builtin.ping
ansible windows_fleet -m ansible.windows.win_ping
```

Both green → the fleet is ready for the compliance job template.

## Caveats / first-run notes

- **Untested in CI:** these playbooks couldn't be run against a live Proxmox API
  during authoring. Expect to debug the first run — most likely spots are the
  cloud-init drive (Part 1b) and the `ipconfig0` format if your network differs.
- **Template defaults vs. clone sizing:** the playbook bumps clones to 2 cores /
  4 GB. Adjust in the `fleet`/task vars for your capacity.
- **proxmox_kvm idempotency:** re-running won't re-clone existing VMIDs, but if a
  clone half-failed, delete the partial VM in Proxmox before re-running.
