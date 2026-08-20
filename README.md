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

- **Account-scoped** — the IAM workload permission boundary and the single-cell
  sentinel SSM parameter. They reference no cell/instance resources, so they are
  shared across the whole AWS account.
- **Cell-scoped** — the ESO IRSA role + ESO Helm release, the Reloader Helm
  release, the `pd-balanced` StorageClass, the `pavo-nginx` IngressClass, the
  Let's Encrypt ClusterIssuer, the EKS access entry for the Omnistrate runner,
  and the cell's network metadata.

> **The EBS CSI driver is owned by Omnistrate, not this module.** Omnistrate
> pre-installs and lifecycle-manages the driver on every cell (IRSA role, its
> `kube-system/ebs-csi-controller-sa` ServiceAccount, and RBAC), and its role
> already carries the `omnistrate-bootstrap-permissions-boundary`. This module
> only adds the `pd-balanced` StorageClass on top of that driver — it does not
> re-own the driver's role/SA/RBAC (doing so caused a reconcile tug-of-war).

**Short-term design:** a single bootstrap module, run **once per cell**. It
creates the account-shared permission boundary (stable `-shared` name) and
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

- **1 IAM role** (cell-scoped):
  - `pavo-eso-${eks_cluster_name}` — IRSA role assumed by the External Secrets
    Operator running in your EKS cluster, used to read the RDS-managed master
    password secret from your AWS Secrets Manager and decrypt it via your CMK.
- **1 inline role policy**: `pavo-eso-policy-${eks_cluster_name}` — grants ESO
  `secretsmanager:GetSecretValue` / `DescribeSecret` on `rds!*` and `pavo-*`
  secrets, plus `kms:Decrypt` / `DescribeKey` scoped via
  `kms:ViaService = secretsmanager.<region>.amazonaws.com`.
- **1 IAM policy (permission boundary, account-scoped)**:
  - `pavo-permission-boundary-shared` — workload boundary attached to Pavo's
    app IAM role (`pavo-role-*`). Source of truth: `policy-statements.json`.

## Customer-managed-key (CMK) EBS volumes (`gp3-cmk`)

For data residency / key custody, EBS volumes (self-hosted Elasticsearch data,
the in-VPC observability PVCs) can be encrypted with **your own KMS key** via a
`gp3-cmk` StorageClass (a `gp3` StorageClass with `kmsKeyId` set). Default
`aws/ebs`-key volumes work with no extra setup; **customer-CMK volumes need three
things** because the EBS CSI driver's role must be allowed to use your key:

