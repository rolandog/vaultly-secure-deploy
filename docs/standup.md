# Stand-up 1 (2026-11-09 -> spoken 2026-11-10)

**What did you do so far?**
I went with a slightly modified deployment of Vaultly [edit: say what differs from the brief].
The app and goals are the same, but the stack is free software (OpenTofu, rootless
Podman, OpenBao) and the security controls go beyond the minimum.
- Stage 1, local proof first: 12 tests pass, a rotated secret is picked up without
  a restart, and the container runs as non-root (uid 10001). Reason: find app bugs
  on my laptop for free, not on a billed cluster.
- Stage 2, AWS foundation with OpenTofu: a 3-tier VPC with one NAT, EKS 1.36 on
  three arm64 nodes, a KMS key for OpenBao auto-unseal, and a least-privilege role
  tied to one service account through Pod Identity. IAM simulation proves it can
  encrypt and decrypt but cannot delete the key or touch other services.
- Guardrails: an architecture guard (a wrong instance type fails the plan), checkov
  with 0 failures (5 skips, each with a written reason), redacted evidence, signed commits.
- I tore everything down at night because EKS, NAT and nodes bill hourly. The
  state bucket stays, so a rebuild takes about 20 minutes.

**Do you feel on track, behind or ahead?**
On track. The infrastructure is reproducible and proven, so the cost of rebuilding is
low. The risk is time on the later stages (TLS, CI, audit), not the foundation.

**What's your plan for today?**
Rebuild (network, EKS, platform), then Stage 3: OpenBao in HA mode (3 nodes, raft
storage), auto-unsealed by the KMS key, with TLS. Reason: it is the core of Vaultly's
security story. The app, CI and audit stages all depend on secrets coming from
OpenBao rather than static values.

**Any blockers?**
None hard. Things I am watching:
- OpenBao 2.7 moved the AWS KMS seal into an external plugin: pinned 2.7.2 + plugin v0.1.1 by digest; unseal needs ghcr.io egress via NAT.
- Pod Identity credentials may not reach the KMS plugin subprocess (untested); fallbacks: plugin env parameter, then IRSA.
- My IAM user has no MFA in the shared account. Known risk, planned for Stage 5.
- Cloud cost: rebuild only when needed, tear down at the end of the day.
