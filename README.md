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
  source = "git::https://github.com/pavoai/pavo-bootstrap-aws.git?ref=v0.6.0"
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

## What it creates

Two scopes:

- **Account-scoped** (shared across the AWS account): the `pavo-permission-boundary-shared`
  IAM workload boundary (source of truth: `policy-statements.json`) and the two
  `/pavo/shared/*` SSM parameters, including the single-cell sentinel.
- **Cell-scoped** (keyed on the cluster name): the ESO IRSA role + ESO / Reloader /
  Sigstore-policy-controller Helm releases, the `pd-balanced` StorageClass, the
  `pavo-nginx` IngressClass, the Let's Encrypt ClusterIssuer, the per-service Sigstore
  ClusterImagePolicies, the EKS access entry for the Omnistrate runner, the
  `/pavo/cells/<cluster>/*` SSM parameters, and the per-cell OpenTofu provider-mirror
  S3 bucket.

> The EBS CSI driver is owned by Omnistrate, not this module — it only adds the
> `pd-balanced` StorageClass on top of the pre-installed driver.

**One deployment cell per account.** A `/pavo/shared/bootstrap_cell` SSM sentinel
(`prevent_destroy = true`) hard-guards this: a second cell's apply in the same account
fails `ParameterAlreadyExists` before any IAM/role/K8s resource is created. Inspect:

```bash
aws ssm get-parameter --name /pavo/shared/bootstrap_cell \
  --query 'Parameter.Value' --output text   # the cluster this account is bootstrapped for
```

The full per-resource inventory (IAM, EKS, Helm, K8s, Sigstore, the S3 provider mirror,
and CMK-backed `gp3-cmk` EBS volumes) is in
[RUNBOOKS.md → What it creates](RUNBOOKS.md#what-it-creates-full-inventory).

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
Not using the helper (an existing corporate backend, or fully-inline config)? See
[RUNBOOKS.md → Terraform state: manual backend alternatives](RUNBOOKS.md#terraform-state-manual-backend-alternatives).

**CRITICAL**: without ANY backend block in the source, `-backend-config` flags are
silently ignored and Terraform defaults to local state. Verify init output reads
`Backend type: s3` (not `local`). For Terraform Cloud / HCP / other backends, see the
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
  If it doesn't have access, see the *Authorization: create + verify* recipe below
  (cross-account) or [RUNBOOKS.md → Case B](RUNBOOKS.md#case-b-bootstrapping-without-k8s-admin) (direct apply).
- **`tag:GetResources` (`Resource: "*"`, read-only) on the plan-time AWS identity.**
  The gateway-endpoint discovery calls the Resource Groups Tagging API at plan time,
  so the grant must pre-exist (the module cannot grant it to itself). Verify the
  effective decision (boundaries/SCPs included) before applying:
  ```bash
  aws iam simulate-principal-policy --policy-source-arn <plan-identity-role-arn> \
    --action-names tag:GetResources        # expect: allowed
  ```
  Without it, `terraform plan` fails before anything is created.

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
Pavo's workload Terraform runs against this cell (see [RUNBOOKS.md → S3 provider
mirror](RUNBOOKS.md#what-it-creates-full-inventory) for why this is mandatory and how to refresh it):

```bash
# Same account/region as the apply; <eks-cluster-name> is the eks_cluster_name var.
AWS_PROFILE=<account-profile> ./scripts/populate-provider-mirror.sh <eks-cluster-name>
```

## Consuming as a child module (cross-account BYOC)

Customers pin the mirror (`git::https://github.com/pavoai/pavo-bootstrap-aws.git?ref=v0.6.0`)
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
  source = "git::https://github.com/pavoai/pavo-bootstrap-aws.git?ref=v0.6.0"

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

### Migrating an existing consumer to v0.6.0

The gateway endpoints are now adaptive (cover only route tables no external
Omnistrate endpoint already covers). One new permission is required:

1. Grant `tag:GetResources` to the plan-time identity (see *Prerequisites*).
2. Bump `?ref` to `v0.6.0` and plan. On an existing owner, expect a `pavo:managed-by`
   tag add plus a `moved` to `[0]`, with no `route_table_ids` change and no destroy.
   On a fresh cell where Omnistrate already covers every route table, no endpoint is
   created.

## Cell self-hosting flags (`enable_eck`, `enable_observability`)

Each in-VPC substrate a strict/residency customer opts into is gated by an opt-in, **default-`false`** flag:

| Flag | Installs (cell-scoped) | Instance routing flag | Cell→instance gate |
|---|---|---|---|
| `enable_eck` | ECK operator (self-hosted ES) | `es_mode` | `/pavo/cells/<cluster>/eck_ready` SSM + **fail-fast** — a `self_hosted` ES CR *hard-fails* without ECK |
| `enable_observability` | in-VPC Grafana/Prometheus + OTel collector | `grafana_mode` | none — a misrouted cell just *drops* telemetry (soft), so no gate is warranted |

- **Default `false`, opt-in per cell** — a cloud cell must not run an idle operator / unused monitoring stack.
- **Set `true` in `cells/<cluster>/<cluster>.tfvars`** by whoever provisions the cell: the **customer** (mirrored module, their admin, they audit it) or **Pavo** at onboarding. Recorded in tfvars so it can't silently regress; never automatic, never a runtime toggle. Self-hosted customer → both `true`, paired with the matching instance flag.
- **Cell-level, not per-instance:** the substrate is cluster-scoped (one operator / one Grafana per cell), so a per-instance flag can't create it. `es_mode`/`grafana_mode` only **route**. Only ES adds a readiness gate (`eck_ready` fail-fast) because its failure is hard; observability's is soft, so `enable_observability` + `grafana_mode` are simply set together.

## Runbooks & reference

Detailed reference and operational runbooks live in [RUNBOOKS.md](RUNBOOKS.md):
full resource inventory + CMK-backed EBS; permission-boundary scoping & verification
(editing `policy-statements.json`); manual state backends; brand-new-cell
workload-node / `eck_ready` ordering; Case B (direct-apply operator without
cluster-admin); setting up the CMK (same-account + customer-governed key policy) +
rotation; scoping notes; and in-VPC observability.

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