1. **Tag the key** — add this tag to the CMK you want used for EBS:
   ```
   omnistrate.com/customer-managed-kms = true
   ```
   The managed EBS-CSI role's KMS permissions are scoped to keys carrying this
   tag (so the driver can only use keys you've explicitly opted in).
2. **Reconcile the account's `AccountConfigSetup` stack** so the managed EBS-CSI
   driver role picks up the KMS actions (`kms:CreateGrant` + the crypto set,
   scoped via `kms:ViaService = ec2.<region>.amazonaws.com` and the
   `omnistrate.com/customer-managed-kms` tag). This is the same stack update
   described in *Reconciling an already-onboarded account* below — `CreateGrant`
   is the action the driver needs to hand the grant to EBS at attach time.
3. **Only for locked-down keys** — if your key policy does **not** delegate to the
   account root, add a key-policy statement naming the **Omnistrate-managed
   EBS-CSI driver role** with the same KMS actions. If the key policy delegates
   to root (the default), the IAM side alone is enough and no key-policy edit is
   needed. The driver runs as the Omnistrate-owned role (not a Pavo role) — get
   its exact ARN from the cell:
   ```
   kubectl -n kube-system get sa ebs-csi-controller-sa \
     -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'
   # -> arn:aws:iam::<acct>:role/omnistrate-ebs-csi-driver-<cell>-<hash>
   ```

> `kms:ViaService = ec2.<region>.amazonaws.com` scopes the role to using the key
> only through EC2/EBS, never the KMS API directly; **your key policy stays the
> per-key gate.**

Then reference the CMK-backed `gp3-cmk` StorageClass in your PVCs. (On a cell
whose key already delegates to account root — e.g. our `awstest` — the IAM side
alone provisions CMK volumes; the tag + key policy matter for locked-down
customer keys.)

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

- `kubernetes_storage_class_v1.ebs_gp3` — `pd-balanced` cluster-scoped
  StorageClass (gp3, name matches GCP convention used by connector PVCs). Uses
  Omnistrate's pre-installed `ebs.csi.aws.com` provisioner.
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

Mode defaults to `"enforce"` (`var.image_policy_mode`) — admission rejects any
`ghcr.io/pavoai/**` image that fails cosign signature, SBOM attestation, or
vuln attestation verification. Per-service signer SAs are provisioned by
`central-ci/`. During the migration window the shared
`cloud-build@<central_ci_project_id>` SA is also accepted — drop that
authority once every service has migrated to its dedicated SA. Set to
`"warn"` only for a one-off bake-in on a fresh image lineup before the first
enforce-mode apply.

### SSM (account + cell scope)

- **5 cell-scoped** under `/pavo/cells/${eks_cluster_name}/`: `vpc_id`,
  `private_subnet_ids`, `eks_cluster_name`, `eks_oidc_provider`, `eso_role_arn`.
- **2 account-scoped** under `/pavo/shared/`: `permission_boundary_arn`,
  `bootstrap_cell` (the single-cell sentinel described under *Resource scopes*;
  `prevent_destroy = true`).

### S3 — OpenTofu provider mirror (cell scope)

A private per-cell bucket `pavo-tf-mirror-<cluster>` (SSE-S3, Block Public Access
on) whose policy allows anonymous `GetObject` **only** from the cell's VPC endpoint
(`aws:SourceVpc`) and denies non-TLS. It serves the Terraform providers to the
cell's tf-executor over the S3 gateway endpoint. Bootstrap only **provisions** this
bucket; a companion spec change (`cliConfigFileOverride`, shipped separately) then
points every AWS cell's `network_mirror` at it with **no registry fallback**, so
terraform installs providers with **no public-registry egress** (a strict,
default-deny cell then needs no registry egress at all). **Once that wiring is in
place**, the bucket must be populated **before the cell's next terraform apply** or
that apply fails — OpenTofu's network mirror has no registry fallback.

Populate it with the self-contained helper (needs only this module plus a host
**with** registry access; the cell later consumes the bucket **without** any):

```bash
AWS_PROFILE=<account-profile> ./scripts/populate-provider-mirror.sh <eks-cluster-name> [region]
```

It mirrors the providers pinned in
[`provider-mirror/versions.tf`](provider-mirror/versions.tf) — a **generated** file
holding the AWS workload's `required_providers`, so the populate step needs no
access to Pavo's workload module. It builds a clean local tree and
`aws s3 sync --delete`s it to `s3://pavo-tf-mirror-<cluster>/providers`, so re-running
it both populates and refreshes the bucket. **Re-run it whenever a provider version
bumps** (i.e. whenever `provider-mirror/versions.tf` changes in a new module version).

> Maintainers: `provider-mirror/versions.tf` is regenerated by
> `scripts/render-mirror-providers.py` from `terraform-omnistrate-aws/providers.tf`
> in the source monorepo; CI (`check-policy-drift`) fails if it drifts. Do not hand-edit it.

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

### Two consumers: workload boundary *and* provisioning role

`policy-statements.json` is the single source of truth for **two** artifacts:

1. **Workload permission boundary** (`pavo-permission-boundary-shared`) — caps the
   Pavo app's IAM role. Rendered to `rendered-permission-boundary.json` via
   `scripts/render-policy.sh` and attached in `main.tf`.
2. **Terraform provisioning role** inline policy — the role Omnistrate assumes to
   run `terraform-omnistrate-aws`. Generated into the `policies.aws` block of
   `spec/spec-byoc.yaml` by `scripts/sync-policy-to-spec.py` (between the
   `AUTO-GENERATED` markers). CI's `drift` job fails if that block is stale.

Most statements apply to both. A few are **boundary-only** and are deliberately
withheld from the provisioning role — listed in `BOUNDARY_ONLY_SIDS` in
`scripts/sync-policy-to-spec.py`:

- `BedrockInvokeScopedToModels` (`bedrock:InvokeModel*`, scoped to the two Claude
  models) — runtime model invocation is the **app workload's** job. The
  provisioning role only sets up infrastructure and must never hold model-invoke
  rights (Coursera BYOC review finding #13). It stays in the boundary (which caps
  the workload role that *does* invoke) but is excluded from the provisioning
  role's policy.

The provisioning role also holds **no** Bedrock agreement / use-case actions, so
accepting the Claude model-use agreement is a one-time customer onboarding step,
not a Pavo permission (see `terraform-omnistrate-aws` → `bedrock_model_agreements`).

### Least-privilege is non-negotiable (and customer-audited)

Both artifacts are **scoped least-privilege**, always. The Terraform provisioning
role's inline policy is generated from `policy-statements.json` — **never a broad
managed policy like `AdministratorAccess`**. BYOC customers review and approve the
exact IAM their account grants Omnistrate's runner, so a broad grant is both a
real security regression and something a security-conscious customer *will* flag
in review. (A per-model role once existed as an out-of-CloudFormation
`AdministratorAccess` orphan — that is exactly the anti-pattern this guards
against. It masked gaps in the scoped policy until it was reconciled away.)

**Contract when adding an AWS resource to `terraform-omnistrate-aws`:** add its
scoped grants to `policy-statements.json` in the same change. Watch for
**resource-level authorization gotchas** — several *create* actions authorize
against *more than* the named resource, so a `pavo-*` / tag scope alone returns
`403`:

- `ec2:CreateSecurityGroup` authorizes against the **VPC** the group lives in
  (which carries no `managed_by` request tag), not just the security group — so
  it needs an unconditional grant on `vpc/*` alongside the tagged one.
- `elasticache:CreateReplicationGroup` authorizes against the **parameter group**
  (`default.redis7`), not just the `pavo-*` replication group.
- `ec2:CreateVpcEndpoint` and EFS mount targets authorize against the ENI +
  subnet + security group + VPC.
- `iam:CreateRole` for a fixed-name IRSA role (e.g. `keda-sqs-scaler`) won't match
  a `role/pavo-*` scope — scope the IAM statements to the actual role names.

When in doubt, run `scripts/simulate-policy.py` and check the AWS *Service
Authorization Reference* for which resource types an action authorizes against. A
failed apply under the scoped policy is the signal to **add the missing scoped
grant — not** to widen to a managed policy.

### Verifying boundary edits locally

After editing `policy-statements.json`, regenerate **both** derived artifacts and
run the simulation matrix.

**1. Re-render the boundary snapshot** (required — CI `rendered-boundary` fails on drift):

```bash
scripts/render-policy.sh pavo-bootstrap-aws/policy-statements.json \
  | jq . > pavo-bootstrap-aws/rendered-permission-boundary.json
```

**2. Re-sync the provisioning-role policy in the spec** (required — CI `drift` fails on drift):

```bash
python scripts/sync-policy-to-spec.py
```

**3. Simulate the matrix** (requires AWS creds + `boto3`):

```bash
pip install boto3
scripts/simulate-policy.py
```

The script uses `aws iam simulate-custom-policy` with the boundary fed through
`--permissions-boundary-policy-input-list` against an allow-all identity policy,
so the simulation reflects how the boundary actually behaves in production
(capping the identity policy, not acting as one). It tests ~20 cases including:

- RDS / ElastiCache / EFS read-only on `*` → allowed (shared `ReadOnlyDescribeList`)
- Provisioning mutations (`rds:*`, `elasticache:Modify*/Delete*`, `elasticfilesystem:*`,
  `iam:CreateRole`, EC2 network, `kms:CreateGrant`) → **denied** — they're
  `scope: runner` (see *Resource scopes*), excluded from the workload boundary
- `elasticache:Connect` on `pavo-*` → allowed (the one ElastiCache action a
  workload role actually uses)
- S3 / SQS / SNS on `pavo-*` → allowed; on non-`pavo-*` → denied

Any caller with `iam:SimulateCustomPolicy` permission works — the simulation is
account-agnostic.

### Reconciling an already-onboarded account (policy changes don't auto-propagate)

Editing `policy-statements.json` and releasing a new service version updates the
**source** only. An account onboarded *before* the change keeps running the
**old** custom-terraform role policy until its `AccountConfigSetup` CloudFormation
stack is reconciled — neither CI nor a published version pushes it.

> **Symptom:** `pavoInfra` fails `AccessDenied` on an action that **is** present
> in `policy-statements.json` — e.g. `ec2:DescribePrefixLists` (added when the
> VPC interface endpoints gained a prefix-list dependency). The role's live
> inline policy simply predates the change.

Reconcile each affected account by updating its `AccountConfigSetup` stack to
Omnistrate's latest onboarding template (the update just **modifies** the
`omnistrate-custom-terraform-role-for-sm-*` role policies — no replacement):

