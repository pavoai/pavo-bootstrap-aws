# pavo-bootstrap-aws — runbooks & reference

Detailed reference and operational runbooks, split out of the main
[README](README.md) to keep it lean. The README covers the quick-start:
versioning, Terraform state, variables, apply, and consuming this repo as a child
module. This file holds everything you reach for less often.

## Contents

- [Full resource inventory](#what-it-creates-full-inventory)
- [S3 / DynamoDB gateway endpoints (adaptive coverage)](#s3--dynamodb-gateway-endpoints-adaptive-coverage)
- [Permission boundary scoping & verification](#permission-boundary-scoping--verification)
- [Terraform state: manual backend alternatives](#terraform-state-manual-backend-alternatives)
- [Brand-new cell: workload-node / `eck_ready` ordering](#brand-new-cell-the-workload-node--eck_ready-ordering)
- [Case B: bootstrapping without K8s admin](#case-b-bootstrapping-without-k8s-admin)
- [Setting up the CMK](#setting-up-the-cmk-separate-from-bootstrap-before-workload-deploys)
- [Rotation runbook for the RDS CMK](#rotation-runbook-for-the-rds-cmk)
- [Scoping notes](#scoping-notes)
- [In-VPC observability](#in-vpc-observability-self-hosted-grafana--prometheus--otel)

---

## What it creates (full inventory)

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
   ```text
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
   account root, the key policy itself must name the **Omnistrate-managed EBS-CSI
   driver role**. Use the `AllowEBSCSICryptographicUse` and
   `AllowEBSCSIGrantManagement` statements from
   [*Explicit key policy (customer-governed keys)*](#explicit-key-policy-customer-governed-keys)
   below — they are already part of that policy, so there is nothing extra to
   author here. If the key policy delegates to root (the default), the IAM side
   alone is enough and no key-policy edit is needed. The driver runs as the
   Omnistrate-owned role (not a Pavo role) — get its exact ARN from the cell:
   ```bash
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
  `bootstrap_cell` (the single-cell sentinel described under the README's *What it creates* section;
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


---

## S3 / DynamoDB gateway endpoints (adaptive coverage)

The cell's node/pod route tables (all non-main route tables) need an S3/DynamoDB
gateway-endpoint route so pod→S3/DynamoDB traffic stays private in-VPC. Omnistrate
provisions its own gateway endpoints; historically only on the main route table, so
this module covered every non-main route table. That assumption broke: on some cells
Omnistrate's endpoints already span non-main route tables, and a route table may
carry only **one** gateway-endpoint route per service, so associating ours with an
already-covered table fails the apply with `RouteAlreadyExists`.

Since v0.6.1 the endpoints are **adaptive**: `missing = required − Omnistrate's
route_table_ids`, per service. We create an endpoint only for the route tables
Omnistrate does not cover; when Omnistrate already covers everything (common on fresh
cells), we create **none**. We read Omnistrate's endpoint directly, so our own endpoint
never enters the calculation.

Discovery is a **live describe** of Omnistrate's endpoint per service
(`data.aws_vpc_endpoint`, `state = "available"`, filtered to this cell by
`tag:omnistrate.com/host-cluster-id` + `tag:omnistrate.com/managed-by` and
`vpc-endpoint-type = Gateway`). It uses `ec2:DescribeVpcEndpoints` (already granted to
the runner) and runs as the provider identity, so it is cross-account correct. A live
describe was chosen over the Resource Groups Tagging API deliberately: the Tagging API
is an eventually-consistent index that can return a *deleted* endpoint id, and a stale
id anywhere in the account would fail the plan on a per-id lookup. The live describe
returns only what exists now, scoped to this cell.

**Contract.** `data.aws_vpc_endpoint` resolves **exactly one** endpoint. This encodes
the invariant that Omnistrate supplies exactly one available S3 and one available
DynamoDB gateway endpoint per cell. Zero or two matches fails planning **before any
mutation** (a clear, safe failure). During an Omnistrate endpoint replacement there may
momentarily be no `available` match; the plan fails then too, which is correct — the
external coverage is not stable and Pavo should not race in to rewrite routing. Inspect
what the filter resolves to:

```bash
aws ec2 describe-vpc-endpoints --filters \
  Name=vpc-id,Values=<vpc> Name=vpc-endpoint-type,Values=Gateway \
  Name=service-name,Values=com.amazonaws.<region>.s3 \
  Name=vpc-endpoint-state,Values=available \
  "Name=tag:omnistrate.com/host-cluster-id,Values=<cluster>" \
  "Name=tag:omnistrate.com/managed-by,Values=omnistrate" \
  --query 'VpcEndpoints[].{id:VpcEndpointId,rts:RouteTableIds}'
```


---

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

**CI runs this too, as the `simulate` job in `check-policy-drift`.** It was not
always so: the script sat in that workflow's `paths:` trigger from the day it
landed with no job executing it, so CI advertised the check and ran none of its
assertions. Two runner-only ElastiCache cases sat failing on `main` unnoticed
until someone ran it by hand.

The job federates to AWS via OIDC using the role in repo variable
`POLICY_SIMULATE_ROLE_ARN` (`pavo-terraform-templates-policy-simulate` in
`453542520145`), whose only permission is `iam:SimulateCustomPolicy` and which
carries a permissions boundary capping it there. `simulate-custom-policy` takes
the policy document as **input** and reads no account state, so the role can see
nothing and change nothing, and the verdict is account-independent. Like
`release-bootstrap-dev`, the job is **skipped rather than failed** if that
variable is unset, and never runs on fork PRs.

Running it locally is still worth doing before pushing — the CI job is a
backstop, not a substitute for checking your own change.

The script uses `aws iam simulate-custom-policy` with the boundary fed through
`--permissions-boundary-policy-input-list` against an allow-all identity policy,
so the simulation reflects how the boundary actually behaves in production
(capping the identity policy, not acting as one). It tests ~20 cases including:

- RDS / ElastiCache / EFS read-only on `*` → allowed (shared `ReadOnlyDescribeList`)
- Provisioning mutations (`rds:*`, `elasticache:Modify*/Delete*`, `elasticfilesystem:*`,
  `iam:CreateRole`, EC2 network, `kms:CreateGrant`) → **denied** — they're
  `scope: runner` (see the README's *What it creates* section), excluded from the workload boundary
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

#### The stack name is per-account — do not hardcode it

It is commonly `AccountConfigSetup`, but customers prefix it (a real one is
`PavoPOC-AccountConfigSetup`). Any command that hardcodes the bare name fails
for them. Discover it:

```bash
aws cloudformation list-stacks --region <REGION> \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE \
                        UPDATE_ROLLBACK_FAILED ROLLBACK_COMPLETE \
  --query "StackSummaries[?contains(StackName,'AccountConfigSetup')].[StackName,StackStatus]" \
  --output text
```

The status filter matters: `list-stacks` returns deleted stacks for 90 days, so
an unfiltered name-only query can hand you a `DELETE_COMPLETE` stack from a
previous onboarding attempt.

#### Never re-run with a *different* `CreateLoadBalancerPolicy` than Phase 1 used

This is why "keep existing parameters" above matters, and it is the single most
common way this update fails. `CreateLoadBalancerPolicy` defaults to `true` and
gates a `ManagedPolicyName: AWSLoadBalancerControllerIAMPolicy` resource. An
account onboarded with `false` (because it manages that policy separately)
already has a policy of that name, so re-running with the default produces:

```text
A policy called AWSLoadBalancerControllerIAMPolicy already exists.
Duplicate names are not allowed. (Service: Iam, Status Code: 409)
```

and CloudFormation rolls the whole update back. **Whatever value Phase 1 used,
every subsequent update must use the same value.** Passing
`UsePreviousValue: true` for every parameter, as above, does this automatically;
hand-written `ParameterValue=` lists are what get it wrong.

##### Break-glass: recovering a rolled-back stack

Only if the stack is already stuck in `UPDATE_ROLLBACK_FAILED`. This leaves
CloudFormation's model out of sync with reality, so it is a recovery path, not
part of the normal procedure.

First confirm the LB policy is genuinely the blocker rather than assuming it:

```bash
aws cloudformation describe-stack-events --stack-name <STACK> --region <REGION> \
  --query "StackEvents[?ResourceStatus=='CREATE_FAILED'].[LogicalResourceId,ResourceStatusReason]" \
  --output text | head
```

If, and only if, `AWSLoadBalancerControllerIAMPolicy` is the failing resource:

```bash
aws cloudformation continue-update-rollback --stack-name <STACK> --region <REGION> \
  --resources-to-skip AWSLoadBalancerControllerIAMPolicy
```

Then re-run the update **with `CreateLoadBalancerPolicy` set to the value Phase 1
used** (normally `false` for any account that hit this), or with
`UsePreviousValue: true`.

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

---

## Terraform state: manual backend alternatives

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

---

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
regardless of IAM). The 8-statement policy below keeps `EnableRootPermissions`
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

2. Create a **dedicated** KMS key for this cell, then **tag it**:

   ```bash
   aws kms tag-resource --region <REGION> --key-id <KEY_ID> \
     --tags TagKey=omnistrate.com/customer-managed-kms,TagValue=true
   ```

   Prefer a dedicated key over an existing shared enterprise key. This flow
   grants the EBS CSI driver role cryptographic use of whatever key you name,
   so a dedicated key keeps that blast radius small.

   **The tag is not optional.** It is easy to miss because `scripts/create-cmk.sh`
   applies it for you on the quick-setup path, while this hand-created path does
   not. Omnistrate's EBS CSI driver role scopes `kms:CreateGrant` to keys
   carrying this tag. Without it the driver cannot encrypt the self-hosted
   Elasticsearch or in-VPC observability volumes: each volume is created and
   then deleted seconds later, and the PVC stays `Pending` forever **with no
   error surfaced in Terraform** — the apply simply times out on a Helm wait.

   Verify before continuing:

   ```bash
   aws kms list-resource-tags --region <REGION> --key-id <KEY_ID> \
     --query "Tags[?TagKey=='omnistrate.com/customer-managed-kms' && TagValue=='true']"
   ```

3. Attach this **8-statement key policy** (with `<CUSTOMER_ACCOUNT_ID>`,
   `<OMNISTRATE_WORKLOAD_ROLE_ARN>`, `<ESO_ROLE_ARN_FROM_BOOTSTRAP>`,
   `<EBS_CSI_DRIVER_ROLE_ARN>`, and `<REGION>` substituted):

   ```json
   {
     "Version": "2012-10-17",
     "Id": "pavo-cell-cmk",
     "Statement": [
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
     },
     {
       "Sid": "AllowEBSCSICryptographicUseViaEC2",
       "Effect": "Allow",
       "Principal": { "AWS": "<EBS_CSI_DRIVER_ROLE_ARN>" },
       "Action": [
         "kms:Encrypt",
         "kms:Decrypt",
         "kms:ReEncrypt*",
         "kms:GenerateDataKey*"
       ],
       "Resource": "*",
       "Condition": {
         "StringEquals": {
           "kms:ViaService": "ec2.<REGION>.amazonaws.com"
         }
       }
     },
     {
       "Sid": "AllowEBSCSIDescribeKey",
       "Effect": "Allow",
       "Principal": { "AWS": "<EBS_CSI_DRIVER_ROLE_ARN>" },
       "Action": "kms:DescribeKey",
       "Resource": "*"
     },
     {
       "Sid": "AllowEBSCSIGrantManagement",
       "Effect": "Allow",
       "Principal": { "AWS": "<EBS_CSI_DRIVER_ROLE_ARN>" },
       "Action": ["kms:CreateGrant", "kms:ListGrants", "kms:RevokeGrant"],
       "Resource": "*",
       "Condition": {
         "Bool": { "kms:GrantIsForAWSResource": "true" }
       }
     }
     ]
   }
   ```

   The last three statements are what let the EBS CSI driver encrypt the
   self-hosted Elasticsearch and in-VPC observability volumes with this key.
   They follow AWS's documented shape for customer-managed keys with the EBS
   CSI driver: cryptographic operations and grant management are separate
   statements, and grant management is constrained with
   `kms:GrantIsForAWSResource` so the driver can only hand grants to AWS
   services, never to arbitrary principals. This mirrors
   `AllowOmnistrateWorkloadGrants` above, which already uses that condition.

   The three-way split is deliberate:

   - **Cryptographic actions carry `kms:ViaService = ec2.<REGION>.amazonaws.com`.**
     A key-policy statement naming a principal directly is sufficient on its own
     for a same-account principal, so without this condition it would grant
     broader use of the key than the driver role's own IAM policy allows. This
     keeps the key policy consistent with the ViaService scoping described under
     *Customer-managed-key EBS volumes* above.
   - **`kms:DescribeKey` is separate and unconditioned**, because the driver
     calls it directly rather than through EC2, so a ViaService condition would
     deny it.
   - **Grant management must NOT carry `kms:ViaService`.** The driver calls
     `kms:CreateGrant` directly; adding the condition would deny grant creation
     and volumes would never attach. `kms:GrantIsForAWSResource` is the correct
     constraint there.

   Discover `<EBS_CSI_DRIVER_ROLE_ARN>` from the cluster:

   ```bash
   kubectl -n kube-system get sa ebs-csi-controller-sa \
     -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'
   # -> arn:aws:iam::<acct>:role/omnistrate-ebs-csi-driver-<cell>-<hash>
   ```

   Omit both statements only if this key will never back an encrypted EBS
   volume, i.e. the cell runs neither self-hosted Elasticsearch nor in-VPC
   observability.

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
cell's network metadata) — see the README's *What it creates* section.

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
`terraform apply` (see the README's *Apply* section) — the stack is part of this module, not a
separate step:

```hcl
enable_observability       = true
observability_grafana_host = "cell.example.com"   # Grafana at grafana.cell.example.com
cell_kms_key_arn           = "arn:aws:kms:us-east-1:<acct>:key/<uuid>"
# pavo_app_alerts_enabled  = true   # only once a signed sanitizer image exists
```

**Set it once, on a brand-new cell, and apply once.** There is no two-phase dance.

This is worth stating explicitly because the opposite used to be true. On a
brand-new cell the customer applies this module BEFORE the cell has converged:
the only nodes present carry Omnistrate's `CriticalAddonsOnly=true:NoSchedule`
taint. Postgres is worse still: `gp3-cmk` uses `WaitForFirstConsumer`, so the
scheduler must pick a node BEFORE the EBS volume is provisioned and the PVC
binds — with no schedulable node, provisioning never starts and the PVC stays
Pending. The pods legitimately cannot start yet. The providers'
default readiness waits then timed out and failed the apply on infrastructure
that was otherwise perfectly correct, so the workaround during the Coursera
onboarding was: apply with `enable_observability = false`, wait for the cell to
reach RUNNING, flip it to `true`, apply again.

The workloads now carry `wait = false` (and `wait_for_rollout = false` on the
Postgres StatefulSet), so the apply completes and the pods schedule on their own
once worker nodes appear. **If you find an older note telling you to toggle the
flag between applies, it is stale — do not follow it.**

Two consequences worth knowing:

- **Apply success no longer means the stack is up.** It means the objects were
  created. Convergence is asserted separately by the Phase-4 barrier, and
  continuously by the alerting rules below.
- **`wait = false` does not skip Helm hooks.** Hook Jobs still block a release
  independently, so this only works because all three charts render zero
  `helm.sh/hook` resources at their pinned versions (prometheus 29.17.0, grafana
  10.5.15, opentelemetry-collector 0.108.0). **Re-audit on every chart bump** — a
  chart that introduces a hook Job silently restores the old coupling.

### Alert rules

Rules live in `observability/prometheus-values.yaml.tftpl` under
`alerting_rules.yml`. Four groups:

| Group | Covers |
|---|---|
| `elasticsearch` | cluster red/yellow, unassigned shards, disk flood watermark, exporter down |
| `temporal` | role availability, SLO latencies, shard-lock latency, persistence errors, resource-exhausted, payload-size limits, no-poller task queues |
| `workloads` | **any** Deployment or container in `instance-*` namespaces |
| routing (`null`, `customer`, `pavo-sanitizer`) | where alerts are delivered, not what fires |

The `workloads` group is deliberately generic — it matches every Deployment and
container rather than naming services, so a workload added later is covered
without editing this file:

- **`DeploymentReplicasUnavailable`** — available < desired for 15m. Fires for a
  bad image, a failing probe, unschedulable Pods, or a Pod that cannot start
  because its config is wrong. 15m clears an ordinary rolling update.
- **`ContainerCrashLooping`** — any container, **including init containers**, in
  `CrashLoopBackOff` for 10m. Separate from the rule above because a Deployment
  can sit at its desired replica count while extra Pods crash-loop behind it: an
  HPA scale-up into a broken config looks healthy by replica count alone.

StatefulSets are not covered — the only one on a cell is Elasticsearch, which has
its own health alerts in the `elasticsearch` group.

> **Merging a rule change does not deliver it.** This module is customer-applied,
> so new rules only reach a cell when that customer re-runs `terraform apply`.
> Track the re-apply per cell; a merged alert is not a live alert.

### Dashboards

Dashboards are **as-code** — ConfigMaps labelled `grafana_dashboard`, loaded by the
Grafana sidecar (`observability/manifests/`). They evolve by **bumping this
module's version** (edit the JSON, tag, customers pick it up on their next apply).
For an urgent fix without a release, apply the ConfigMap directly:
`kubectl apply -f observability/manifests/<dashboard>.yaml -n pavo-observability`
(and back-port the edit into the module so the next apply doesn't revert it).
