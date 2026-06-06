# Proxmox Build Sheet — Managed Host Fleet

This is the "stand up the fleet" checklist for the four VMs the compliance role
targets. They live on your **Proxmox box (10 cores / 64 GB / 1 TB NVMe)** and are
managed *over the flat home VLAN* by AAP running on the **OCP SNO box**.

Nothing here installs an agent — AAP reaches each VM over SSH (Linux) or
WinRM (Windows). These are just normal VMs on your LAN.

## VM sizing

Total footprint below is ~22 GB RAM / ~16 vCPU-equiv across four VMs, leaving
roughly **40 GB RAM and plenty of NVMe free** on the Proxmox host for headroom,
snapshots, or extra test VMs. vCPU is oversubscribed deliberately — these are
idle demo hosts, not workloads, so contention is a non-issue.

| VM | OS | vCPU | RAM | Disk | Purpose |
|----|----|------|-----|------|---------|
| `rhel9-demo`   | RHEL 9            | 2 | 4 GB | 40 GB | RHEL target (also pairs with Satellite story) |
| `ubuntu-demo`  | Ubuntu 24.04 LTS  | 2 | 4 GB | 40 GB | Debian-family target |
| `suse-demo`    | openSUSE Leap 15 / SLES 15 | 2 | 4 GB | 40 GB | SUSE-family target |
| `win2022-demo` | Windows Server 2022 | 4 | 8 GB | 80 GB | Windows target (RDP/registry baseline) |

Storage tip: put all four on the NVMe-backed Proxmox storage pool. Use the
`virtio-scsi-single` controller and enable `discard`/`ssd emulation` so thin
provisioning reclaims space on your 1 TB pool.

## Common setup (all VMs)

1. **Static-ish addressing.** DHCP reservations on the flat VLAN are fine; just
   make sure each VM has a stable IP so the AAP inventory stays valid.
2. **Hostname + DNS.** Set hostnames matching the table and, ideally, add them to
   your LAN DNS (or the AAP EE's `/etc/hosts`) so the inventory can use names.
3. **Reachability check from the SNO side:** AAP's execution pods must reach
   - Linux VMs on TCP **22** (SSH)
   - Windows VM on TCP **5986** (WinRM HTTPS)
   and each VM must reach the SNO's EDA webhook Route on **443** for drift signals.
   On a flat VLAN with no host firewalls blocking these, it's automatic.

## Linux VMs (RHEL / Ubuntu / SUSE)

1. Minimal server install; create an automation user (e.g. `ansible`) with
   passwordless `sudo`:
   ```bash
   sudo useradd -m -s /bin/bash ansible
   echo 'ansible ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/ansible
   sudo install -d -m 700 /home/ansible/.ssh
   ```
2. Add the public key that the AAP **machine credential** will use:
   ```bash
   sudo tee -a /home/ansible/.ssh/authorized_keys < your_aap_key.pub
   sudo chown -R ansible:ansible /home/ansible/.ssh
   sudo chmod 600 /home/ansible/.ssh/authorized_keys
   ```
3. Ensure `python3` and `openssh-server` are present (they are on default
   server installs of all three). SUSE: `sudo zypper install -y python3`.
4. The role hardens sshd, so SSH must be running: `sudo systemctl enable --now sshd`
   (Ubuntu service is `ssh`, but the role resolves that automatically).

## Windows VM (Server 2022)

Enable WinRM over HTTPS for Ansible. From an elevated PowerShell on the VM:

```powershell
# 1. Create the automation account (or use a domain account via AAP credential)
net user ansible 'ChangeMe-Strong!' /add
net localgroup Administrators ansible /add

# 2. Quick WinRM setup for Ansible (HTTPS listener + firewall rule).
#    Red Hat / Ansible publish a hardened version of this script; for a lab the
#    built-in quickconfig plus an HTTPS listener is enough:
winrm quickconfig -quiet
# Create a self-signed cert and an HTTPS listener on 5986
$cert = New-SelfSignedCertificate -DnsName "win2022-demo" -CertStoreLocation Cert:\LocalMachine\My
winrm create winrm/config/Listener?Address=*+Transport=HTTPS `
  ("@{Hostname=`"win2022-demo`"; CertificateThumbprint=`"" + $cert.Thumbprint + "`"}")
# Allow 5986 through the firewall
New-NetFirewallRule -DisplayName "WinRM HTTPS" -Direction Inbound -LocalPort 5986 -Protocol TCP -Action Allow
# Allow Basic/NTLM for the lab (use Kerberos in production)
Set-Item WSMan:\localhost\Service\Auth\Basic $true
Set-Item WSMan:\localhost\Service\AllowUnencrypted $false
```

Notes:
- The role enforces an RDP/registry baseline, so leave **Remote Desktop** in its
  default state — beat 2 of the demo deliberately flips `UserAuthentication`
  (NLA) off, and the role restores it.
- For a cleaner production-style setup, use the official Ansible
  `ConfigureRemotingForAnsible.ps1` and Kerberos auth against AD instead of the
  self-signed/NTLM lab shortcut above.

## Matching `compliance-demo/inventory/hosts.ini`

Uncomment and edit to match your VM IPs/names:

```ini
[rhel]
rhel9-demo    ansible_host=192.168.1.11

[ubuntu]
ubuntu-demo   ansible_host=192.168.1.12

[suse]
suse-demo     ansible_host=192.168.1.13

[windows_fleet]
win2022-demo  ansible_host=192.168.1.21

[linux_fleet:vars]
ansible_user=ansible

[windows_fleet:vars]
ansible_connection=winrm
ansible_winrm_transport=ntlm
ansible_port=5986
ansible_winrm_server_cert_validation=ignore
```

Credentials (`ansible_user`/password/keys for both Linux and Windows) belong in
an **AAP machine credential**, not in this file. The inventory just declares the
hosts and connection method.

## Smoke test before the demo

From the AAP controller (or a laptop with the inventory + credentials):

```bash
# Linux reachability
ansible linux_fleet -m ansible.builtin.ping
# Windows reachability
ansible windows_fleet -m ansible.windows.win_ping
```

Both returning `pong` means the fleet is ready for the compliance job template.