- **Portal:** Operations Center → BYOC Cloud Accounts → your account → open the
  provided CloudFormation link → **Update** `AccountConfigSetup` (Replace template
  → the `…/onboarding-cfv1/<org>/account-config-setup-template.yaml` URL → keep
  existing parameters → acknowledge IAM capabilities) → `UPDATE_COMPLETE`.
- **CLI** (reviewable — create a change set first, expect only `AWS::IAM::Role`
  `Modify`): `create-change-set`/`execute-change-set` against the same template
  URL, passing existing params as JSON (`{"ParameterKey":…,"UsePreviousValue":true}`
  — the `key=,UsePreviousValue=true` shorthand mis-parses), with
  `--capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND`.

Get `<org>` + the exact template URL from the account config's `cloudformation_url`
(`omnistrate-ctl instance describe <account-config-instance>`). **This is the same
stack update** that refreshes the EBS-CSI KMS permissions for customer-CMK volumes
(*Customer-managed-key EBS volumes* above) — one mechanism, several triggers.

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
point this module at a remote S3 backend.

### Quick setup (recommended): `scripts/create-state-backend.sh`

One state backend per AWS account (all cells in the account share it, keyed per
cell). Create it once per account with the helper — it's **idempotent** (adopts
an existing bucket/table and re-asserts hygiene), derives everything from the
caller's account ID, and prints the per-cell backend config:

```bash
AWS_PROFILE=<account-profile> ./scripts/create-state-backend.sh [region]   # region defaults to us-east-1
```

It creates (naming convention — do not hand-name):

| Resource | Name | Notes |
|---|---|---|
| S3 bucket | `pavo-tf-state-<account-id>` | versioned, AES256, public-access-blocked |
| DynamoDB lock table | `pavo-tf-state-locks` | `LockID` hash key, on-demand |
| State key (per cell) | `pavo-bootstrap-aws/<cluster>/terraform.tfstate` | |

Then commit a per-cell backend file and init against it (this is what the
committed `cells/<cluster>/backend.s3.tfbackend` files are — e.g.
`cells/hc-fmnwao4ct/`):

```hcl
# cells/<cluster>/backend.s3.tfbackend
bucket         = "pavo-tf-state-<account-id>"
key            = "pavo-bootstrap-aws/<cluster>/terraform.tfstate"
region         = "us-east-1"
dynamodb_table = "pavo-tf-state-locks"
encrypt        = true
```

```bash
# backend.tf (gitignored) — the empty block the partial config fills in:
#   terraform { backend "s3" {} }
terraform init -backend-config=cells/<cluster>/backend.s3.tfbackend
```

### Manual alternatives

If you're not using the helper (e.g. an existing corporate backend), create a
gitignored `backend.tf` yourself. Two patterns:

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
- **CLIs on PATH**: `aws` (≥ v2) and `terraform` are always required — `aws` is the
  exec-auth plugin the Kubernetes providers invoke. The `kubectl`/`helm` **binaries
  are NOT** needed for a Terraform apply (the Helm provider embeds the SDK; the
  `alekc/kubectl` provider is self-contained). They are used only by `--mode=direct`
  preflight and by the manual authorization-verification recipe.
- **The AWS provider is caller-owned.** This module declares no `provider "aws"`
  block; the caller/root supplies it (region, credentials, `assume_role`). See
  *Consuming as a child module (cross-account BYOC)*.
