---
title: Vaultly
author: Rolando Garza
patat:
  slideLevel: 2
  pandocExtensions:
    - patat_extensions
    - autolink_bare_uris
  links:
    osc8: true
  speakerNotes:
    file: /tmp/rg-notes.txt
  eval:
    figlet:
      command: figlet
      reveal: false
      replace: true
    bash:
      command: bash
      container: code
      syntax: text
      replace: true
...

# Introduction

<!--
TIMING: slides 4:10 total, demo 3:00. Target 7:15 of talking, rest is buffer.
KEEP IN MIND: the "figlet" block below runs figlet when the slide opens
(reveal: false). If the title is blank, figlet is not installed: ignore it.
-->

## Vaultly Secure Deployment

Secrets platform on EKS, hardened end to end

```figlet
Vaultly
```

<!--
0:15
SAY: Hello everyone, you know me by now: Rolando Garza, working solo. My final
project is a secure deployment of a secrets platform on AWS EKS, built and
secured as code, with a CI pipeline that can prove what it cannot do...
and life had other plans, as you will see.
KEEP IN MIND: Vaultly = the professor's FastAPI secrets API, treated as a black
box (git submodule). OpenBao = the free-software Vault fork, which the spec
allows as "equivalent".
-->

# Why?

And... what did we have to deliver?

<!--
0:03. Just click on.
-->

## Motivations and Goals
- Credential compromise is a top incident cause
- Goal: highly available secrets store, least privilege, auditable
- Everything as code (OpenTofu); no long-lived keys; no secrets in CI env

<!--
0:30
SAY: Misconfigured access and leaked credentials cause most incidents. So the
requirements were: HA secrets store (3 replicas, Raft), auto-unseal with KMS,
the app logs in with Kubernetes auth (no static token), rotation without
restart, least-privilege network and IAM, and a CI pipeline with no stored
keys. Everything is OpenTofu.
KEEP IN MIND: tools in one breath: OpenTofu, EKS, OpenBao, cert-manager,
GitHub Actions with OIDC, Trivy, Athena. Do not list them slide by slide.
-->

# Architecture

<!--
0:03. Next.
-->

## Trust boundaries

```
Internet --HTTPS--> ALB (public subnets, ACM cert)
                     | NetworkPolicy: default deny + allow
                     v
EKS, private subnets:
  Vaultly x2 (uid 10001) --TLS--> OpenBao x3 (Raft)
                                     | Pod Identity
                                     v
                                 KMS auto-unseal

GitHub Actions --OIDC, exact sub--> IAM role (read-only) --> SSM
```

<!--
0:40
SAY: Read it top to bottom. Boundary 1: internet to the load balancer, the
only thing in a public subnet, TLS with an ACM certificate on
rg-vaultly.ih.rolan.dog. Boundary 2: the ALB to the pods, where a
default-deny NetworkPolicy allows only what is needed. Boundary 3: OpenBao to
KMS, via Pod Identity. CI is a separate trust path: GitHub gets short-lived
credentials from OIDC; no access keys exist.
KEEP IN MIND:
- Pod Identity (not IRSA): the account already has dozens of EKS OIDC
  providers. The trust is conditioned on namespace and service account.
- The KMS key policy has no CreateGrant, so an admin cannot delegate decrypt.
- There is an empty "database" subnet tier: no RDS, rotation is a KV v2
  version change. Say that if asked.
-->

## Implementation

- OpenBao, 3 replicas, Raft, KMS auto-unseal, Kubernetes auth (no static token)
- TLS inside the cluster (cert-manager); default-deny NetworkPolicy
- Restricted pods: non-root, all capabilities dropped
- Multi-arch image, pinned by digest
- One command up (scripts/up.sh), one command down (scripts/teardown.sh)

<!--
0:40
SAY: Two things I want you to remember. First: no static Vault token. The pod
presents its Kubernetes service account token, and OpenBao checks it with the
API server. Second: killing the Raft leader, the pod came back and unsealed
itself through KMS in about 25 seconds. The whole stack, from nothing to a
running app behind the ALB, is one script: up.sh took 22 minutes for the
cluster you are about to see.
KEEP IN MIND:
- cert-manager issues the in-cluster TLS; plain HTTP to OpenBao is refused
  (proved, returns 400).
- The image is on ghcr.io (public), amd64 and arm64, digest pinned.
- Do NOT say "root token revoked" unless you ran the revoke step.
-->

## CI/CD security

- Blocking on CRITICAL: Trivy on our infra and k8s manifests
- Before that: gitleaks, checkov
- Warn only: Semgrep, pip-audit, Trivy on the vendored app
- OIDC: role trusts only refs/heads/develop and refs/heads/main
- Secret read at runtime from SSM SecureString, never stored
- Negative proof: a scratch branch is denied; the role cannot delete a VPC,
  list IAM roles, or read other parameters

