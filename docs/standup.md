# Stand-up 1 (2026-11-09 -> spoken 2026-11-10)

**What did you do so far?**
I went with a modified deployment of Vaultly: OpenBao instead of HashiCorp Vault, OpenTofu instead of Terraform, rootless Podman instead of Docker, EKS Pod Identity instead of IRSA.
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


# Stand-up 2 (2026-11-11)

**What did you do so far?**
- Rebuilt the Stage 2 foundation from the saved state: network (36 resources), EKS
  (40), platform with the KMS key and alias (5). Three arm64 nodes Ready, and the
  KMS alias was reused without a conflict.
- Stage 3a done and committed (signed): cert-manager v1.21.3, a self-signed root CA
  and a server certificate for OpenBao (ECDSA, 90 days, SANs for every pod name of
  the headless service). The CA key lives only in a cluster secret, never in git.
- Stage 3b (OpenBao HA, 3 replicas, Raft, TLS, KMS plugin seal) is written but not
  installed yet. The first install was rejected by Kubernetes before creating
  anything: a duplicate `BAO_ADDR` env var (the chart already sets it when TLS is on).
  I fixed that, found that `$(HOSTNAME)` would not have expanded in the API address
  (the chart declares it too late) and use `$(BAO_K8S_POD_NAME)` instead, and added
  a tagged, encrypted gp3 StorageClass because `gp2` is not the default class.
- Lost time to my dynamic public IP: the EKS API allow-list still had yesterday's
  address, so kubectl timed out. I wrote `scripts/update-admin-ip.sh` (rewrites only
  `admin_cidr`, plans one resource, refuses anything that creates or deletes) and
  `scripts/rebuild.sh`. The plan also wanted to touch five addons; I left those alone
  on purpose, so a running cluster is not upgraded by an IP change.

**Do you feel on track, behind or ahead?**
On track overall, slightly behind my own Stage 3 schedule: 3b should have been
installed yesterday. Both delays (the chart bug and the IP drift) are fixed or
scripted now, and they cost time, not design changes.

**What's your plan for today?**
- Restore API access, install OpenBao (3b) and collect evidence.
- 3c: initialise, recovery keys to SSM, revoke the root token.
- 3d: proofs: three Raft peers, delete a pod and watch it auto-unseal, plain HTTP refused.
- 3e: policies and Kubernetes auth mount, if time allows.
- Tear everything down tonight: Helm uninstall, delete the volumes, then the three roots.

**Any blockers?**
None hard. Things I am watching:
- Pod Identity credentials may not reach the KMS plugin subprocess (untested; the
  first OpenBao start is the test). Fallbacks: plugin `env` parameter, then IRSA.
- Unseal depends on ghcr.io egress through the NAT for the plugin download. I am
  trying a plugin cache on the data volume (untested).
- The cluster has been running since 2026-11-10 and bills hourly. I have not computed
  the hourly cost. Tonight's teardown needs extra steps because CSI volumes are not in
  OpenTofu state.
- My IAM user has no MFA in the shared account. Known risk, planned for Stage 5.