- **Cluster-admin RBAC on the EKS cluster** for the principal whose credentials the
  Kubernetes/Helm providers authenticate as. For direct apply that is your ambient
  principal; for a cross-account child-module run it is `k8s_get_token_role_arn`.
  If it doesn't have access, see *Case B* / the cross-account authorization recipe.

Run **`scripts/preflight.sh`** before `terraform init`. It **requires a mode**:

- `--mode=direct` — you apply this directory as a Terraform root with credentials
  already in the cell account. Verifies CLI presence, AWS creds, cluster
  reachability, and cluster-admin RBAC (hard gate `kubectl auth can-i '*' '*'`);
  refreshes your kubeconfig as a side-effect.
- `--mode=child` — you consume this repo as a Terraform child module (your root/CI
  owns the AWS provider and EKS authorization). Verifies only the
  environment-independent prerequisites (`aws` + `terraform` present); it does not
  and cannot validate your caller auth. See *Consuming as a child module* below.

```bash
export EKS_CLUSTER_NAME=hc-fmnwao4ct  # your cluster name
export AWS_REGION=us-east-1           # your region
./scripts/preflight.sh --mode=direct
```

## Variables

| Variable | Description |
|---|---|
| `vpc_id` | VPC ID provisioned by Omnistrate's CFN. |
| `private_subnet_ids` | Private subnet IDs (Omnistrate-tagged `kubernetes.io/role/internal-elb=1`). |
| `eks_cluster_name` | EKS cluster name (Omnistrate-provisioned). |
| `eks_oidc_provider` | EKS OIDC issuer URL **without** the `https://` prefix. |
| `runner_role_arn` | IAM role ARN of the Omnistrate Terraform runner principal that needs cluster-admin RBAC on this EKS cluster. MUST be the role ARN (`arn:aws:iam::<acct>:role/<RoleName>`), NOT an assumed-role session ARN. Its account must equal the injected AWS provider's account (the deterministic cell-account guard). |
| `k8s_get_token_role_arn` | *Optional; cross-account only.* IAM role the K8s/Helm exec-auth (`aws eks get-token --role-arn`) assumes when the run's **ambient** credentials are in a different account than the cell (e.g. a central Atlantis/CI account that assumes into the cell only at the provider level). Ambient creds must be able to assume it; it does **not** inherit provider-only options like `external_id`. Must differ from `runner_role_arn` and be in the provider's account. The module does **not** create its access entry (operator prerequisite). Empty = use ambient creds directly. |
| `image_policy_mode` | Sigstore ClusterImagePolicy enforcement mode for `ghcr.io/pavoai/**` images. `"enforce"` (default) rejects admission of images that fail verification; `"warn"` admits them and emits a Warning to admission callers (reserved for one-off signing-bake-in on a fresh image lineup). |
| `policy_controller_chart_version` | Helm chart version for `sigstore/policy-controller`. Default `0.10.6`. Bump deliberately and validate by setting `image_policy_mode = "warn"` for the upgrade apply — chart upgrades can change webhook config paths or CRD API versions. |
| `central_ci_project_id` | GCP project hosting Pavo's central Cloud Build that builds + signs all `ghcr.io/pavoai/*` images. Default `onboarding-455713`. The per-service signing SAs live here as `cloud-build-<service>@<central_ci_project_id>.iam.gserviceaccount.com`. Override only if you've forked the signing pipeline into a different GCP project. |
| `enable_eck` | Install the Elastic Cloud on Kubernetes (ECK) operator on this cell. **Default `false`.** Set `true` **only** on a cell that will host a self-hosted in-VPC Elasticsearch instance (`es_mode = self_hosted`). Cloud-Elasticsearch-only cells should leave it off to avoid an idle operator, CRDs, and validating webhook. When `true`, the cell publishes `/pavo/cells/<eks_cluster_name>/eck_ready=true`; the per-instance module reads that and **fails fast** if a `self_hosted` instance is created before ECK exists. |
| `eck_operator_chart_version` | Helm chart version for `elastic/eck-operator` (operator + CRDs move in lockstep). Default `3.4.0`. Only relevant when `enable_eck = true`. Confirm the ECK ↔ Elasticsearch support matrix before bumping (ECK 3.x supports the 8.x and 9.x stacks). |

Populate the infra identifiers (`vpc_id`, `private_subnet_ids`, `eks_cluster_name`,
`eks_oidc_provider`, `runner_role_arn`) from the Omnistrate console (instance
details panel) or via `aws eks describe-cluster --name <cluster-name>`. Region is
**not** a variable — it comes from the injected AWS provider. The remaining variables
default to safe values for a **new** cloud-Elasticsearch cell — override only if
you need to: flip Sigstore enforcement mode, pin a different
policy-controller/ECK chart version, repoint the signer project, or **enable ECK
on a cell that will run self-hosted in-VPC Elasticsearch (`enable_eck = true` —
off by default)**.

> **⚠️ Upgrade note — `enable_eck` default changed `true` → `false`.** Earlier
> versions of this module installed the ECK operator on **every** cell by
> default. If you already run a **self-hosted in-VPC Elasticsearch** instance
> (`es_mode = self_hosted`) on this cell, you **must** set
> `enable_eck = true` **before** applying this version — otherwise the apply
> removes the ECK operator and deletes `/pavo/cells/<cluster>/eck_ready`, and
> the per-instance module's `eck_ready` guard will then fail any self-hosted-ES
> reconcile. Cloud-Elasticsearch-only cells need no action.

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
error message that shows how to convert a session ARN to the role ARN.