<!--
0:40
SAY: The pipeline has no stored AWS keys. GitHub proves who it is with an OIDC
token, and the IAM role only trusts two exact branch references. Before
anything deploys, gitleaks looks for secrets, checkov checks the IaC, and
Trivy blocks on CRITICAL findings in my Terraform and Kubernetes manifests.
The vendored application is a black box, so Semgrep, pip-audit and the Trivy
dependency scan only warn on it; a switch turns them into a gate. I proved the
negative: the same workflow file on a scratch branch is denied. You will see
the red run in the demo.
KEEP IN MIND:
- Blocking = the two "trivy config" lines in security.yml (infra, k8s).
- Warn only = scripts/ci-soft.sh: prints a GitHub warning, exits 0, unless
  SUBMODULE_GATE=true. Used for semgrep, pip-audit and trivy fs.
- SAST = Semgrep (p/python rules, vendor/vaultly/app). Not Bandit.
- No step scans the container image (verified in security.yml only).
  Do not say "image scanned".
- Trivy is a pinned binary with a sha256 check (scripts/ci-install-tools.sh).
- The role ARN is a GitHub secret. Hosted runners reach AWS over the
  internet; that is the OIDC design.
-->

# Challenges

<!--
0:03. Next.
-->

## The major obstacle

<!--config:
incrementalLists: true
-->

> - Life?
> - Time?

<!--
0:20. Keep it light, do not linger.
SAY: The real major obstacle was not technical. In the first week my laptop
died, then a family illness plus travel logistics, and during this week a
renovation that started on Tuesday at 7:30. When it rains, it pours. Diogo knows
the long version. The consequence: I scoped to the minimum I could prove, and
I will tell you exactly which proofs are missing.
KEEP IN MIND: the block quote makes this list appear item by item: press next
once per bullet. If both bullets show at once, that is fine.
-->

## Non metaphysical limitations
- My own CI log printed the AWS account ID (variables are not masked)
  - fix: role ARN as a secret, mask-aws-account-id, deleted the logs
- CloudTrail: the shared account is at 5/5 trails, CreateTrail refused
  - fix: exported event history to S3, queried with Athena
- Checker rejected an immutable sub claim (`CKV_AWS_358`): documented skip
- The app never renews its Vault token: 500s after 15 min
  - fix: 8 h role TTL, upstream issue filed

<!--
0:40
SAY: Technically: one, my own CI log printed the account ID, because variables
are not masked. I fixed the symptom first, then found the cause: the role ARN
had to be a secret. I deleted the logs. Lesson: check masking before the first
run. Two, the shared account has a CloudTrail quota of five trails per region,
all used, so creating mine was refused; I exported event history to S3 and
queried it with Athena. Three, checkov flagged the pinned GitHub sub claim; I
documented a skip. Four, the app never renews its token: all secret calls
failed after 15 minutes. I worked around it with a longer TTL and filed an
issue upstream.
KEEP IN MIND:
- CKV_AWS_358 is checkov's GitHub OIDC check; the skip carries a reason.
- Token fix: ROLE_TTL=8h is a workaround, not a fix: say so.
- If short on time, drop item three.
-->

# TODOs

<!--
0:03. Next.
-->

## Insights and open questions

