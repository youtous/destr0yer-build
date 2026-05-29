# ADR-002: Debian Bookworm (12) to Trixie (13) upgrade

**Status**: Done

**Context**: The repo targeted Debian 12 Bookworm. Debian 13 Trixie was released
on August 9, 2025, currently at 13.5 (May 2026). Supported until 2028 + LTS 2030.
The old Trello WIP card "Upgrade to Debian 12 (Bookworm)" is now superseded.

**Decision**: Migrate to Debian 13 Trixie.

**Notable Trixie changes**:
- Kernel 6.12 LTS (vs 6.1 on Bookworm) — better eBPF support for Cilium
- Systemd 257
- OpenSSL 3.4
- Python 3.13 native
- nftables by default (iptables is a wrapper)
- Dropped mipsel, armel architectures (no impact for us)

**Implementation**:
1. Add `apt_trixie_flag_path` in `roles/apt/defaults/main.yml` (done)
2. Update `apt_distribution_version_target` to support `trixie`
3. Create an upgrade test playbook on Vagrant
4. Update Vagrantfile: `debian/bookworm64` -> `debian/trixie64` (done)
5. Verify all role compatibility with Trixie
6. Review iptables rules for native nftables backend

**Risks**:
- Existing UFW/iptables roles may not work out-of-the-box with nftables backend.
  Test priority.
- Third-party packages (k3s, docker) may have temporary incompatibilities.

**Alternatives considered**:
- Stay on Bookworm: Rejected, EOL June 2028, kernel 6.12 offers better Cilium/eBPF.
- Non-Debian distro (Talos, Flatcar, Alpine): Rejected, would require rewriting
  all Ansible roles. Debian Trixie + hardening is the right balance.