## Apply

```bash
./scripts/preflight.sh --mode=direct
# Configure backend.tf first (see "Configuring Terraform state" above), then:
terraform init
terraform plan
terraform apply
```

Capture outputs (especially `eso_role_arn` — needed for the CMK key policy):

```bash
terraform output
```

Then **populate the OpenTofu provider mirror** the apply just created, before
Pavo's workload Terraform runs against this cell (see *S3 — OpenTofu provider
mirror* for why this is mandatory and how to refresh it):

```bash
# Same account/region as the apply; <eks-cluster-name> is the eks_cluster_name var.
AWS_PROFILE=<account-profile> ./scripts/populate-provider-mirror.sh <eks-cluster-name>
```

## Consuming as a child module (cross-account BYOC)

Customers pin the mirror (`git::https://github.com/pavoai/pavo-bootstrap-aws.git?ref=v0.5.0`)
and consume this repo as a child module. **The AWS provider is caller-owned** — this
module declares no `provider "aws"` block, so it inherits the provider you configure
in your root (region, credentials, `assume_role`). Region is read back from that
provider, so it is never passed as a variable.

**Provider wiring.** If your root's cell-account provider is the **default** `aws`
provider, inheritance is automatic (pass nothing). If it is **aliased**, pass it
explicitly (confirmed sufficient by `tests/consumer-root` — `time`/`random` resolve
implicitly, so only `aws` needs mapping):

```hcl
module "pavo_bootstrap" {
  source = "git::https://github.com/pavoai/pavo-bootstrap-aws.git?ref=v0.5.0"

  providers = { aws = aws.cell }   # only if your aws provider is aliased

  vpc_id             = var.vpc_id
  private_subnet_ids = var.private_subnet_ids
  eks_cluster_name   = var.eks_cluster_name
  eks_oidc_provider  = var.eks_oidc_provider
  runner_role_arn    = var.runner_role_arn
  # k8s_get_token_role_arn = "..."  # cross-account only, see below
}
```

**Cross-account exec-auth.** The Kubernetes/Helm providers authenticate with
`aws eks get-token`, a subprocess that reads the run's **ambient** AWS credentials,
NOT the Terraform provider's `assume_role`. If your run executes in a *different*
account than the cell (e.g. a central Atlantis account that assumes into the cell
only at the provider level), set `k8s_get_token_role_arn` to the cell-account role
your provider assumes; the token call then assumes it too. Your ambient credentials
must be able to assume that role (it does **not** inherit provider-only trust options
like `external_id`).

### Authorization: create + verify (before apply)

