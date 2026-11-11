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

TBD: filled in from the measured rebuild (stage T3).

## Teardown

The order matters: Kubernetes data first, then AWS, then the infrastructure.

1. `scripts/teardown.sh k8s`: delete namespace `vaultly`, uninstall OpenBao, delete the
   PVCs, and wait until the EBS volumes behind them are gone (the `rg-gp3` StorageClass
   reclaims volumes on PVC deletion; do this while the cluster still runs).
2. `scripts/teardown.sh ssm`: delete `/rg-vaultly/openbao/*`. This destroys the recovery
   keys and the root token, so the next rebuild must run `init` again.
3. `scripts/teardown.sh tofu`: destroy the roots `platform`, `eks`, `network`, in that order.
4. `scripts/teardown.sh verify`: every line must say `ok`.

The KMS key enters its deletion waiting period, which costs nothing.
If `network` fails with `DependencyViolation`, a leaked ENI is the usual cause (see
Troubleshooting, TBD).

## Troubleshooting

TBD: admin IP drift (`scripts/update-admin-ip.sh`), `DependencyViolation`, image pulls.

## Evidence index

See `docs/evidence/` (files are prefixed by stage).
