# pavo-bootstrap-aws

Customer-applied Terraform module that provisions the **bootstrap-tier** IAM
resources Pavo's workload module needs in your AWS account. This module is
applied **once per Pavo instance** by you (the customer), before Pavo's
workload Terraform runs.

## What it creates

- **1 IAM role**: `pavo-eso-${instance_id}` — IRSA role assumed by the
  External Secrets Operator running in your EKS cluster, used to read the
  RDS-managed master password secret from your AWS Secrets Manager and decrypt
  it via your CMK.
- **1 inline role policy**: `pavo-eso-policy-${instance_id}` — grants the ESO
  role `secretsmanager:GetSecretValue` / `DescribeSecret` on `rds!*` and
  `pavo-*` secrets, plus `kms:Decrypt` / `DescribeKey` scoped via
  `kms:ViaService = secretsmanager.<region>.amazonaws.com`.
- **2 IAM policies (permission boundaries)**:
  - `pavo-permission-boundary-${instance_id}` — workload boundary attached to
    Pavo's app IAM role (`pavo-role-*`). Source of truth:
    `policy-statements.json`.
  - `pavo-permission-boundary-ebs-csi-${instance_id}` — separate boundary for
    the EBS CSI driver IRSA role. Mirrors `AmazonEBSCSIDriverPolicy`. Source:
    `ebs-csi-policy-statements.json`.
- **7 SSM parameters** under `/pavo/${instance_id}/`: `vpc_id`,
  `private_subnet_ids`, `eks_cluster_name`, `eks_oidc_provider`,
  `eso_role_arn`, `permission_boundary_arn`, `ebs_csi_permission_boundary_arn`.

## Configuring Terraform state (REQUIRED)

**Do not run with local state.** Before running `terraform init`, you MUST
create a `backend.tf` file (gitignored) with your chosen backend. Two patterns:

### A. Partial config + `-backend-config` flags

```hcl
# backend.tf
terraform {
  backend "s3" {}
}
```

```bash
terraform init \
  -backend-config="bucket=my-tf-state" \
  -backend-config="key=pavo-bootstrap-aws/${INSTANCE_ID}/terraform.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="dynamodb_table=my-tf-state-locks" \
  -backend-config="encrypt=true"
```

### B. Fully-specified inline

```hcl
# backend.tf
terraform {
  backend "s3" {
    bucket         = "my-tf-state"
    key            = "pavo-bootstrap-aws/<instance-id>/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "my-tf-state-locks"
    encrypt        = true
  }
}
```

```bash
terraform init
```

**CRITICAL**: without ANY backend block in the source, `-backend-config` flags
are silently ignored and Terraform defaults to local state. Verify init output
reads `Backend type: s3` (not `local`).

