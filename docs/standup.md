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
- Rebuilt the Stage 2 foundation from the saved state (network, EKS, platform with
  the KMS key). Three arm64 nodes Ready.
- Stage 3 is finished and committed (signed commits), as five steps:
  - 3a: cert-manager v1.21.3, a private CA and a server certificate for OpenBao.
  - 3b: OpenBao 2.7.2 in HA, 3 replicas, Raft storage, TLS. The first install was
    rejected before creating anything (duplicate `BAO_ADDR`); fixed.
  - 3c: initialised; recovery keys went to SSM.
  - 3d: proofs. Three Raft voters. Plain HTTP is refused (HTTP 400). I deleted the
    leader pod and the replacement auto-unsealed in about 25 s. The KMS plugin cache
    survived the restart. CloudTrail shows each pod calling KMS with its own Pod
    Identity session, and a new session after the restart.
  - 3e: KV v2, two policies (`vaultly-app` and `rg-operator`) and a Kubernetes auth
    role `vaultly`. The self-test logs in through Kubernetes auth with the correct
    service account and is refused for the wrong one. All three pods agree on
    policies and secret version.
- `scripts/openbao-configure.sh` (v0.1.1) is idempotent: a re-run changes nothing.
  I found its negative test checked the wrong error wording, fixed it and re-ran.
- Read the app code to set the policy: the app passes API paths to KV unchanged, so
  the policy allows `app-config/*` plus read-only on the rotation secret.
- Lost time earlier to my changing public IP (EKS allow-list). Scripted fix:
  `scripts/update-admin-ip.sh`.

**Do you feel on track, behind or ahead?**
On track. Stage 3 is done a day later than I first planned (chart bug plus the IP
drift), but both are fixed or scripted. Stages 4 to 8 are still ahead and the CI,
audit and docs stages carry the schedule risk.

**What's your plan for today?**
- Merge Stage 3 into develop and start Stage 4.
- Build the app image for arm64 and amd64 on a pinned base, check the ELF headers,
  push it to ghcr.io (public package).
- Deploy the app to a `vaultly` namespace with restricted pod security (non-root
  uid 10001) and prove it logs in with Kubernetes auth (no static tokens).
- Add NetworkPolicies and re-prove the login. Then the rotation demo, a "denied
  outside app-config/" proof, and revoke the root token.
- Then the load balancer if time allows. Tear down tonight; the teardown needs
  extra steps for the volumes.

**Any blockers?**
None hard. Things I am watching:
- The app has not logged in from a pod yet. Two parts are untested: the app
  trusting OpenBao's private CA (no TLS setting in the app, so I use `VAULT_CACERT`),
  and the network path from OpenBao to the Kubernetes API.
- NetworkPolicies are my main risk. A default-deny egress rule could block the Pod
  Identity agent and break auto-unseal at the next restart. I will test by deleting
  a follower after applying them.
- The root token is still in SSM, by design, until the app login works.
- The cluster has been up since 2026-11-10. My list-price estimate is about $0.21/h
  (about $5/day); I have not checked it against billing.
- My IAM user has no MFA in the shared account. Known risk, planned for Stage 5.
