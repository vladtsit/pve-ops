# PVE host firewall — Amnezia VPN client isolation

## Goal
Prevent users connected to the Amnezia VPN server (VM 102, 192.168.3.43) from reaching
any host on the local LAN. Only internet access is allowed.

## Why this is enforced on the PVE host (not inside VM 102)
VM 102 is a black box — managed only via its admin UI from the internet. We cannot
add firewall rules inside it. Once the VM SNATs VPN client traffic to 192.168.3.43,
the source IP is identical to the VM's own outbound traffic, so any host-side rule
necessarily affects both. In practice the VM only needs internet + DNS, so this is fine.

## Files
- \cluster.fw\ -> \/etc/pve/firewall/cluster.fw\ — datacenter-wide enable, default ACCEPT (does not affect other VMs).
- \102.fw\ -> \/etc/pve/firewall/102.fw\ — per-VM rules applied to NIC \
et0\ of VM 102.

## Effective OUT chain on VM 102 (tap102i0)
1. ACCEPT to 192.168.3.1:53 (UDP+TCP) — DNS via the LAN router (needed for apt/updates name resolution).
2. DROP to 192.168.3.0/24, 10/8, 172.16/12, 192.168/16 — blocks all RFC1918.
3. ACCEPT default — internet egress.

IN direction: default ACCEPT — admin SSH on :22, AmneziaWG :8443, IP-telnet :31947 still reachable.

## Activation steps performed
1. \/etc/pve/firewall/cluster.fw\ created with \nable: 1\ and policy ACCEPT everywhere.
2. \/etc/pve/firewall/102.fw\ created with the rules above.
3. NIC firewall flag set: \qm set 102 --net0 virtio=...,bridge=vmbr0,firewall=1\
4. \pve-firewall restart\ (note: not \eload\ — that subcommand does not exist).

## Verification (run from a connected VPN client)
- \ping 192.168.3.20\ -> must FAIL (was: works)
- \ping 192.168.3.1\  -> must FAIL (router LAN UI unreachable from VPN)
- \ping 1.1.1.1\      -> must work
- \curl https://ifconfig.me\ -> returns your home WAN IP

From the LAN side (admin perspective):
- \ssh admin@192.168.3.43\ -> still works (IN unaffected)
- AmneziaWG handshake on :8443 / :31947 from internet -> still works

On the PVE host:
- \pve-firewall status\ -> \nabled/running\
- \iptables -S | grep tap102i0\ -> shows the OUT chain with DNS ACCEPT then DROP rules.

## Rollback
\\\
ssh root@192.168.3.20 'sed -i \ s/^enable: 1/enable: 0/\ /etc/pve/firewall/102.fw ; pve-firewall restart'
\\\
or in PVE web UI: Datacenter -> VM 102 -> Firewall -> Options -> Firewall: No.

## Notes
- DNS is allowed only to 192.168.3.1 (router). If the router goes down, the VM will lose name resolution. Fallback: edit 102.fw to also allow 8.8.8.8 / 1.1.1.1 :53.
- NTP is intentionally not whitelisted — VM falls back to public NTP via internet.
- Broadcast/multicast (mDNS, SSDP) are not relevant — VM 102's SNAT does not propagate them.
