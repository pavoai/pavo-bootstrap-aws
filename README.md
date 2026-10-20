# pavo-bootstrap-aws

Customer-applied Terraform module that provisions the **bootstrap-tier** IAM
resources Pavo's workload module needs in your AWS account. This module is
applied **once per deployment cell** (one EKS cluster) by you (the customer),
before Pavo's workload Terraform runs. It does not depend on a Pavo instance
ID, so it can run as soon as the deployment cell exists.

Stage 1 items from the latest BYOC security review are answered in
[`docs/security-review-response.md`](../docs/security-review-response.md).

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
  source = "git::https://github.com/pavoai/pavo-bootstrap-aws.git?ref=v0.6.1"
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
  IAM workload boundary (source of truth: `policy-statements.json`) and the
  `/pavo/shared/*` SSM parameters, including the single-cell sentinel. When
  `enable_microvm_image_builds = true` (or those markers already exist), also the
  MicroVM publisher/build permission boundaries and
  `/pavo/shared/microvm_*_boundary_arn`.
  When `cell_kms_key_arn` is set, also the account EBS default key (= the CMK,
  encryption by default on) plus KMS grants for the AutoScaling and EKS-nodegroup
  service-linked roles, so node and keyless-StorageClass volumes use the CMK.
- **Cell-scoped** (keyed on the cluster name): the ESO IRSA role + ESO / Reloader /
  Sigstore-policy-controller Helm releases, the `pd-balanced` StorageClass, the
  `pavo-nginx` IngressClass, the Let's Encrypt ClusterIssuer (and, when
  `install_private_ca = true`, the in-cell `pavo-private-ca` ClusterIssuer), the
  per-service Sigstore ClusterImagePolicies, the EKS access entry for the
  Omnistrate runner, the `/pavo/cells/<cluster>/*` SSM parameters, the per-cell
  OpenTofu provider-mirror S3 bucket, and Interface VPC endpoints for the AWS
  APIs instance tofu refreshes on plan (KMS, Secrets Manager, IAM, RDS,
  ElastiCache, SNS, SQS, EFS, SES) so a private / no-NAT cell can plan before
  those endpoints exist at the instance layer. Helm and in-VPC observability
  images are pinned from `mirrored-images.json` (artifact-plane ECR); omitting
  those pins rewrites a no-NAT cell to public registries.

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
| S3 bucket | `pavo-tf-state-<account-id>` | versioned, SSE-KMS under the CMK when passed (else AES256), public-access-blocked |
| DynamoDB lock table | `pavo-tf-state-locks` | `LockID` hash key, on-demand |
| State key (per cell) | `pavo-bootstrap-aws/<cluster>/terraform.tfstate` | |