For Terraform Cloud / HCP Terraform / other backends, see
[Terraform docs](https://developer.hashicorp.com/terraform/language/settings/backends/configuration).

## Prerequisites

- AWS account with admin credentials configured (`aws sts get-caller-identity`
  works).
- EKS cluster + VPC already provisioned by Omnistrate's CFN bootstrap stack.
- AWS CLI ≥ v2.

## Variables

| Variable | Description |
|---|---|
| `aws_region` | AWS region where the Pavo deployment lives. |
| `instance_id` | Pavo deployment instance ID (matches Omnistrate's `$sys.id`). 1-40 chars, lowercase alphanumeric + hyphens, no leading/trailing hyphen. |
| `vpc_id` | VPC ID provisioned by Omnistrate's CFN. |
| `private_subnet_ids` | Private subnet IDs (Omnistrate-tagged `kubernetes.io/role/internal-elb=1`). |
| `eks_cluster_name` | EKS cluster name (Omnistrate-provisioned). |
| `eks_oidc_provider` | EKS OIDC issuer URL **without** the `https://` prefix. |

Populate from the Omnistrate console (instance details panel) or via
`aws eks describe-cluster --name <cluster-name>`.

## Apply

```bash
terraform init <see above>
terraform plan
terraform apply
```

Capture outputs (especially `eso_role_arn` — needed for the CMK key policy):

```bash
terraform output
```

## Setting up the CMK (separate from bootstrap; before workload deploys)

1. **First**, run `terraform apply` for this module and capture the ESO role
   ARN:

   ```bash
   ESO_ROLE_ARN=$(terraform output -raw eso_role_arn)
   echo "$ESO_ROLE_ARN"
   ```

   The CMK key policy (step 3) needs both Omnistrate's workload role ARN AND
   this ESO role ARN as principals. Without the ESO principal, ESO cannot
   decrypt the RDS-managed secret at runtime.

2. Create a KMS key in your AWS account (or reuse an existing one).

3. Attach this **5-statement key policy** (with `<CUSTOMER_ACCOUNT_ID>`,
   `<OMNISTRATE_WORKLOAD_ROLE_ARN>`, `<ESO_ROLE_ARN_FROM_BOOTSTRAP>`, and
   `<REGION>` substituted):

   ```json
   [
     {
       "Sid": "EnableRootPermissions",
       "Effect": "Allow",
       "Principal": { "AWS": "arn:aws:iam::<CUSTOMER_ACCOUNT_ID>:root" },
       "Action": "kms:*",
       "Resource": "*"
     },
     {
       "Sid": "AllowOmnistrateWorkloadDescribe",
       "Effect": "Allow",
       "Principal": { "AWS": "<OMNISTRATE_WORKLOAD_ROLE_ARN>" },
       "Action": ["kms:DescribeKey"],
       "Resource": "*"
     },
     {
       "Sid": "AllowOmnistrateWorkloadUseViaService",
       "Effect": "Allow",
       "Principal": { "AWS": "<OMNISTRATE_WORKLOAD_ROLE_ARN>" },
       "Action": ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*"],
       "Resource": "*",
       "Condition": {
         "StringEquals": {
           "kms:ViaService": [
             "rds.<REGION>.amazonaws.com",
             "secretsmanager.<REGION>.amazonaws.com"
           ]
         }
       }
     },
     {
       "Sid": "AllowOmnistrateWorkloadGrants",
       "Effect": "Allow",
       "Principal": { "AWS": "<OMNISTRATE_WORKLOAD_ROLE_ARN>" },
       "Action": ["kms:CreateGrant", "kms:ListGrants", "kms:RevokeGrant"],
       "Resource": "*",
       "Condition": { "Bool": { "kms:GrantIsForAWSResource": "true" } }
     },
     {
       "Sid": "AllowESORoleDecryptViaSecretsManager",
       "Effect": "Allow",
       "Principal": { "AWS": "<ESO_ROLE_ARN_FROM_BOOTSTRAP>" },
       "Action": ["kms:Decrypt", "kms:DescribeKey"],
       "Resource": "*",
       "Condition": {
         "StringEquals": {
           "kms:ViaService": "secretsmanager.<REGION>.amazonaws.com"
         }
       }
     }
   ]
   ```

4. Paste the CMK ARN into the Omnistrate UI under `db_kms_key_arn`. The
   instance won't provision until set (`required: true`).

5. **Note on the same CMK serving dual duty**: this single CMK encrypts both
   RDS storage *and* the master-password Secrets Manager secret. Statements
   2-4 grant the workload role what RDS needs to provision both. Statement 5
   grants the ESO role what it needs to decrypt the secret at runtime.

6. The `db_kms_key_arn` value can be either a **key ARN** (`arn:aws:kms:<region>:<account>:key/<uuid>`)
   or an **alias ARN** (`arn:aws:kms:<region>:<account>:alias/<name>`). Both
   work — RDS resolves either at instance creation time. **Aliases are
   accepted for create-time convenience only — not for rotation.** Reasons to
   use an alias: readable naming in the Omnistrate UI
   (`alias/coursera-pavo-db` vs a UUID); environment-agnostic spec values if
   you use the same alias name across dev/prod; consistency with your
   existing alias-based KMS naming convention. RDS resolves the alias to a
   specific key ARN at creation and is bound to that key for the instance's
   lifetime — re-pointing the alias afterwards has no effect on existing
   data. To rotate the CMK, follow the **Rotation runbook** below
   (snapshot → restore-to-new-instance → DNS cutover).

## Rotation runbook for the RDS CMK

AWS does not permit changing the KMS key on an existing RDS instance. To
rotate:

1. Snapshot the existing RDS instance.
2. Restore the snapshot to a new instance with the new KMS key
   (`--kms-key-id <new-key-arn>`).
3. Cut DNS over to the new instance.
4. Decommission the old instance once traffic has drained.

This is a multi-step manual procedure; coordinate with Pavo support.

## Cluster-sharing assumption

This module assumes **one Pavo instance per EKS cluster**. ESO + IRSA are
designed for single-instance per cluster. If shared clusters become a
requirement, ESO moves to a cluster-level deployment-cell amenity (tracked
as a follow-up).
