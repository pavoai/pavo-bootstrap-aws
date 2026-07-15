# Cell: `hc-fmnwao4ct` (awstest — Pavo dev, `453542520145`, us-east-1)

Per-cell config for applying `pavo-bootstrap-aws` to the **awstest** dev cell.
This directory is the single source of truth for how this cell is bootstrapped
and is what the (planned) **"Release Omnistrate Bootstrap Dev"** GitHub Action
consumes.

| File | Purpose |
|---|---|
| `backend.s3.tfbackend` | Partial S3 backend config (state key `pavo-bootstrap-aws/hc-fmnwao4ct/terraform.tfstate`). |
| `hc-fmnwao4ct.tfvars` | Cell input values (non-secret infra IDs + `enable_eck`, `image_policy_mode`). |

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

## Known issue — permission boundary exceeds IAM's 6,144-character limit

`aws_iam_policy.pavo_permission_boundary` (`pavo-permission-boundary-shared`)
as currently rendered from `policy-statements.json` exceeds IAM's managed-policy
size limit of **6,144 characters** (IAM counts non-whitespace characters in the
JSON document), so `terraform apply` fails to update it
(`LimitExceeded: Cannot exceed quota for PolicySize: 6144`). The live boundary
stays at an older, smaller (working) version. **Until the boundary is
trimmed/split, every apply exits non-zero on this one resource** — which blocks
a clean automated (GHA) apply. Track and fix at the module level before enabling
the auto-apply Action.