- Missing proofs: RBAC `can-i` checks and KMS role denials not collected
- No CloudTrail trail of my own; GuardDuty detector was pre-existing
- No MFA on my CLI user yet (didn't have the time to set it up)
- Rotation without restart: proven locally and on EKS; not repeated live here
- No branch protection yet, and the OIDC trust depends on develop and main
- Egress 443 from OpenBao to any address (KMS, ghcr.io): accepted risk,
  fix = KMS VPC endpoint

<!--
0:30
SAY: I'll say the gaps before you ask. I did not collect the RBAC and KMS
denial proofs. I have no CloudTrail trail of my own, and the GuardDuty
detector was already there. I did not set up MFA on my CLI user. Branch
protection is not enabled: the OIDC role trusts develop and main, so anyone
who can push there can use it. In a solo repo that is me, but it is the first
thing I would fix. Rotation: the app picks up a changed secret with no
restart; the evidence is in the repo, local and on the cluster, I just did not
repeat it live. Accepted risk: OpenBao egress on 443 is open, and a KMS VPC
endpoint would close it.
KEEP IN MIND:
- Rotation evidence: docs/evidence/01-rotation.txt (local) and
  04-rotation-after-revoke.txt (EKS).
- 04-rotation-run1-expired-token.txt is the token-TTL bug: first run failed
  after 15 min. Mention it if asked about the upstream issue.
- Never say MFA is on. Never say "root token revoked" on this cluster unless
  the SSM check says so.
- If the rules count above was not 0, change the branch protection bullet.
-->

# Demo time!

<!--
3:00 total for the demo, hard stop at 3:15.
KEEP IN MIND:
- Each ```bash slide is an eval block: it shows the command first; the next
  keypress runs it and replaces the command with its output.
- patat runs in the repo root, so relative paths work.
- If any command hangs: Ctrl-C, run `cat` on the evidence file named in
  the slide notes, say "recorded earlier", move on.
- Order: alive -> pods -> hardening -> network -> CI -> audit -> GuardDuty.
-->

## Is it alive, and is the app authenticated?

```bash
for p in healthz readyz api/v1/db/status; do
  printf '%s -> ' "$p"
  curl -s -o /dev/null -w '%{http_code}\n' "https://rg-vaultly.ih.rolan.dog/$p"
done
```

<!--
0:30
SAY: Through the real ALB and TLS. healthz 200 means the app is up. readyz
200 means it logged in to OpenBao with Kubernetes auth. And without a bearer
token the API answers 401.
KEEP IN MIND: expected 200, 200, 401. up.sh verified healthz through the ALB;
readyz and the 401 through the gateway are not yet confirmed: test at 13:00.
If readyz fails, replace it by the pods block's readiness.
-->

## What is running?
```bash
kubectl get pods -n openbao; kubectl get pods -n vaultly
```

<!--
0:15
SAY: Three OpenBao pods, two Vaultly pods, all Running, zero restarts.
KEEP IN MIND: openbao 3/3 Ready is the Raft cluster after KMS auto-unseal.
vaultly x2 is the Deployment, digest-pinned.
-->

## securityContext and namespace

```bash
echo "# pods: namespace pod runAsNonRoot runAsUser dropped-caps"
kubectl get pods -A -o json \
  | jq -r '.items[] | select(.metadata.namespace | test("vaultly|openbao")) | [.metadata.namespace, .metadata.name, (.spec.securityContext.runAsNonRoot // "-"), (.spec.containers[0].securityContext.runAsUser // .spec.securityContext.runAsUser // "-"), (.spec.containers[0].securityContext.capabilities.drop // [] | join(","))] | @tsv' \
  | column -t
```

<!--
0:30
SAY: No pod runs as root. Vaultly runs as user 10001 with all capabilities
dropped and a read-only root filesystem; OpenBao drops ALL as well.
KEEP IN MIND:
- Columns: namespace, pod, runAsNonRoot, runAsUser, dropped caps.
- jq reads only container 0, so a "-" means set elsewhere or not set. Look at
  the output at 13:00 and be ready to say which.
- The long command on screen is expected; do not read it out.
- This is the "no pods running as root" requirement.
-->

## default security group ingress and egress rules

```bash
echo "# default security group: id ingress-rules egress-rules"
vpc=$(aws ec2 describe-vpcs --filters 'Name=tag:Namespace,Values=rg' 'Name=tag:Name,Values=rg-vaultly*' --query 'Vpcs[].VpcId' --output text)
echo "vpcs: $(echo "$vpc" | wc -w)"
aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc" Name=group-name,Values=default --query 'SecurityGroups[].[GroupId,length(IpPermissions),length(IpPermissionsEgress)]' --output text
```

<!--
0:25
SAY: The VPC's default security group has zero inbound and zero outbound rules,
so nothing can use it by accident. Every real rule is a separate resource
with a reason.
KEEP IN MIND: expect "vpcs: 1" and "<sg-id> 0 0". If vpcs is not 1 the
tag filter is wrong (my guess): say "one VPC, default SG empty" only if true.
-->

## ci/cd red/green

```bash
gcli api '/repos/rolandog/vaultly-secure-deploy/actions/workflows/aws-oidc.yml/runs?per_page=10' \
  | jq -r '.workflow_runs[] | [.head_branch, .event, .conclusion] | @tsv'
```

<!--
0:30
SAY: Same workflow file. On develop it succeeds. On my scratch branch,
started by hand, it fails because the role does not trust that branch.
KEEP IN MIND: look for develop/push/success and
scratch/rg-oidc-denied/workflow_dispatch/failure. If the failure is not in the
last 10 rows, rerun with per_page=20. The scratch branch itself is deleted;
the run stays.
-->

## audit trail

```bash
echo '### live leaking account ID'
scripts/audit-export.sh
```

<!--
0:25
SAY: This is the Athena query over exported CloudTrail event history. Twelve
denied web-identity assumptions come from one dispatch: the action retried
twelve times. Three successes are the green runs. Two denied GetParameter
calls are the "what the role cannot do" step.
KEEP IN MIND:
- Columns: event name, outcome, count, first seen (UTC).
- The first_seen of the denials, 08:18:34Z, matches the "Retry AssumeRole:
  attempt 1 of 12" line in the log.
- Do NOT run scripts/audit-export.sh live: it prints the account ID in the
  bucket ARN and takes about 30 s.
- Honest wording: "event history exported to S3", not "my CloudTrail trail".
-->

## Demo: rotation without restart (EKS)

1. What the app serves now, and when its pods started
2. Rotate the secret inside OpenBao
3. Both pods serve the new version, no restart

```bash
scripts/demo-rotation.sh before
```

<!--
0:15
SAY: This is the real cluster: private subnets, TLS at the load balancer. Eight
requests through the ALB, all showing the same version. Note the two pod
names, the restart count and the start times.
-->

## Demo: rotate

```bash
scripts/demo-rotation.sh rotate
```

<!--
0:15
SAY: A new random password goes straight into OpenBao. The operator token comes
from SSM and is not shown, and the password is generated inside the pod, so I
never see it. Nothing touches the app. The app's own role is read-only on
purpose, so a compromised app cannot change its own secret.
IF DENIED: do not debug. Say so, run: cat docs/evidence/04-rotation-after-revoke.txt
-->

## Demo: the app picks it up

```bash
scripts/demo-rotation.sh after
```

<!--
0:30 plus the poll wait (the app polls every 30 s)
SAY: The app polls OpenBao every 30 seconds. The script asks through the load
balancer eight times and only succeeds when all eight answers are the same new
version, so both pods must agree. Same pod names, same start times, restart
count unchanged: nothing was restarted.
IF TIMEOUT: say "the poll interval is longer than my timeout", then run:
cat docs/evidence/04-rotation-after-revoke.txt
-->

## Fake secrets through the Vaultly API

Real cluster, fake values. Bearer token from a Kubernetes secret, never shown.

1. No token: refused
2. Store a fake secret, then read it back
3. Write outside the app's policy: refused
4. Delete it

```bash
scripts/demo-secrets.sh noauth
```

<!--
0:10
SAY: The API sits behind a shared bearer token. Without it the load balancer
forwards the request and the app refuses it.
EXPECT: 401 (a 403 is also accepted by the script).
-->

## Store and read

```bash
scripts/demo-secrets.sh put
```

```bash
scripts/demo-secrets.sh get
```

<!--
0:30
SAY: The app logs in to OpenBao with its Kubernetes identity and writes under
its own path. The value is fake and random. Then I read it back and the script
checks it is the same value.
IF PUT IS REFUSED: do not debug. Say "the app's role is read-only here", run
scripts/demo-secrets.sh seed, then run the get block.
-->

## Outside the policy

```bash
scripts/demo-secrets.sh denied
```

<!--
0:15
SAY: Same token, same API, a path the app's policy does not cover. OpenBao
refuses. A compromised app can only touch what its role allows. This is the
containment point.
EXPECT: HTTP 403 (not verified; any non-2xx counts as refused).
-->

## Clean up

```bash
scripts/demo-secrets.sh delete
```

<!--
0:10
SAY: Delete removes all versions. A read afterwards returns not found.
IF DENIED: skip. The value is fake.
-->

## GuardDuty console

- Enabled in `eu-central-1`
- The detector already existed in this shared account

<!--
0:30
SAY: GuardDuty is enabled in eu-central-1. The detector already existed in this
shared account, so I reused it and did not create one.
KEEP IN MIND:
- Open the tab before the talk, on the GuardDuty summary page, region
  eu-central-1. Do NOT open the account menu (it shows the account ID).
- Go back to the patat window with Zoom's New Share afterwards.
- If the console is slow or logged out: say so and move on.
-->

# Thank you

Thank you very much for your attention!

<!--
0:05
SAY: Thank you. I'm happy to take questions.
-->

## Questions?

<!--
SAY: This was my approach at a secure deployment of Vaultly. Thank you very
much for your attention.
KEEP IN MIND: likely questions and short answers:
- Why OpenBao, not Vault? Free-software fork; the spec allowed "equivalent".
- Why Pod Identity, not IRSA? Account already holds dozens of EKS OIDC
  providers; trust is scoped to namespace and service account.
- How does rotation work? Change the KV v2 secret version; the app polls and
  picks it up with no restart (no RDS: it is a KV change).
- Why no own trail? 5/5 quota in the shared account; I exported event history.
- What does the cluster cost? About $0.21/h list price; not checked against
  billing. Torn down right after the talk.
-->

<!--
This was my approach at a secure deployment of Vaultly.

Thank you very much for your attention.


0:10.
-->
