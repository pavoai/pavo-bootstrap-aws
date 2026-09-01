# Cell: `hc-fmnwao4ct` (awstest — Pavo dev, `453542520145`, us-east-1)

Per-cell config for applying `pavo-bootstrap-aws` to the **awstest** dev cell.
This directory is the single source of truth for how this cell is bootstrapped
and is what the **"Release Omnistrate Bootstrap Dev"** GitHub Action consumes
when it is armed. **It is not armed today** — see *Automated apply (CI)* below.

| File | Purpose |
|---|---|
| `backend.s3.tfbackend` | Partial S3 backend config (state key `pavo-bootstrap-aws/hc-fmnwao4ct/terraform.tfstate`). |
| `hc-fmnwao4ct.tfvars` | Cell input values (non-secret infra IDs + `enable_eck`, `enable_observability`, `observability_grafana_host`, `image_policy_mode`). |

## Apply

```bash
cd pavo-bootstrap-aws

# The module ships NO backend.tf (state backend is operator choice). Create a
# throwaway one FIRST — without a `backend "s3" {}` block present at init time,
# the -backend-config flags are silently ignored and Terraform falls back to
# LOCAL state. backend.tf is gitignored.
printf 'terraform {\n  backend "s3" {}\n}\n' > backend.tf

# S3 creds via SSO: export AWS_PROFILE, or export static env creds.
terraform init  -backend-config=cells/hc-fmnwao4ct/backend.s3.tfbackend  # verify it prints: Backend type: s3
terraform plan  -var-file=cells/hc-fmnwao4ct/hc-fmnwao4ct.tfvars
terraform apply -var-file=cells/hc-fmnwao4ct/hc-fmnwao4ct.tfvars
```

## Automated apply (CI)

The **`Release Omnistrate Bootstrap Dev`** workflow
(`.github/workflows/release-bootstrap-dev.yaml`) runs the commands above for
this cell: `plan` on any PR touching `pavo-bootstrap-aws/**`, and a
manual-approval-gated `apply` on merge to `main` (or `workflow_dispatch`).

There is **no approval gate** — awstest is a throwaway test cell, so once armed
merges auto-apply (mirroring "Release to Omnistrate Dev"). One-time
prerequisites before it can run (see the workflow header):
1. A GitHub OIDC provider in `453542520145`.
2. Two OIDC IAM roles (repo variables): `BOOTSTRAP_DEV_ROLE_ARN` (apply — manage
   IAM / SSM / EKS access entries) and `BOOTSTRAP_DEV_PLAN_ROLE_ARN` (read-only,
   used by the PR `plan` job).
3. A cluster-admin EKS **access entry** for the apply role on `hc-fmnwao4ct` (the
   module applies K8s/Helm objects, so the CI principal needs kube API access).
4. Repo variable `BOOTSTRAP_DEV_APPLY_ENABLED = "true"` to arm the apply job —
   until set, `apply` is skipped (not failed) so merges don't fail-loop before
   the roles/access-entry exist.
5. Repo secrets for the module's two required sensitive inputs:
   `GHCR_READ_USERNAME` + `GHCR_READ_PAT` (already present, combined into
   `ghcr_dockerconfig`) and `PAVO_ALERT_WEBHOOK_URL` (new). Without them the
   plan fails its `observability.tf` preconditions, and an apply would rewrite
   the `pavo-ghcr-signature-pull` secret empty. The workflow fails closed on
   empty GHCR credentials before building the dockerconfig, because the encoded
   form of two empty strings is itself non-empty and would satisfy the module's
   precondition while authenticating as nobody.

**Status as of 2026-08-31: none of the three repo variables are set**, so every
run of this workflow to date has reported `skipped` for both jobs. The OIDC
provider (prerequisite 1) does exist in `453542520145`; the roles do not. So
this cell is currently applied **by hand** using the commands above, not by CI.

Read `skipped` as "never ran", not "passed". Until the variables are set, the
only thing standing between a bad `pavo-bootstrap-aws` change and this cell is
whoever runs the apply.

Note also that arming the `apply` job would make CI apply with HashiCorp
Terraform, while this cell's state is currently owned by OpenTofu provider
addresses (every resource references `registry.opentofu.org/...`). Reconcile
that first — see the provider-source migration notes before setting
`BOOTSTRAP_DEV_APPLY_ENABLED`.

## Enforcement rollout

`image_policy_mode` is currently **`warn`**. Before flipping to `enforce`:

1. Confirm the policy-controller admission log shows **no signature/attestation
   violations** for any running `ghcr.io/pavoai/**` image on the cell
   (`kubectl -n cosign-system logs -l app.kubernetes.io/name=policy-controller`).
2. Set `image_policy_mode = "enforce"` here and re-apply.

Under `enforce`, any unsigned / unenrolled `ghcr.io/pavoai` image is **rejected
at admission** on its next pod (re)creation — so the warn window must be clean
first.

## State reconstruction (2026-07-15, one-time)

The cluster-scoped bootstrap resources on this cell were originally created by a
post-rescope apply whose Terraform state was lost, leaving them **unmanaged**;
the only state in the bucket was a dead, pre-rescope, instance-named one
(`pavo-bootstrap-aws/instance-aplibtqnj/…`, resources since deleted). This cell
was re-brought under management by importing the ~23 live resources into a fresh
cluster-keyed state (`…/hc-fmnwao4ct/…`) and then applying the missing signing
stack (policy-controller + 9 ClusterImagePolicies) + ECK operator.

The dead `instance-aplibtqnj` state object is orphaned and can be removed once
confirmed unneeded.

## Resolved — permission boundary within IAM's 6,144-character limit

`aws_iam_policy.pavo_permission_boundary` (`pavo-permission-boundary-shared`)
had exceeded IAM's managed-policy size limit of **6,144 characters**
(`LimitExceeded: PolicySize 6144`), which had blocked a clean automated apply.
**Fixed in #247** by consolidating the read-only statements in
`policy-statements.json` (rendered size 6,242 → 5,904, zero permission change).
No longer a blocker for the auto-apply Action.
