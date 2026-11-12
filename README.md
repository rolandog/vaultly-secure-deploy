# vaultly-secure-deploy

Vaultly (secrets-rotation demo app) on AWS EKS with OpenBao HA (Raft, KMS auto-unseal,
TLS), Kubernetes auth and no static tokens. Infrastructure is OpenTofu, containers are
rootless Podman, and every stage leaves redacted evidence in `docs/evidence/`.

## Prerequisites

- OpenTofu 1.10+, `kubectl`, `helm`, `aws` CLI (region `eu-central-1`), `jq`, `skopeo`, `podman`.
- Shared AWS account: resources are prefixed `rg-` and tagged `Namespace=rg`.
- State bucket `tf-state-<account>-eu-central-1` (created once by `scripts/bootstrap-state.sh`, never deleted).

## Cost

EKS, the NAT gateway and the three t4g.small nodes bill hourly (about $0.21/h by a
list-price estimate that has not been checked against billing). Tear down when you stop.

## Rebuild

Measured 2026-11-11, eu-central-1, from an empty state (the previous cluster's KMS keys stay in
PendingDeletion; the state bucket is kept). Run the steps in this order:

| Step | Command | Time |
|---|---|---|
| 1 | `scripts/rebuild.sh` (admin IP refresh, apply network, eks, platform with -auto-approve, wait for 3 nodes) | 15 m 43 s |
| 2 | `scripts/install-cert-manager.sh` | 41 s |
| 3 | `scripts/install-openbao.sh` | 28 s |
| 4 | `scripts/openbao-init.sh` (recovery keys and root token go to SSM) | 25 s |
| 5 | `scripts/openbao-configure.sh` | 47 s |
| 6 | `scripts/vaultly-bootstrap.sh` (namespace, CA ConfigMap, API bearer Secret) | 9 s |
| 7 | `kubectl apply -f k8s/vaultly/` then `kubectl rollout status -f k8s/vaultly/deployment.yaml --timeout=180s` | 13 s |

About 18 minutes of command time from nothing to a running app (second run: 18 min 02 s). The cluster bills hourly until teardown.
Teardown deletes the SSM parameters, so every rebuild runs step 4 again.

Verify (the app answers on port 8080 inside the cluster):

```bash
kubectl -n vaultly port-forward svc/vaultly 8080:8080 &
curl -sS localhost:8080/healthz    # {"status":"ok"}
curl -sS localhost:8080/readyz     # {"status":"ok","vault_authenticated":true}
kill %1
```

## Teardown

The order matters: Kubernetes data first, then AWS, then the infrastructure.

1. `scripts/teardown.sh k8s`: delete namespace `vaultly`, uninstall OpenBao, delete the
   PVCs, and wait until the EBS volumes behind them are gone (the `rg-gp3` StorageClass
   reclaims volumes on PVC deletion; do this while the cluster still runs).
2. `scripts/teardown.sh ssm`: delete `/rg-vaultly/openbao/*`. This destroys the recovery
   keys and the root token, so the next rebuild must run `init` again.
3. `scripts/teardown.sh tofu`: destroy the roots `platform`, `eks`, `network`, in that order.
4. `scripts/teardown.sh verify`: every check line must say `ok` (the tagged-resource list after it is informational: the tagging API keeps deleted resources for hours). Measured 2026-11-11: k8s 1 min, ssm 8 s, tofu 14 min, verify 30 s.

The KMS key enters its deletion waiting period, which costs nothing.
For unattended runs: `scripts/teardown.sh --force all` skips the prompts and passes
`-auto-approve` to `tofu destroy`; `--force` alone is refused, a phase is required.
If `network` fails with `DependencyViolation`, a leaked ENI is the usual cause (see
Troubleshooting).

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `kubectl` times out or `cluster unreachable` | your public IP changed; the API allows only `admin_cidr` | `scripts/update-admin-ip.sh` |
| `PodSecurity "restricted:latest"` warning in `install-openbao.sh` | the chart does not drop all capabilities | warning only; the install succeeds |
| `teardown.sh verify` lists tagged ARNs | the tagging API keeps deleted resources for hours | informational; the `ok` lines above decide |
| KMS keys in `PendingDeletion` after teardown | the deletion waiting period | none; no cost |
| `network` destroy fails with `DependencyViolation` | a leaked ENI in the VPC | list it with `aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=<vpc-id>`, delete it, re-run `scripts/teardown.sh tofu` |
| `ImagePullBackOff` | the ghcr package is private or the digest is wrong | `skopeo inspect --raw docker://<image>` |

## Evidence index

See `docs/evidence/` (files are prefixed by stage).

## Known limitations

- The vendored app never renews its OpenBao token, and a policy denial surfaces as HTTP 500 (issue #1). Workaround: role `token_ttl=8h`, `token_max_ttl=24h`; the pods stop working about 8 h after start and need a restart.
- OpenBao egress allows port 443 to any public address, because the KMS and ghcr.io addresses change. Accepted risk; the fix is a KMS VPC interface endpoint plus a narrower rule.
- The root token is revoked at the end of stage 4e. Policy changes afterwards need `bao operator generate-root` with the recovery keys in SSM. The operator token has a 12 h TTL, so rotation stops after that; a rebuild issues a new one.