`k8s_get_token_role_arn` (or, in the ambient/direct case, your run's principal) must
have an EKS access entry + `AmazonEKSClusterAdminPolicy`. The module does **not**
create it — it is a one-time prerequisite **per role/cluster pair**. Run the two
creation calls under a **cell-account** identity authorized to manage EKS access
entries (however you obtain those credentials):

```bash
ROLE_ARN="arn:aws:iam::<cell-acct>:role/<your-exec-role>"; CLUSTER="<eks_cluster_name>"; REGION="<region>"
aws eks create-access-entry    --cluster-name "$CLUSTER" --principal-arn "$ROLE_ARN" --type STANDARD --region "$REGION"
aws eks associate-access-policy --cluster-name "$CLUSTER" --principal-arn "$ROLE_ARN" \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy --access-scope type=cluster --region "$REGION"
```

Then verify the **exact** exec-auth path Terraform will use, with Atlantis-equivalent
ambient credentials and a throwaway kubeconfig (`--assume-role-arn` does the
cross-account `DescribeCluster`; `--role-arn` is the K8s identity). The AWS provider
being able to assume the role does **not** prove this subprocess can:

```bash
KCFG="$(mktemp)"
aws eks get-token --cluster-name "$CLUSTER" --region "$REGION" --role-arn "$ROLE_ARN" --output json >/dev/null
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" \
  --assume-role-arn "$ROLE_ARN" --role-arn "$ROLE_ARN" --kubeconfig "$KCFG" --alias pavo-bootstrap-preflight
KUBECONFIG="$KCFG" kubectl auth can-i '*' '*' --all-namespaces   # expect: yes
rm -f "$KCFG"
```

> **Lifecycle.** Keep this access entry for the entire lifetime of the bootstrap
> state; remove it only after the final `terraform destroy`. To rotate the role:
> create B's entry + policy, verify B, switch `k8s_get_token_role_arn` A→B, apply,
> then remove A. Never revoke the active entry first.

### Migrating an existing consumer to v0.5.0

1. Bump `?ref` to `v0.5.0`.
2. **Remove** `aws_region = ...` from the `module` block (the input no longer exists).
3. If your cell provider is aliased, add `providers = { aws = aws.<alias> }`.
4. Add `k8s_get_token_role_arn` **only if** your run's ambient credentials are in a
   different account than the cell.
5. Ensure the exec principal has the access entry above (one-time prerequisite).

## Brand-new cell: the workload-node / `eck_ready` ordering

> The *other* brand-new-account gotcha — `pavoInfra` failing `AccessDenied` on a
> policy action that's already in `policy-statements.json` — is a stale onboarded
> role; see *Reconciling an already-onboarded account*.

A freshly-provisioned Omnistrate cell has **only the system/critical node pool**
(nodes tainted `CriticalAddonsOnly=true:NoSchedule`). The per-resource **tenant
workload node pools are created lazily by Omnistrate when an *instance* deploys**
— so on a cell where no instance has deployed yet, there are no untainted nodes.

Without care this deadlocks a self-hosted-ES bring-up:

> `es_mode=self_hosted` instance needs `eck_ready=true` → the cell publishes that
> **only after the ECK operator is actually running** (`main.tf`, `depends_on =
> [helm_release.eck_operator]`) → the operator needs a node → the only nodes are
> tainted → the operator can't schedule → the instance never deploys → no
> workload nodes are ever created.

**This module breaks the cycle by design:** the bootstrap operators (ESO, ECK,
policy-controller, reloader) are cluster infrastructure — the same category as
CoreDNS, the cluster-autoscaler, and the CSI drivers, which all tolerate
`CriticalAddonsOnly`. So they carry the same toleration
(`local.critical_addon_toleration`) and **run on the system pool**. That lets ECK
come up on a bare cell → `eck_ready=true` → the self-hosted instance deploys →
its **app + ES data pods** (which deliberately do *not* have the toleration)
trigger the workload-node scale-up and run there. No `es_mode` juggling, and
`eck_ready` stays truthful.

If you ever see the bootstrap helm releases stuck (`terraform apply` hanging on
`helm_release.* Still creating…`), check for `Pending` operator pods with
`FailedScheduling … untolerated taint(s)` — that means a chart's toleration value
path is wrong for its version (they differ: ESO sets `tolerations` +
`webhook.tolerations` + `certController.tolerations`; reloader uses
`reloader.deployment.tolerations`; policy-controller uses `commonTolerations`;
eck-operator uses top-level `tolerations`). Confirm with `helm show values`.

### Where the tenant workload nodes come from

Omnistrate provisions a **scale-from-zero node group per (resource × instance
type)** from each resource's `compute.instanceTypes`; the cluster-autoscaler
scales them on demand. Inspect/manage with
`omctl deployment-cell list-nodepools|describe-nodepool|scale-up-nodepool|
scale-down-nodepool|delete-nodepool --id <cell>` (there is **no** `create` — pools
are platform-created). For **CUSTOM_TENANCY** (Helm) plans like ours they're
created when the plan's **resources reconcile**, not up front.

So a **truly fresh cell** (no instance ever deployed) starts with **zero workload
pools**, only the tainted system pool. Fine for the bootstrap operators (they
tolerate the taint, above), but it would **deadlock a self-hosted-ES first
deploy**: `pavoInfra`'s own ES/init-db pods need a workload node, yet the pools
that would supply one are created by app resources that only deploy *after*
`pavoInfra` succeeds. A cell that has deployed before (e.g. `awstest`) already has
pools from prior deploys and never hits this.

**Resolved by the `pavo-compute-anchor` resource.** It declares `compute` with
**no `dependsOn`**, so Omnistrate deploys it first and its pool supplies the
initial untainted workload node before `pavoInfra` runs; `pavoInfra` and the app
helms all depend on it. See
[`charts/pavo-compute-anchor/README.md`](../charts/pavo-compute-anchor/README.md).

> **Interim (per-helm compute).** The app helms (ingress-nginx, api-gateway,
> intern, frontend, onboarding-copy, tribal-knowledge, capability-proxy) currently
> each declare their **own** compute pool rather than sharing the anchor pool, to
> work around an Omnistrate render-metadata race where a compute-less helm's
> `RenderClusterParameters` runs before `pavoInfra`'s outputs are queryable and
> fails. The anchor still exists to unblock `pavoInfra`'s own ES/init-db pods.
> Once Omnistrate ships the fix, drop the per-helm `compute` blocks and the app
> pods float back onto the single shared anchor pool (the lean target design).
If a fresh deploy still fails with tenant pods `Pending` /
`NotTriggerScaleUp: untolerated taint(s)` and `list-nodepools` shows none, the
anchor didn't come up (check its resource first).

## Case B: bootstrapping without K8s admin

If `scripts/preflight.sh` fails on the `kubectl auth can-i '*' '*' --all-namespaces`
hard gate, the principal running `terraform apply` lacks cluster-admin RBAC on
the EKS cluster. Bootstrap can't create the EKS access entry for the Omnistrate
runner (that's exactly what it's trying to do) without already having access.

**Remediation** — create an access entry for your principal manually, then re-run
bootstrap. The bootstrap apply also adds a separate access entry for
`var.runner_role_arn` (the Omnistrate runner). Your own entry stays out of
Terraform state, but it is the identity Terraform authenticates as for every
Kubernetes/Helm operation on this bootstrap state, so **keep it** (see the
lifecycle note after the apply below).

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
```

> **Do NOT delete this access entry after apply.** Your principal is the identity
> the Kubernetes/Helm providers authenticate as for **every** operation against
> this bootstrap state — plan, refresh, update, and destroy. Keep it for the
> entire lifetime of this bootstrap state; remove it only **after** the final
> `terraform destroy` has torn down the module's Kubernetes/Helm resources.
> Revoking it earlier bricks Terraform's ability to clean up.

### Runner `Unauthorized` on the K8s API after a role recreate

If the Omnistrate **runner** role is deleted and recreated with the same name
(e.g. the scoped-policy reconcile that replaces an orphan `AdministratorAccess`
role), its existing EKS access entry goes **stale** — EKS binds the entry to the
role's unique ID, not just the ARN, so `describe-access-entry` still shows the
right ARN but `pavoInfra`'s K8s reads fail with
`Error: Unauthorized … the server has asked for the client to provide credentials`.
**Re-seat** the runner's entry (the `create-access-entry` + `associate-access-policy`
pair above, using `var.runner_role_arn` instead of your own): `delete-access-entry`
→ `create-access-entry` → `associate-access-policy` (`AmazonEKSClusterAdminPolicy`).

## Setting up the CMK (separate from bootstrap; before workload deploys)

One CMK per cell encrypts **everything** — RDS storage, the RDS-managed master
secret, and (on self-hosted cells) the ES / in-VPC-observability EBS volumes.
Its ARN is the instance `cell_kms_key_arn` apiParameter. There are two cases:

### Quick setup: same-account key (dev/test, e.g. `awstest`) — `scripts/create-cmk.sh`

When the workload + ESO roles live in the **same account** as the key, a plain
key with the **default policy (root → `kms:*`)** is sufficient: those roles get
key use from their own IAM policies, so **no key-policy statements are needed**.
Create it with the idempotent helper (adopts an existing `alias/pavo-<name>`):

```bash
AWS_PROFILE=<account-profile> ./scripts/create-cmk.sh <cell-or-customer-name> [region]
# prints the key ARN + alias ARN — use either as cell_kms_key_arn
```

The script tags the key `omnistrate.com/customer-managed-kms=true` for you (item
1 of the *CMK EBS volumes* section above), so the EBS CSI driver can encrypt the
self-hosted-ES / observability volumes. It applies the tag on both paths, so
re-running it also back-tags a key that pre-dates this behaviour. You still need
step 2 there (reconcile the account's `AccountConfigSetup` stack) so the driver
role actually carries the KMS actions.

That's the whole CMK step for a same-account cell. **Skip the locked-down flow
below** — it applies only to a customer key that does not delegate to root.

### Explicit key policy (customer-governed keys)

Use this when key access must be granted by the **key policy itself** — naming
the workload + ESO roles — rather than left to account-root + IAM (e.g. an org
that gates KMS at the key policy, or a key whose principals you want pinned
regardless of IAM). The 5-statement policy below keeps `EnableRootPermissions`
(root → `kms:*`) so the account never loses the recovery path, and **adds** the
explicit workload/ESO grants on top:

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

4. Paste the CMK ARN into the Omnistrate UI under `cell_kms_key_arn`. The
   instance won't provision until set (`required: true`).

5. **Note on the same CMK serving dual duty**: this single CMK encrypts both
   RDS storage *and* the master-password Secrets Manager secret. Statements
   2-4 grant the workload role what RDS needs to provision both. Statement 5
   grants the ESO role what it needs to decrypt the secret at runtime.

6. The `cell_kms_key_arn` value can be either a **key ARN** (`arn:aws:kms:<region>:<account>:key/<uuid>`)
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
single-cell sentinel) and **cell-scoped** (the ESO IRSA role, the
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
2. *cell bootstrap* — the ESO IRSA role, Helm releases, EKS access
   entry, cluster-scoped K8s resources, and `/pavo/cells/<eks_cluster_name>/*`
   SSM parameters; applied **once per deployment cell**.

## In-VPC observability (self-hosted Grafana / Prometheus / OTel)

For customers whose telemetry must not leave the VPC (`grafana_mode = self_hosted`,
e.g. BCBSNC). Opt-in per cell — a cloud-observability cell must not run an unused
monitoring stack. Everything installs from this module's single `terraform apply`
into the `pavo-observability` namespace: Prometheus (in-VPC TSDB), Grafana
(internal `pavo-nginx` ingress, dashboards-as-code), Postgres (Grafana backend),
and the `pavo-otel-collector`. All PVCs bind the customer's one CMK. **Zero
external egress for telemetry**: metrics, dashboards, and scraping stay entirely
in-cluster. The one deliberate exception is alerting: if `pavo_app_alerts_enabled`
or `customer_alert_webhook_url` is set, Alertmanager posts alerts out to those
endpoints (the customer webhook is the customer's own receiver, often in-VPC). With
both unset — the default — nothing leaves the cluster.

### Flags — who sets what

| Variable | Who sets it | Effect |
|---|---|---|
| `enable_observability` | **Pavo operator**, per cell, at bootstrap | Installs the whole stack. Default `false`. Set `true` on any cell that will host a `grafana_mode=self_hosted` instance. |
| `observability_grafana_host` | Pavo operator | Public hostname Grafana serves at; ingress host becomes `grafana.<this>`. Required when `enable_observability = true`. |
| `cell_kms_key_arn` | **Customer** (the one CMK) | Encrypts the observability PVCs (`gp3-cmk`). Same key the instance module uses for RDS/ES/Zitadel — one key for everything. |
| `pavo_app_alerts_enabled` | Pavo operator | Also routes Prometheus alerts to Pavo via the in-VPC sanitizer (8-key metadata only). Default `false` = customer-webhook leg only. Requires a real signed `sanitizer_image` — the sanitizer stays off until that image is built (the cell ClusterImagePolicy admits only signed digests). |
| `customer_alert_webhook_url` | Customer (optional) | Alertmanager posts raw alerts here (via a Secret, never a break-glass-readable ConfigMap). Empty = no customer leg. |

The matching per-instance flag is `grafana_mode` (`cloud` default | `self_hosted`),
set on the Omnistrate instance. It only routes telemetry in-VPC when this cell was
bootstrapped with `enable_observability = true`.

### How metrics flow

Every Pavo app service exposes a `prometheus_client` `/metrics` endpoint, so the
in-VPC Prometheus **scrapes** them via the standard `prometheus.io/scrape` pod
annotations (the app charts set these). The OTel collector + `remote_write`
receiver are also wired for the eventual move to 100% OTel push, but scraping is
the near-term path. Infra metrics come from in-VPC kube-state-metrics +
node-exporter. No metric ever leaves the VPC.

### Applying

Set the flags in your `terraform.tfvars` (or `-var`) and run the normal
`terraform apply` (see **Apply** above) — the stack is part of this module, not a
separate step:

```hcl
enable_observability       = true
observability_grafana_host = "cell.example.com"   # Grafana at grafana.cell.example.com
cell_kms_key_arn           = "arn:aws:kms:us-east-1:<acct>:key/<uuid>"
# pavo_app_alerts_enabled  = true   # only once a signed sanitizer image exists
```

### Dashboards

Dashboards are **as-code** — ConfigMaps labelled `grafana_dashboard`, loaded by the
Grafana sidecar (`observability/manifests/`). They evolve by **bumping this
module's version** (edit the JSON, tag, customers pick it up on their next apply).
For an urgent fix without a release, apply the ConfigMap directly:
`kubectl apply -f observability/manifests/<dashboard>.yaml -n pavo-observability`
(and back-port the edit into the module so the next apply doesn't revert it).

## Ownership rules

Resources are scoped at one of four levels. The level determines which
module owns the resource, who applies it, and where state lives.

| Scope | Module | Applier | State backend | Examples |
|---|---|---|---|---|
| **Account** | `pavo-bootstrap-aws/` | Customer (AWS creds) | Customer-local | IAM permission boundaries, `/pavo/shared/*` SSM |
| **Cell** (one EKS cluster) | `pavo-bootstrap-aws/` | Customer (AWS creds) | Customer-local | IngressClass, ClusterIssuer, ESO/Reloader helm releases, EKS access entry, `/pavo/cells/<cluster>/*` SSM |
| **Customer** (one `customer_name`) | `pavo-customer-bootstrap/` | Pavo ops (Zitadel PAT) | GCS `gs://pavo-terraform-state`, prefix `customer-bootstrap/<customer>` | Zitadel org, project, OIDC app, IdPs, login policy |
| **Instance** (one Pavo deployment) | `terraform-omnistrate-aws/` | Omnistrate runner | Omnistrate-managed | RDS, ElastiCache, S3, SNS/SQS, EFS, workload IAM role, app namespace, app secrets, Elastic Cloud deployment |

### Picking the right module for a new resource

1. If deleting one Pavo instance shouldn't delete it → not `terraform-omnistrate-aws/`.
2. If its `name` doesn't include `var.instance_id` → probably not `terraform-omnistrate-aws/`.
3. If it lives in Pavo's identity tenant (Zitadel) → `pavo-customer-bootstrap/`.
4. If it's cluster-scoped K8s or per-cell IAM → `pavo-bootstrap-aws/`.
5. Otherwise (per-instance app resource) → `terraform-omnistrate-aws/`.
6. If it's a self-hostable cell substrate the customer opts into (ECK, in-VPC observability) → `pavo-bootstrap-aws/` behind an `enable_*` flag — NEVER an Omnistrate cell-amenity. See `pavo-bootstrap-aws/README.md` → *Cell self-hosting flags*.

### Hard rules

- No cluster-scoped K8s resource may live in `terraform-omnistrate-aws/`, even with `apply_only = true` as a mitigation.
- `pavo-customer-bootstrap/` MUST NOT declare `instance_id` as a variable (structural enforcement of the customer-hostname invariant).
- A second cell in the same AWS account is currently guarded by an SSM sentinel — see `pavo-bootstrap-aws/README.md`.
- No fifth "place": Omnistrate cell-amenities are not a home for Pavo infra. Cell-scoped infra a customer should apply/audit in their VPC → `pavo-bootstrap-aws/` (customer-applied), never an amenity (Pavo-applied, no audit trail). The observability stack shipped as an amenity by mistake — now migrated to `enable_observability` in `pavo-bootstrap-aws/` (the old `observability/` amenity module was removed).

## Cell self-hosting flags (`enable_eck`, `enable_observability`)

Each in-VPC substrate a strict/residency customer opts into is gated by an opt-in, **default-`false`** flag:

| Flag | Installs (cell-scoped) | Instance routing flag | Cell→instance gate |
|---|---|---|---|
| `enable_eck` | ECK operator (self-hosted ES) | `es_mode` | `/pavo/cells/<cluster>/eck_ready` SSM + **fail-fast** — a `self_hosted` ES CR *hard-fails* without ECK |
| `enable_observability` *(planned — still an amenity, migrating here)* | in-VPC Grafana/Prometheus + OTel collector | `grafana_mode` | none — a misrouted cell just *drops* telemetry (soft), so no gate is warranted |

- **Default `false`, opt-in per cell** — a cloud cell must not run an idle operator / unused monitoring stack.
- **Set `true` in `cells/<cluster>/<cluster>.tfvars`** by whoever provisions the cell: the **customer** (mirrored module, their admin, they audit it) or **Pavo** at onboarding. Recorded in tfvars so it can't silently regress; never automatic, never a runtime toggle. Self-hosted customer → both `true`, paired with the matching instance flag.
- **Cell-level, not per-instance:** the substrate is cluster-scoped (one operator / one Grafana per cell), so a per-instance flag can't create it. `es_mode`/`grafana_mode` only **route**. Only ES adds a readiness gate (`eck_ready` fail-fast) because its failure is hard; observability's is soft, so `enable_observability` + `grafana_mode` are simply set together.