Then commit a per-cell backend file and init against it (this is what the
committed `cells/<cluster>/backend.s3.tfbackend` files look like):

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
- **Read-only discovery permissions.** The module finds the cell's cluster,
  private subnets and Omnistrate's existing S3/DynamoDB gateway
  endpoints (so it only fills gaps instead of colliding with
  `RouteAlreadyExists`). A data source cannot grant its own permission, so these
  must be in place **before the plan runs** (`eks:ListClusters` and
  `ec2:DescribeSubnets` only when `eks_cluster_name` / `private_subnet_ids` are omitted):

  ```json
  [
    {
      "Effect": "Allow",
      "Action": ["ec2:DescribeVpcEndpoints", "ec2:DescribeRouteTables", "ec2:DescribeSubnets"],
      "Resource": "*",
      "Condition": { "StringEquals": { "ec2:Region": "<REGION>" } }
    },
    { "Effect": "Allow", "Action": "eks:ListClusters", "Resource": "*" },
    { "Effect": "Allow", "Action": "eks:DescribeCluster", "Resource": "arn:aws:eks:<REGION>:<ACCOUNT>:cluster/hc-*" }
  ]
  ```

  Verify by exercising the real calls with the same credentials Terraform will
  use:

  ```bash
  aws ec2 describe-vpc-endpoints --max-items 1 --region <REGION> >/dev/null \
    && aws ec2 describe-route-tables --max-items 1 --region <REGION> >/dev/null \
    && aws ec2 describe-subnets --max-items 1 --region <REGION> >/dev/null \
    && aws eks list-clusters --region <REGION> >/dev/null \
    && echo OK
  ```

  `Resource: "*"` is inherent to the EC2 describe actions, and `eks:ListClusters`:
  they have no resource-level permissions (the EC2 ones take only
  the `ec2:Region` condition used above). `eks:DescribeCluster` is scoped to
  Omnistrate's `hc-*` clusters. All are read-only.

  > **v0.6.0 only:** that release discovered endpoints through the Resource
  > Groups Tagging API and needed `tag:GetResources`. v0.6.1 replaced it with
  > the describe calls above, so `tag:GetResources` is **no longer required**
  > and can be dropped if you added it for v0.6.0.

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
export EKS_CLUSTER_NAME=hc-<cluster>  # your cluster name
export AWS_REGION=us-east-1           # your region
./scripts/preflight.sh --mode=direct
```

## Variables

| Variable | Description |
|---|---|
| `eks_cluster_name` | *Optional.* When omitted, the one `hc-*` EKS cluster in the provider's account/region; zero or several fail the plan. |
| `vpc_id` | *Optional.* When omitted, read from the cluster. |
| `private_subnet_ids` | *Optional.* When omitted, the cluster VPC's subnets tagged `kubernetes.io/role/internal-elb=1` (same rule as the instance module). |
| `eks_oidc_provider` | *Optional.* When omitted, read from the cluster. If set, **without** the `https://` prefix. |
| `runner_role_arn` | IAM role ARN of the Omnistrate Terraform runner principal that needs cluster-admin RBAC on this EKS cluster. MUST be the role ARN (`arn:aws:iam::<acct>:role/<RoleName>`), NOT an assumed-role session ARN. Its account must equal the injected AWS provider's account (the deterministic cell-account guard). Pavo provides it. |
| `k8s_get_token_role_arn` | *Optional; cross-account only.* IAM role the K8s/Helm exec-auth (`aws eks get-token --role-arn`) assumes when the run's **ambient** credentials are in a different account than the cell (e.g. a central Atlantis/CI account that assumes into the cell only at the provider level). Ambient creds must be able to assume it; it does **not** inherit provider-only options like `external_id`. Must differ from `runner_role_arn` and be in the provider's account. The module does **not** create its access entry (operator prerequisite). Empty = use ambient creds directly. |
| `image_policy_mode` | Sigstore ClusterImagePolicy mode for globs `ghcr.io/pavoai/<svc>*`. `"enforce"` (default) rejects a **matching** image that fails verification; `"warn"` admits and warns. Policy-controller `no-match-policy = allow`. A private cell pulls artifact-plane ECR names, which do **not** match those globs, so admission does not check those pulls until CIP globs include the ECR rewrite. |
| `policy_controller_chart_version` | Helm chart version for `sigstore/policy-controller`. Default `0.10.6`. Bump deliberately and validate by setting `image_policy_mode = "warn"` for the upgrade apply — chart upgrades can change webhook config paths or CRD API versions. |
| `external_secrets_chart_version` | Helm chart version for `external-secrets/external-secrets`. Default `0.10.4` (v1beta1 CRDs). The image tag stays in `mirrored-images.json`; bump both together and check SecretStore compatibility. |
| `reloader_chart_version` | Helm chart version for `stakater/reloader`. Default `1.1.0`. The image tag stays in `mirrored-images.json`; bump both together. |
| `central_ci_project_id` | GCP project hosting Pavo's central Cloud Build that builds + signs all `ghcr.io/pavoai/*` images. Default `onboarding-455713`. The per-service signing SAs live here as `cloud-build-<service>@<central_ci_project_id>.iam.gserviceaccount.com`. Override only if you've forked the signing pipeline into a different GCP project. |
| `network_posture` | Cell posture: `standard` (default) or `strict`. The Route53 interface VPCE is created only on `strict`. Set `strict` on a dedicated zero-egress cell before the first instance. See [RUNBOOKS.md → Route53 interface VPCE](RUNBOOKS.md#route53-interface-vpce-host-cluster-external-dns). |
| `enable_eck` | Install the Elastic Cloud on Kubernetes (ECK) operator on this cell. **Default `false`.** Set `true` **only** on a cell that will host a self-hosted in-VPC Elasticsearch instance (`es_mode = self_hosted`). Cloud-Elasticsearch-only cells should leave it off to avoid an idle operator, CRDs, and validating webhook. When `true`, the cell publishes `/pavo/cells/<eks_cluster_name>/eck_ready=true`; the per-instance module reads that and **fails fast** if a `self_hosted` instance is created before ECK exists. |
| `eck_operator_chart_version` | Helm chart version for `elastic/eck-operator` (operator + CRDs move in lockstep). Default `3.4.0`. Only relevant when `enable_eck = true`. Confirm the ECK ↔ Elasticsearch support matrix before bumping (ECK 3.x supports the 8.x and 9.x stacks). |
| `install_private_ca` | Install the in-cell private CA (`pavo-private-ca` ClusterIssuer). **Default `false`.** Set `true` on a `network_posture = strict` cell — Let's Encrypt HTTP-01 needs egress. Install-once / monotonic: do not flip back on a live cell. Publishes `/pavo/cells/<cluster>/private_ca_ready`. |
| `network_policy_ready` | Operator assertion that AWS VPC CNI NetworkPolicy enforcement is on. **Default `false`.** Set `true` only after Omnistrate confirms it. Publishes `/pavo/cells/<cluster>/network_policy_ready`; a `strict` instance fails fast without it. |
| `enable_observability` | Install in-VPC Prometheus + Grafana + OTel. **Default `true`.** Requires `cell_kms_key_arn` and `observability_grafana_host`. Set `false` only on Grafana Cloud cells (`grafana_mode = cloud`). |
| `observability_grafana_host` | Public hostname Grafana is served at (`grafana.<this>`). Required when `enable_observability = true`. |
| `cell_kms_key_arn` | Cell customer-managed KMS key ARN (`gp3-cmk` plus workload encryption). Required when `enable_observability = true`. |
| `kubeconfig_path` | Kubeconfig for Kubernetes-facing providers. Empty (default) uses `aws eks get-token`. Set only for a private-only cell whose API is not publicly reachable. |
| `enable_microvm_image_builds` | Create the account-owned MicroVM publisher/build permission boundaries. **Default `false`.** Once either `/pavo/shared/microvm_*_boundary_arn` marker exists, `false` retains them. |
| `legacy_eso_cell_secret_read` | Keep the cell ESO role's account-wide `rds!*` secret read. **Default `false`.** Plan fails while any `pavo-aws-sm-*` ClusterSecretStore exists and this is false. |
| `connector_assumable_role_arns` | Exact IAM role ARNs in your accounts that Pavo's connectors may assume (Amazon SageMaker IAM-role mode). **Default empty.** Publishes them for the instance's workload role, which may then assume exactly these roles. The permission boundary's always-present ceiling limits this to a Pavo-issued external ID, and your role's trust policy requires the exact one. See *Connector access from a strict cell*. |
| `strict_egress_extra_destinations` | Extra destinations (CIDR, TCP ports, description) that pods of a strict instance may reach, such as your outbound proxy or an on-premises range. **Default empty.** See *Connector access from a strict cell*. |
| `enable_sagemaker_api_endpoint` | Add the SageMaker API to the cell's interface endpoints (`vpc_interface_endpoints.tf`). **Default `false`.** See *Connector access from a strict cell*. |
| `snowflake_privatelink` | Snowflake over AWS PrivateLink: the endpoint service name and hostnames from `SYSTEM$GET_PRIVATELINK_CONFIG`. **Default `null`.** Needs Snowflake Business Critical on AWS in the cell's region. See *Connector access from a strict cell*. |

Pavo sends `runner_role_arn`; the module finds the cluster, VPC, private
subnets and OIDC issuer in the provider's account. Region is
**not** a variable — it comes from the injected AWS provider. Remaining
variables (alert webhooks, sanitizer image, observability chart pins,
`cert_manager_namespace`, `customer_name`) default to safe values for a new
cell — override only if you need to.

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

## Before you apply: decide these inputs

Answer these before the first `terraform apply`. Each one has cost a real
onboarding hours, and none of them surfaces as a clear error at the time you get
it wrong.

These are two **independent** questions. How the key was created decides whether
the tag is present; whether its key policy delegates to account root decides
whether explicit key-policy statements are needed. Answer both.

| Question | If yes, set | If you get it wrong |
|---|---|---|
| Are you using a customer-managed KMS key? | `cell_kms_key_arn = <key ARN>` | Required whenever this cell encrypts EBS with your own key. See [RUNBOOKS.md → Setting up the CMK](RUNBOOKS.md#setting-up-the-cmk-separate-from-bootstrap-before-workload-deploys). |
| Did you create that CMK **by hand** rather than with `scripts/create-cmk.sh`? | Tag it `omnistrate.com/customer-managed-kms=true`. | EBS volumes are created and then deleted seconds later. PVCs hang `Pending` forever **with no Terraform error** — the apply just times out on a Helm wait. This took hours to diagnose on a real onboarding. |
| Does that key's policy **not** delegate to account root? | Add the explicit statements from [RUNBOOKS.md → Explicit key policy](RUNBOOKS.md#explicit-key-policy-customer-governed-keys). | The EBS CSI driver and the workload/ESO roles cannot reach the key at all, because IAM alone cannot grant access to a key whose policy does not delegate to root. |

A hand-created key that **does** delegate to root (the AWS default) needs only
the tag; IAM handles the rest. `scripts/create-cmk.sh` applies the tag for you,
and the hand-created path does not, which is the single most common way this
goes wrong.

## Apply

```bash
./scripts/preflight.sh --mode=direct
# Configure backend.tf first (see "Configuring Terraform state" above), then:
terraform init
terraform plan
terraform apply
```

Capture outputs:

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

## Laptop access (strict cell)

The load balancer on a strict cell is internal. `scripts/create-cell-vpn.sh`
builds a mutual-TLS AWS Client VPN: a local EasyRSA CA, an ACM import, one
subnet association, cluster-admin for the caller, and a `.ovpn` for AWS VPN
Client. It is not part of the cluster and not created by `terraform apply`.
The endpoint costs about $0.10/hour. The script discovers the VPC from the
EKS cluster; pass an optional client CIDR as the second argument (default
`10.201.0.0/22`).

```bash
AWS_PROFILE=<account-profile> ./scripts/create-cell-vpn.sh <eks-cluster-name>
```

The profile is written under `$HOME/pavo-cvpn-<eks-cluster-name>/`. Do not
commit it; the file contains the client private key. The VPN CA is not the
in-cluster private CA (`pavo-cell-root-ca`); ingress site trust is still the
MDM-installed cell root.

## Consuming as a child module (cross-account BYOC)

Customers pin the mirror (`git::https://github.com/pavoai/pavo-bootstrap-aws.git?ref=v0.6.1`)
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
  source = "git::https://github.com/pavoai/pavo-bootstrap-aws.git?ref=v0.6.1"

  providers = { aws = aws.cell }   # only if your aws provider is aliased

  runner_role_arn            = var.runner_role_arn
  cell_kms_key_arn           = var.cell_kms_key_arn
  observability_grafana_host = var.observability_grafana_host
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

### Migrating an existing consumer to v0.6.1

The gateway endpoints are now adaptive: they cover only the route tables
Omnistrate's own gateway endpoint does not. No config or new permission is
required (discovery is a live `ec2:DescribeVpcEndpoints`, already granted).

Bump `?ref` to `v0.6.1` and plan. On an existing owner, expect only a `moved`
address change (`aws_vpc_endpoint.*_gateway` to `[0]`), with no `route_table_ids`
change and no destroy. On a fresh cell where Omnistrate already covers every
route table, no endpoint is created.

This assumes Omnistrate supplies exactly one available S3 and one available
DynamoDB gateway endpoint for the cell. Zero or two fails planning before any
change (see RUNBOOKS).

## Strict-cell flags (`network_posture`, `install_private_ca`, `network_policy_ready`)

A zero-egress cell sets `network_posture = strict` (Route53 interface VPCE only
on that posture). Pair it with:

- `install_private_ca = true` — Let's Encrypt HTTP-01 needs egress, so strict
  ingress certs come from `pavo-private-ca`. Install-once; flipping the flag
  off withdraws `/pavo/cells/<cluster>/private_ca_ready` and does not destroy
  the signing keys (`apply_only`).
- `network_policy_ready = true` — only after Omnistrate confirms VPC CNI
  NetworkPolicy enforcement. Without it a `strict` instance's default-deny
  policies are inert.

`kubeconfig_path` is required when the EKS API has no public endpoint. See
[Laptop access](#laptop-access-strict-cell) for Client VPN.

## Cell self-hosting flags (`enable_eck`, `enable_observability`)

Each in-VPC substrate is gated by a cell flag (`enable_eck` defaults `false`, `enable_observability` defaults `true`):

| Flag | Installs (cell-scoped) | Instance routing flag | Cell→instance gate |
|---|---|---|---|
| `enable_eck` | ECK operator (self-hosted ES) | `es_mode` | `/pavo/cells/<cluster>/eck_ready` SSM + **fail-fast** — a `self_hosted` ES CR *hard-fails* without ECK |
| `enable_observability` | in-VPC Grafana/Prometheus + OTel collector | `grafana_mode` | Phase-4 one-time convergence barrier (see below) |

- **`enable_eck` is opt-in** — a cloud-ES cell must not run an idle operator.
- **`enable_observability` is on by default** and then requires `cell_kms_key_arn` + `observability_grafana_host`. Set it `false` on a cell whose instances use Grafana Cloud (`grafana_mode = cloud`). **Upgrade note:** a cell that relied on the old `false` default must set `enable_observability = false` explicitly before applying this version, or the plan fails on the missing CMK/host.
- **Set `true` in `cells/<cluster>/<cluster>.tfvars`** by whoever provisions the cell: the **customer** (mirrored module, their admin, they audit it) or **Pavo** at onboarding. Recorded in tfvars so it can't silently regress; never automatic, never a runtime toggle. Self-hosted customer → both `true`, paired with the matching instance flag.
- **Cell-level, not per-instance:** the substrate is cluster-scoped (one operator / one Grafana per cell), so a per-instance flag can't create it. `es_mode`/`grafana_mode` only **route**.
- **Both substrates are gated, for different reasons and at different points.** ES uses `eck_ready` as a *pre*-condition: a `self_hosted` ES CR hard-fails without the operator, so Phase 4 must refuse to start. Observability is gated *after* the fact, by a one-time Phase-4 convergence barrier.

  An earlier version of this table said observability needed no gate, on the grounds that a misrouted cell merely *drops* telemetry and the failure is therefore soft. **That reasoning has been retired.** Observability is not an ordinary workload whose loss degrades one feature: it is the mechanism that reports whether everything else is healthy. A cell reaching READY with a monitoring substrate that never started is a bad terminal state, because every subsequent failure becomes partly or wholly invisible. The invariant is now:

  > A newly created cell must not complete Phase 4 successfully unless the minimum observability data path has converged at least once.

  Deliberately narrow. It is a one-time creation assertion, **not** a permanent health check — Terraform must not become an ongoing monitoring system. Continuous health after creation belongs to Prometheus, Alertmanager and the workload-health alerting rules. Those two mechanisms cover different failure modes and neither substitutes for the other: the alerts run *inside* the stack they watch, so they cannot report Prometheus failing to start, which is exactly what the barrier exists to catch.

## Connector access from a strict cell (`connector_assumable_role_arns`, `strict_egress_extra_destinations`, `enable_sagemaker_api_endpoint`, `snowflake_privatelink`)

A strict cell has no NAT or internet gateway, and its instances' pods may reach only the VPC, same-region S3 and the cluster's own services. These four inputs let specific connectors reach the customer's own systems. All four default to off or empty, so a cell that sets none of them renders exactly as before.

| Input | What it creates (cell-scoped) | What the instance does with it |
|---|---|---|
| `connector_assumable_role_arns` | The parameter `/pavo/cells/<cluster>/connector_assumable_role_arns` | Adds a statement to the workload role allowing it to assume exactly these roles, so connectors in IAM-role mode (Amazon SageMaker today) can sign in. The permission boundary limits this to a Pavo-issued external ID, and your role's trust policy requires the exact one |
| `strict_egress_extra_destinations` | The parameter `/pavo/cells/<cluster>/strict_egress_extra_destinations` | Adds one rule per entry to the strict egress NetworkPolicy, opening only that CIDR and only its listed TCP ports |
| `enable_sagemaker_api_endpoint` | Adds `sagemaker.api` to the cell's interface endpoints in `vpc_interface_endpoints.tf`: same reuse rule (an existing foreign private-DNS endpoint is reused), naming and HTTPS-only security group as the other cell endpoints, with private DNS | Nothing: the endpoint's IPs are inside the VPC, which the strict policy already allows |
| `snowflake_privatelink` | An interface endpoint to your Snowflake endpoint service (on the same subnets as the other cell endpoints), its own security group allowing HTTPS (443) only from the cell VPC, and a Route 53 private hosted zone `privatelink.snowflakecomputing.com` associated with this VPC only, with one CNAME per PrivateLink hostname | Nothing: the endpoint's IPs are inside the VPC. In Pavo the Snowflake connector's account is entered as the PrivateLink identifier (`<locator>.<region>.privatelink`) |

The permission boundary always carries the ceiling for this, as `ConnectorAssumeCustomerRoles` in [`rendered-permission-boundary.json`](rendered-permission-boundary.json), the boundary you review:

```json
{
  "Sid": "ConnectorAssumeCustomerRoles",
  "Effect": "Allow",
  "Action": ["sts:AssumeRole"],
  "Resource": ["arn:aws:iam::*:role/*"],
  "Condition": { "StringLike": { "sts:ExternalId": "pavo-*" } }
}
```

It is a ceiling, not a grant: it lets a workload role assume a role only with a Pavo-issued external ID, and allows nothing on its own. The workload role's own policy names exactly the roles you list in `connector_assumable_role_arns`, and has no such statement while the list is empty.

Example `cells/<cluster>/<cluster>.tfvars` entries:

```hcl
connector_assumable_role_arns = ["arn:aws:iam::<account-id>:role/pavo-sagemaker-read"]

strict_egress_extra_destinations = [
  { cidr = "10.40.0.10/32", ports = [3128], description = "Outbound proxy to Microsoft (Power BI)" },
]

enable_sagemaker_api_endpoint = true

# From SYSTEM$GET_PRIVATELINK_CONFIG in your Snowflake account
snowflake_privatelink = {
  vpce_service_name = "com.amazonaws.vpce.us-east-1.vpce-svc-0123456789abcdef0"
  hostnames = [
    "xy12345.us-east-1.privatelink.snowflakecomputing.com",
    "myorg-myaccount.privatelink.snowflakecomputing.com",
  ]
  # false when your VPCs already resolve privatelink.snowflakecomputing.com (a
  # shared private zone or forwarding to your resolvers): the endpoint is still
  # created, hostnames may be empty, and your DNS team points the account
  # hostnames at the endpoint's DNS name (output snowflake_vpce_dns_name).
  manage_dns = true
}
```

Snowflake over PrivateLink also needs steps in your Snowflake account, in this order:

1. Your Snowflake ACCOUNTADMIN authorizes this cell's AWS account with `SYSTEM$AUTHORIZE_PRIVATELINK` (needs Business Critical or higher, with Snowflake on AWS in the cell's region).
2. They run `SYSTEM$GET_PRIVATELINK_CONFIG` and pass the `privatelink-vpce-id` and the two PrivateLink account URLs (`privatelink-account-url` and `regionless-privatelink-account-url`) into `snowflake_privatelink` above, then apply this module. Your network team first says how your VPCs resolve `privatelink.snowflakecomputing.com`: if they already do, set `manage_dns = false` and have them point the two hostnames at the endpoint's DNS name (output `snowflake_vpce_dns_name`); otherwise leave it `true` and the module creates the private zone.
3. They allow the Pavo service user to log in through the endpoint, typically a network rule of type `AWSVPCEID` naming the endpoint ID from this module's `snowflake_vpce_id` output.

- **Three checks, all of which must pass.** The boundary allows assuming a role only with a Pavo-issued external ID. The workload role's policy, from the cell parameter, names exactly the roles you list. Your role's trust policy, which stays yours, names the workload role and the exact external ID shown in Pavo's setup panel.
- **Why the boundary checks the external ID's `pavo-` prefix, not its exact value.** The exact external ID is derived for your Pavo tenant only once the Pavo instance exists, which is after this module is applied, so it cannot be named here. Your role's trust policy pins the exact value; the boundary adds that only a Pavo-issued ID is ever presented. Both are required for the assume-role call to succeed.
- **Values come from the cell, not from instance parameters.** The role grant and the destination list therefore never depend on an instance parameter being present when an instance deploys. The strict egress policy they extend is itself created by the instance module when the instance's `network_posture` is `strict`.
- **Order of operations.** Apply this module first so the parameters exist; instances pick them up on their next deploy. An instance on a cell that sets none of them renders nothing extra.
- **Routing stays yours.** `strict_egress_extra_destinations` opens the Kubernetes egress policy only. Reaching a proxy or an on-premises range also needs your Transit Gateway, route tables and firewall rules.
- **Keep destinations narrow.** Use a /32 for a single host such as a proxy or a Confluence server. The module accepts IPv4 only and rejects anything broader than /16, so a typo cannot open a whole internal network.
- **Scope of the SageMaker endpoint.** It covers the SageMaker API in the cell's region. SageMaker in another region, and SageMaker MLflow Apps (AWS publishes no PrivateLink endpoint for them), need a separate route.
- **Scope of the Snowflake endpoint.** It covers your Snowflake account in the cell's region. The endpoint goes in the cell's private subnets that are in Availability Zones your Snowflake endpoint service supports, and the plan stops with an error if there are none. Query results are downloaded from Snowflake's internal stage on S3 through the cell's S3 gateway endpoint, which reaches buckets in the same region only, so a Snowflake account in another region needs a different route. This module sets no policy on that gateway endpoint. If you restrict it, allow your account's stage bucket, which `SYSTEM$ALLOWLIST_PRIVATELINK()` lists with type `STAGE`.
- **HTTPS only, unlike Snowflake's PrivateLink guide.** Snowflake's guide also opens port 80 on the endpoint, for its drivers' OCSP response cache. Since version 4.8.0 the Snowflake Connector for Python does no certificate-revocation (OCSP) checking unless a client opts in, so this input requires every Pavo service that connects to Snowflake to run connector 4.8 or later without opting in. An older client would wait out OCSP timeouts against the closed port before connecting. Certificate-chain and hostname verification still apply, and the traffic stays on PrivateLink. If your policy requires revocation checking, tell us: it needs port 80 on this endpoint, the two `ocsp.` hostnames and a client change. If a `privatelink.snowflakecomputing.com` zone is already shared into this VPC, or a Route 53 Resolver rule forwards `snowflakecomputing.com` to your own DNS, the zone here would clash: leave `snowflake_privatelink` unset and add the records on your side instead.

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
| **Account** | `pavo-bootstrap-aws/` (AWS only) | Customer (AWS creds) | Customer-local | IAM permission boundaries, `/pavo/shared/*` SSM |
| **Cell** (one EKS cluster) | `pavo-bootstrap-aws/` (AWS only) | Customer (AWS creds) | Customer-local | IngressClass, ClusterIssuer, ESO/Reloader helm releases, EKS access entry, `/pavo/cells/<cluster>/*` SSM |
| **Customer** (one `customer_name`) | `pavo-customer-bootstrap/` | Pavo ops (Zitadel PAT) | GCS `gs://pavo-terraform-state`, prefix `customer-bootstrap/<customer>` | Zitadel org, project, OIDC app, IdPs, login policy |
| **Instance** (one Pavo deployment) | `terraform-omnistrate-aws/` (AWS)<br>`terraform-omnistrate-gcp/` (GCP) | Omnistrate runner | Omnistrate-managed | AWS: RDS, ElastiCache, S3, SNS/SQS, EFS, workload IAM role.<br>GCP: Cloud SQL, Memorystore, GCS, Pub/Sub, workload service account.<br>Both: per-instance namespace, app secrets, Elastic Cloud deployment |

Account and Cell scope are AWS-only today: GCP has no cell-bootstrap module, so a
GCP cell's substrate is not customer-applied. Customer scope is cloud-neutral —
`pavo-customer-bootstrap/` owns identity for both clouds.

### Picking the right module for a new resource

1. If deleting one Pavo instance shouldn't delete it → not the per-instance module (`terraform-omnistrate-aws/` or `terraform-omnistrate-gcp/`).
2. If its `name` doesn't include `var.instance_id` → probably not the per-instance module.
3. If it lives in Pavo's identity tenant (Zitadel) → `pavo-customer-bootstrap/`.
4. If it's cluster-scoped K8s or per-cell IAM → `pavo-bootstrap-aws/`.
5. Otherwise (per-instance app resource) → the per-instance module for that cloud.
6. If it's a self-hostable cell substrate the customer opts into (ECK, in-VPC observability) → `pavo-bootstrap-aws/` behind an `enable_*` flag — NEVER an Omnistrate cell-amenity. See `pavo-bootstrap-aws/README.md` → *Cell self-hosting flags*.

### Hard rules

- No cluster-scoped K8s resource may live in a per-instance module, even with `apply_only = true` as a mitigation.
- Exception: the per-instance file-system StorageClass. Kubernetes has no namespaced StorageClass. AWS `efs-pavo-vpc-<instance_id>` must reference the instance's own EFS file system, which doesn't exist at bootstrap time; GCP `filestore-pavo-vpc-<instance_id>` has no cell-bootstrap module to live in.
- `pavo-customer-bootstrap/` MUST NOT declare `instance_id` as a variable (structural enforcement of the customer-hostname invariant).
- A second cell in the same AWS account is currently guarded by an SSM sentinel — see `pavo-bootstrap-aws/README.md`.
- No fifth "place": Omnistrate cell-amenities are not a home for Pavo infra. Cell-scoped infra a customer should apply/audit in their VPC → `pavo-bootstrap-aws/` (customer-applied), never an amenity (Pavo-applied, no audit trail). The observability stack shipped as an amenity by mistake — now migrated to `enable_observability` in `pavo-bootstrap-aws/` (the old `observability/` amenity module was removed).
