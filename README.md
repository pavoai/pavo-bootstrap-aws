# pavo-bootstrap-aws

Customer-applied Terraform module that provisions the **bootstrap-tier** IAM
resources Pavo's workload module needs in your AWS account. This module is
applied **once per deployment cell** (one EKS cluster) by you (the customer),
before Pavo's workload Terraform runs. It does not depend on a Pavo instance
ID, so it can run as soon as the deployment cell exists.

## Source of truth & versioning

This module's source of truth is the [`pavo-bootstrap-aws/` subdirectory of
`pavoai/pavo-terraform-templates`](https://github.com/pavoai/pavo-terraform-templates/tree/main/pavo-bootstrap-aws),
mirrored to [`pavoai/pavo-bootstrap-aws`](https://github.com/pavoai/pavo-bootstrap-aws)
for customer consumption.

**Two lanes** on the mirror:

- **`main`** — continuously updated snapshot of the latest source. Useful for
  review, dev, and reading the latest docs.
- **`v*` tags** — manually-cut stable checkpoints (semver). What customers
  should pin to in production.

```hcl
# Production deployments: pin to a tag.
module "pavo_bootstrap" {
  source = "git::https://github.com/pavoai/pavo-bootstrap-aws.git?ref=v0.2.0"
  # ...
}

# Review / dev only: track main.
module "pavo_bootstrap" {
  source = "git::https://github.com/pavoai/pavo-bootstrap-aws.git?ref=main"
  # ...
}
```

Cutting a new stable tag (`bootstrap-vMAJOR.MINOR.PATCH` on the source repo)
publishes a `vMAJOR.MINOR.PATCH` snapshot to the mirror; pushes to the source
`main` branch that touch this subdir are auto-mirrored to the mirror's `main`.

## Resource scopes

The resources this module creates fall into two scopes:

- **Account-scoped** — the two IAM permission boundaries and the single-cell
  sentinel SSM parameter. They reference no cell/instance resources, so they are
  shared across the whole AWS account.
- **Cell-scoped** — the ESO IRSA role + ESO Helm release, the EBS CSI driver IRSA
  wiring (IAM role + SA annotation + RBAC), the Reloader Helm release, the
  `pd-balanced` StorageClass, the `pavo-nginx` IngressClass, the Let's Encrypt
  ClusterIssuer, the EKS access entry for the Omnistrate runner, and the cell's
  network metadata.

**Short-term design:** a single bootstrap module, run **once per cell**. It
creates the account-shared permission boundaries (stable `-shared` names) and
the full cell-scoped K8s/Helm/IAM stack (keyed on the cluster name) together in
one apply. **This assumes one deployment cell per AWS account.**

A **single-cell-per-account sentinel** (`/pavo/shared/bootstrap_cell` SSM
parameter, `prevent_destroy = true`) is the hard guard: a second cell's apply
in the same account hits AWS `ParameterAlreadyExists` on this name and fails
**before** any IAM boundary, role, or K8s resource is created. To inspect:

```bash
aws ssm get-parameter --name /pavo/shared/bootstrap_cell \
  --query 'Parameter.Value' --output text
# prints the cluster name this account was bootstrapped for
```

See *Scoping notes* below for the planned account/cell module split that fully
supports multi-cell-per-account.

## What it creates

### IAM (account + cell scope)

- **2 IAM roles** (cell-scoped):
  - `pavo-eso-${eks_cluster_name}` — IRSA role assumed by the External Secrets
    Operator running in your EKS cluster, used to read the RDS-managed master
    password secret from your AWS Secrets Manager and decrypt it via your CMK.
  - `pavo-ebs-csi-<cluster-prefix>-<cell-hash>` — IRSA role for the
    `kube-system/ebs-csi-controller-sa` ServiceAccount. The cell-hash suffix
    keeps the name unique even when `<eks_cluster_name>` gets truncated to fit
    IAM's 64-char role-name limit (prefix-55 + dash + hash-8 = 64).
- **1 inline role policy**: `pavo-eso-policy-${eks_cluster_name}` — grants ESO
  `secretsmanager:GetSecretValue` / `DescribeSecret` on `rds!*` and `pavo-*`
  secrets, plus `kms:Decrypt` / `DescribeKey` scoped via
  `kms:ViaService = secretsmanager.<region>.amazonaws.com`.
- **1 attached managed policy**: `AmazonEBSCSIDriverPolicy` attached to the
  EBS CSI role above.
- **2 IAM policies (permission boundaries, account-scoped)**:
  - `pavo-permission-boundary-shared` — workload boundary attached to Pavo's
    app IAM role (`pavo-role-*`). Source of truth: `policy-statements.json`.
  - `pavo-permission-boundary-ebs-csi-shared` — separate boundary for the EBS
    CSI driver IRSA role. Mirrors `AmazonEBSCSIDriverPolicy`. Source:
    `ebs-csi-policy-statements.json`.

### EKS (cell scope)

- **1 EKS access entry** (`aws_eks_access_entry.runner`) + cluster-admin policy
  association — grants the Omnistrate Terraform runner cluster-admin RBAC on
  the cell. Principal is `var.runner_role_arn`. Pre-rescope this lived in
  `terraform-omnistrate-aws/` and was created on every instance create; now
  it's created once here per cell.

### Helm (cell scope)

- `helm_release.external_secrets` — ESO installed in the `external-secrets`
  namespace, IRSA-annotated with the `pavo-eso-${cluster}` role above.
- `helm_release.stakater_reloader` — Reloader installed in the `reloader`
  namespace, watching globally for Secret/ConfigMap changes.
- `helm_release.policy_controller` — Sigstore Policy Controller admission
  webhook installed in the `cosign-system` namespace. Validates ghcr.io/pavoai
  images against the per-service ClusterImagePolicy objects below.

### Kubernetes (cell scope)

- `kubernetes_annotations.ebs_csi_sa` — patches the `eks.amazonaws.com/role-arn`
  annotation on `kube-system/ebs-csi-controller-sa`.
- `kubernetes_role.ebs_csi_leases` + RoleBinding in `kube-system` — RBAC the
  EBS CSI controller needs for leader election.
- `kubernetes_storage_class_v1.ebs_gp3` — `pd-balanced` cluster-scoped
  StorageClass (gp3, name matches GCP convention used by connector PVCs).
- `kubectl_manifest.pavo_ingress_class` — cluster-scoped `pavo-nginx`
  IngressClass.
- `kubectl_manifest.pavo_letsencrypt_prod` — cluster-scoped Let's Encrypt
  ClusterIssuer (HTTP-01).
- `kubectl_manifest.pavo_image_policy` — one cluster-scoped ClusterImagePolicy
  per Pavo service (for_each over `image-manifest.json`). Binds each
  `ghcr.io/pavoai/<svc>*` glob to its dedicated Cloud Build signer identity.

### Sigstore policy controller (cell scope)

The Sigstore Policy Controller and the per-service ClusterImagePolicy
resources are cluster-scoped — there is exactly one owner per EKS cluster,
which is this module. Per-instance pavoInfra only adds the
`policy.sigstore.dev/include = "true"` label to each instance namespace; the
controller picks up labeled namespaces dynamically with no Terraform-graph
dependency. Operational invariant: **apply `pavo-bootstrap-aws` BEFORE
expecting policy enforcement on a fresh pavoInfra instance**, because the
controller has to be up before workloads are admitted.

The service list + image globs come from `image-manifest.json` vendored
alongside `main.tf` (this module is applied standalone by customers, so the
wider repo isn't shipped to them). The canonical source is
`spec/image-manifest.json`; keep `pavo-bootstrap-aws/image-manifest.json` in
sync when adding a new service.

Mode defaults to `"warn"` (`var.image_policy_mode`); flip to `"enforce"` once
every Pavo image in the cell is signed + attested. Per-service signer SAs
are provisioned by `central-ci/`. During the migration window the shared
`cloud-build@<central_ci_project_id>` SA is also accepted — drop that
authority once every service has migrated to its dedicated SA.

### SSM (account + cell scope)

- **5 cell-scoped** under `/pavo/cells/${eks_cluster_name}/`: `vpc_id`,
  `private_subnet_ids`, `eks_cluster_name`, `eks_oidc_provider`, `eso_role_arn`.
- **3 account-scoped** under `/pavo/shared/`: `permission_boundary_arn`,
  `ebs_csi_permission_boundary_arn`, `bootstrap_cell` (the single-cell sentinel
  described under *Resource scopes*; `prevent_destroy = true`).

## Permission boundary scoping & verification

The workload boundary (`policy-statements.json` → `pavo-permission-boundary-shared`)
uses two scoping patterns depending on whether the service supports name-prefix
ARNs:

- **Name-prefix ARN scoping** (RDS, ElastiCache, S3, SNS, SQS, IAM, SSM, KMS via
  `kms:ViaService`): every Pavo-created resource is named `pavo-*`. Mutating
  actions are scoped to `arn:aws:<service>:*:*:<type>:pavo-*`.
- **Tag-based conditional scoping** (EFS): EFS ARNs use auto-generated IDs
  (`fs-XXXX`), so name-prefix doesn't apply. Instead the boundary requires the
  `managed_by=pavo` tag, which `terraform-omnistrate-aws` attaches to every
  resource via the AWS provider's `default_tags`:
  - `CreateFileSystem` requires `aws:RequestTag/managed_by = pavo` (Terraform's
    `default_tags` puts this in the create-call automatically).
  - All other EFS mutating actions require `aws:ResourceTag/managed_by = pavo`.

**Footgun**: if `managed_by` is removed from a Pavo EFS file system (via direct
AWS CLI, not Terraform), subsequent mutations on it will fail — including
re-tagging it. Don't strip the tag.

**Describe / List actions stay wildcard** (`"resources": ["*"]`) by AWS IAM
design — those actions don't accept resource-level permissions. Same constraint
applies to `s3:ListAllMyBuckets`, `sns:ListTopics`, etc. (also `*` in this file).
Read-only metadata; no data access.

### Verifying boundary edits locally

After editing `policy-statements.json`, re-render the committed snapshot and
run the simulation matrix.

**1. Re-render the snapshot** (required — CI fails if drift exists):

```bash
scripts/render-policy.sh pavo-bootstrap-aws/policy-statements.json \
  | jq . > pavo-bootstrap-aws/rendered-permission-boundary.json
```

**2. Simulate the matrix** (requires AWS creds + `boto3`):

```bash
pip install boto3
scripts/simulate-policy.py
```

The script uses `aws iam simulate-custom-policy` with the boundary fed through
`--permissions-boundary-policy-input-list` against an allow-all identity policy,
so the simulation reflects how the boundary actually behaves in production
(capping the identity policy, not acting as one). It tests ~20 cases including:

- RDS / ElastiCache / EFS read-only on `*` → allowed
- RDS / ElastiCache mutations on `pavo-*` ARNs → allowed
- RDS / ElastiCache mutations on non-`pavo-*` ARNs → denied
- EFS `CreateFileSystem` with `aws:RequestTag/managed_by=pavo` → allowed
- EFS `CreateFileSystem` without the request tag → denied
- EFS mutations with `aws:ResourceTag/managed_by=pavo` → allowed
- EFS mutations without the resource tag → denied
- S3 / SQS sanity (existing scopings still work)

Any caller with `iam:SimulateCustomPolicy` permission works — the simulation is
account-agnostic.

### Migrating existing customers when boundary changes

Customers who applied this module **before** the EFS tag-scoping change need a
one-time tag backfill on the existing EFS file system, **before** re-applying
the bootstrap with the new boundary. Without the backfill, the new boundary
would block all mutations on the pre-existing un-tagged file system.

For `awstest`:

```bash
# 1. Find the awstest EFS file system ID.
aws efs describe-file-systems --region us-east-1 \
  --query "FileSystems[?starts_with(Name, 'pavo-efs-')].FileSystemId" --output text

# 2. Backfill all 4 Pavo standard tags (use the actual instance ID for omnistrate_instance).
aws efs tag-resource \
  --resource-id <fs-id-from-step-1> \
  --tags \
    Key=managed_by,Value=pavo \
    Key=customer,Value=awstest \
    Key=environment,Value=prod \
    Key=omnistrate_instance,Value=<awstest-omnistrate-instance-id>

# 3. Verify all 4 tags present.
aws efs describe-tags --file-system-id <fs-id-from-step-1>

# 4. Re-apply the bootstrap module (refreshes the permission boundary in IAM).
terraform -chdir=pavo-bootstrap-aws apply
```

New customers (e.g. Coursera): no migration needed. They get the tightened
boundary on first apply — `terraform-omnistrate-aws` provider default_tags
applies `managed_by=pavo` to every EFS file system on creation.

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
  -backend-config="key=pavo-bootstrap-aws/${EKS_CLUSTER_NAME}/terraform.tfstate" \
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
    key            = "pavo-bootstrap-aws/<eks-cluster-name>/terraform.tfstate"
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
- **CLIs on PATH**: `aws` (≥ v2), `kubectl`, `helm`. Bootstrap now creates K8s
  + Helm resources on the cell's cluster, so all three are required.
- **Cluster-admin RBAC on the EKS cluster** from the principal running
  `terraform apply`. The Omnistrate CFN-provisioned cluster typically grants
  this via the AdministratorAccess SSO role; if your principal doesn't have
  it, see *Case B: bootstrapping without K8s admin* below.

Run **`scripts/preflight.sh`** before `terraform init` — it verifies CLI
presence, AWS creds, cluster reachability, and cluster-admin RBAC. Hard gate is
`kubectl auth can-i '*' '*' --all-namespaces`. The script refreshes your
kubeconfig as a side-effect.

```bash
export EKS_CLUSTER_NAME=hc-fmnwao4ct  # your cluster name
export AWS_REGION=us-east-1           # your region
./scripts/preflight.sh
```

## Variables

| Variable | Description |
|---|---|
| `aws_region` | AWS region where the Pavo deployment lives. |
| `vpc_id` | VPC ID provisioned by Omnistrate's CFN. |
| `private_subnet_ids` | Private subnet IDs (Omnistrate-tagged `kubernetes.io/role/internal-elb=1`). |
| `eks_cluster_name` | EKS cluster name (Omnistrate-provisioned). |
| `eks_oidc_provider` | EKS OIDC issuer URL **without** the `https://` prefix. |
| `runner_role_arn` | IAM role ARN of the Omnistrate Terraform runner principal that needs cluster-admin RBAC on this EKS cluster. MUST be the role ARN (`arn:aws:iam::<acct>:role/<RoleName>`), NOT an assumed-role session ARN. |
| `image_policy_mode` | Sigstore ClusterImagePolicy enforcement mode for `ghcr.io/pavoai/**` images. `"warn"` (default) admits failing images and emits a Warning to admission callers; `"enforce"` rejects admission. Flip to `"enforce"` once every Pavo image in the cell is signed + attested. |
| `policy_controller_chart_version` | Helm chart version for `sigstore/policy-controller`. Default `0.10.6`. Bump deliberately and validate in `"warn"` mode first — chart upgrades can change webhook config paths or CRD API versions. |
| `central_ci_project_id` | GCP project hosting Pavo's central Cloud Build that builds + signs all `ghcr.io/pavoai/*` images. Default `onboarding-455713`. The per-service signing SAs live here as `cloud-build-<service>@<central_ci_project_id>.iam.gserviceaccount.com`. Override only if you've forked the signing pipeline into a different GCP project. |

Populate the first 5 from the Omnistrate console (instance details panel) or
via `aws eks describe-cluster --name <cluster-name>`. The 3 Sigstore variables
default to safe values — override only if you need to flip enforcement mode,
pin a different chart version, or repoint the signer project.

### How to get `runner_role_arn`

The runner role is the IAM role Omnistrate uses to apply Terraform inside your
account. It's the role that needs cluster-admin RBAC on the EKS cluster so
`terraform-omnistrate-aws/` (pavoInfra) can manage per-instance K8s resources.

You'll typically find it in the Omnistrate UI under your account integration
page, OR by listing the IAM roles in your AWS account whose name starts with
`omnistrate-`:

```bash
aws iam list-roles \
  --query 'Roles[?starts_with(RoleName, `omnistrate-`) || contains(RoleName, `omnistrate`)].[RoleName,Arn]' \
  --output table
```

Pick the role that Omnistrate's runner assumes — usually
`omnistrate-custom-terraform-role-for-sm-<id>` or similar — and use its
**role ARN** (the `arn:aws:iam::...:role/...` form). If you get an assumed-role
session ARN instead (`arn:aws:sts::...:assumed-role/.../session-name`), strip
the trailing `/<session-name>` and replace
`:sts::<acct>:assumed-role/` with `:iam::<acct>:role/`.

The `variables.tf` validation rejects assumed-role ARN shapes with a clear
error pointing back to this section.

## Apply

```bash
./scripts/preflight.sh
# Configure backend.tf first (see "Configuring Terraform state" above), then:
terraform init
terraform plan
terraform apply
```

Capture outputs (especially `eso_role_arn` — needed for the CMK key policy):

```bash
terraform output
```

## Case B: bootstrapping without K8s admin

If `scripts/preflight.sh` fails on the `kubectl auth can-i '*' '*' --all-namespaces`
hard gate, the principal running `terraform apply` lacks cluster-admin RBAC on
the EKS cluster. Bootstrap can't create the EKS access entry for the Omnistrate
runner (that's exactly what it's trying to do) without already having access.

**Remediation** — create a one-off access entry for your principal manually,
then re-run bootstrap. The bootstrap apply will then add a separate access
entry for `var.runner_role_arn`; the one-off entry stays out of Terraform state
and can be removed afterwards.

```bash
# Get your current principal's underlying role ARN (NOT the assumed-role form):
MY_ROLE_ARN=$(aws sts get-caller-identity --query Arn --output text \
  | sed 's|:sts::|:iam::|; s|:assumed-role/|:role/|; s|/[^/]*$||')

# Create the access entry + admin policy association:
aws eks create-access-entry \
  --cluster-name "$EKS_CLUSTER_NAME" \
  --principal-arn "$MY_ROLE_ARN" \
  --region "$AWS_REGION"

aws eks associate-access-policy \
  --cluster-name "$EKS_CLUSTER_NAME" \
  --principal-arn "$MY_ROLE_ARN" \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster \
  --region "$AWS_REGION"

# Re-run preflight; it should now pass.
./scripts/preflight.sh

# Apply.
terraform apply

# Optional cleanup: once bootstrap has run, the one-off access entry for your
# principal is no longer required (bootstrap created a permanent one for the
# Omnistrate runner). Remove it if your governance prefers no out-of-band
# access entries:
aws eks delete-access-entry \
  --cluster-name "$EKS_CLUSTER_NAME" \
  --principal-arn "$MY_ROLE_ARN" \
  --region "$AWS_REGION"
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

## Scoping notes

This module's resources are **account-scoped** (the permission boundaries + the
single-cell sentinel) and **cell-scoped** (the ESO + EBS CSI IRSA roles, the
Helm releases, the cluster-scoped K8s resources, the EKS access entry, and the
cell's network metadata) — see *Resource scopes* above.

**Limitation — one deployment cell per account.** This is a single module run
once per cell that creates account-scoped *and* cell-scoped resources together.
Running it for a **second cell in the same account** re-creates the
account-scoped `-shared` permission boundaries from fresh state and would
collide (`EntityAlreadyExists`) — the boundary names are account-global.

**Today's hard guard.** The `/pavo/shared/bootstrap_cell` SSM sentinel
(`prevent_destroy = true`) is the structural defense. A second bootstrap apply
in the same account hits AWS `ParameterAlreadyExists` on this name and fails
**before** any IAM boundary, role, or K8s resource is touched. The
`depends_on = [aws_ssm_parameter.single_cell_guard]` on every shared resource
serializes everything behind the sentinel; the first error is the cleanest
possible one.

**Planned follow-up — split the module** so multi-cell accounts are supported:

1. *account bootstrap* — the two shared permission boundaries + `/pavo/shared/*`
   SSM parameters + the sentinel; applied **once per AWS account**.
2. *cell bootstrap* — the ESO + EBS CSI IRSA roles, Helm releases, EKS access
   entry, cluster-scoped K8s resources, and `/pavo/cells/<eks_cluster_name>/*`
   SSM parameters; applied **once per deployment cell**.

## Ownership rules

Resources are scoped at one of four levels. The level determines which
module owns the resource, who applies it, and where state lives.

| Scope | Module | Applier | State backend | Examples |
|---|---|---|---|---|
| **Account** | `pavo-bootstrap-aws/` | Customer (AWS creds) | Customer-local | IAM permission boundaries, `/pavo/shared/*` SSM |
| **Cell** (one EKS cluster) | `pavo-bootstrap-aws/` | Customer (AWS creds) | Customer-local | IngressClass, ClusterIssuer, ESO/Reloader helm releases, EBS CSI role, EKS access entry, `/pavo/cells/<cluster>/*` SSM |
| **Customer** (one `customer_name`) | `pavo-customer-bootstrap/` | Pavo ops (Zitadel PAT) | GCS `gs://pavo-terraform-state`, prefix `customer-bootstrap/<customer>` | Zitadel org, project, OIDC app, IdPs, login policy |
| **Instance** (one Pavo deployment) | `terraform-omnistrate-aws/` | Omnistrate runner | Omnistrate-managed | RDS, ElastiCache, S3, SNS/SQS, EFS, workload IAM role, app namespace, app secrets, Elastic Cloud deployment |

### Picking the right module for a new resource

1. If deleting one Pavo instance shouldn't delete it → not `terraform-omnistrate-aws/`.
2. If its `name` doesn't include `var.instance_id` → probably not `terraform-omnistrate-aws/`.
3. If it lives in Pavo's identity tenant (Zitadel) → `pavo-customer-bootstrap/`.
4. If it's cluster-scoped K8s or per-cell IAM → `pavo-bootstrap-aws/`.
5. Otherwise (per-instance app resource) → `terraform-omnistrate-aws/`.

### Hard rules

- No cluster-scoped K8s resource may live in `terraform-omnistrate-aws/`, even with `apply_only = true` as a mitigation.
- `pavo-customer-bootstrap/` MUST NOT declare `instance_id` as a variable (structural enforcement of the customer-hostname invariant).
- A second cell in the same AWS account is currently guarded by an SSM sentinel — see `pavo-bootstrap-aws/README.md`.
