# Deployment Cell Amenities vs this module — scope review

**Status: findings note, no code change in this PR. Reachability is settled;
artifact mirroring is not. Read the conclusion at the bottom before acting on
either.**

## Why this exists

`hc-d75sozh69`, the first private-only cell, reports:

```
$ aws eks describe-cluster --name hc-d75sozh69 \
    --query 'cluster.resourcesVpcConfig.{pub:endpointPublicAccess,priv:endpointPrivateAccess}'
{ "pub": false, "priv": true }
```

Every cell before it (`hc-fmnwao4ct` and the Coursera cell included) had
`endpointPublicAccess: true` with `0.0.0.0/0`. This module configures Kubernetes
resources, so on a private-only cell it **cannot be applied from outside the
VPC** — `kubectl` times out even with a cluster-admin access entry granted.

The obvious fixes are a bastion in the VPC, or an optional provider override so
the `kubernetes` / `helm` / `kubectl` providers can target something reachable
(`providers.tf` currently hardcodes `data.aws_eks_cluster.primary.endpoint`).

Before building either, check whether the platform already does this. It largely
does.

## What Omnistrate already provides

[Deployment Cell Amenities](https://docs.omnistrate.com/operate-guides/deployment-cell-amenities/)
install cluster-scoped components per cell, applied **by Omnistrate from inside
the account**. Their own guidance names the exact category this module occupies:

> Install components that should exist once per cluster, such as shared
> Operators, Prometheus stacks, ExternalDNS, CSI drivers, ingress controllers, or
> policy controllers, at the deployment-cell layer. Use Deployment Cell Amenities
> for these prerequisites instead of treating them as manual post-install steps.

Capabilities that matter here:

| Need | Amenity feature |
| --- | --- |
| Helm releases | `type: Helm` with `ChartValues` / `LayeredChartValues` |
| Raw manifests | `type: KubernetesManifest`, inline `def` or `file` |
| Ordering (CRD before CR) | `dependsOn`, cross-type, validated for cycles |
| Per-cell on/off | `disable:` expression, e.g. `$sys.deploymentCell.accountTags["..."]` |
| Per-cell values | `LayeredChartValues` with `scope`, and `$sys.deploymentCell.accountTags` |
| Private registries | `CredentialsProvider`, `$secret.NAME` |

## Overlap with this module

This module creates 19 Kubernetes resources and 18 AWS ones. The Kubernetes half
maps almost one-to-one onto amenities:

| This module | Amenity form |
| --- | --- |
| `helm_release.external_secrets` | Helm |
| `helm_release.eck_operator` | Helm |
| `helm_release.policy_controller` | Helm |
| `helm_release.stakater_reloader` | Helm |
| `helm_release.observability_{prometheus,grafana,otel_collector}` | Helm |
| `kubectl_manifest.pavo_image_policy` | KubernetesManifest, `dependsOn: [policy-controller]` |
| `kubectl_manifest.private_ca_*` (5 objects) | KubernetesManifest chain |
| `kubectl_manifest.pavo_letsencrypt_prod` | KubernetesManifest — the amenities docs use a `letsencrypt-prod` ClusterIssuer as their worked example |
| `kubectl_manifest.pavo_ingress_class` | KubernetesManifest |
| `kubectl_manifest.obs_*` | KubernetesManifest |
| `var.enable_eck` / `install_private_ca` / `enable_observability` | `disable:` expressions on account tags |

What amenities do **not** cover is the other half, and it is the half that
matters most for the customer story: the IAM permission boundary, the workload
IAM role and policy, the 11 `/pavo/**` SSM parameters, the gateway endpoints, the
EKS access entry, and the provider-mirror S3 bucket.

## Why this is not an obvious migration

The split is clean, which makes it tempting. Three reasons to think before moving:

1. **The trust story lives in the AWS half, but the enforcement lives in the
   Kubernetes half.** We tell customers "the module is public, your team can read
   exactly what ceiling it sets on our workload, and we live inside whatever you
   set." That stays true for IAM. But `ClusterImagePolicy` is the control that
   refuses unsigned images, and moving it to an Omnistrate-applied template means
   Omnistrate, not the customer, applies our admission policy. That is a real
   change in who enforces what, and it is the customer's call, not ours.
2. **Account tags are per-account, not per-cell.** Our capability flags are
   cell-scoped. The single-cell-per-account SSM sentinel makes this survivable
   today, but it is an assumption, not a guarantee.
3. **`disable` fails closed on a missing tag.** Per the docs, a `disable`
   expression referencing a tag that is not set on the account does not resolve
   and *fails the amenity sync for that cell*. Every account would have to carry
   every gating tag explicitly, including the ones where the answer is "false".

## What this means right now

Reaching a private cell's Kubernetes API is a **solved, supported, customer-held
control** — not something to build around:

- `omnistrate-ctl deployment-cell update-kubeconfig <cell> --role cluster-admin`
  issues a kubeconfig pointed at an Omnistrate-side proxy
  (`https://manager.<cell>.<region>.aws.omnistrate.cloud:6666`) which reaches the
  private API. Verified on `hc-d75sozh69`: `kubectl auth can-i '*' '*'` returns
  yes and all nodes list. It is documented under
  [Remotely Access Cells](https://docs.omnistrate.com/operate-guides/deployment-cell-access/).
  (It is not listed by `omnistrate-ctl deployment-cell --help` on CLI v1.8.1,
  observed 2026-09-15, which is why it is easy to miss.)
- That path is gated by the account CloudFormation parameter
  `K8sDebugAccessEnabled`, described as controlling "BYOC PrivateLink Kubernetes
  debug access by mutating the management VPCE security group. true allows the
  regional K8S proxy port". So the customer decides, in their own stack, with a
  switch they can flip back.

The only code change needed is a host override in `providers.tf`, since the proxy
uses a different endpoint and client-certificate auth rather than
`aws eks get-token`. No bastion, no extra VPC endpoints, no EC2.

## What the evidence rules out

Checked 2026-09-15, verified rather than assumed. These remove most of the reasons
to migrate, but not all of them — see the conclusion.

**1. The mirror already handles arbitrary upstream registries — for artifacts
Omnistrate mirror.** Every image *Omnistrate themselves install* on the private
cell `hc-d75sozh69` resolves to
`493807289773.dkr.ecr.us-east-2.amazonaws.com/omnistrate/managed-artifacts/images/<original-registry>/<original-path>`,
covering `docker.io`, `ghcr.io`, `public.ecr.aws`, `registry.k8s.io` **and
`quay.io`** — including `quay.io/jetstack/cert-manager-*` and
`quay.io/prometheus-operator/*`, which are exactly the class of third-party
operator image this module installs. The path is preserved, and for the standing
managed set it carries no date stamp.

Read that as capability, not coverage. It shows the mirroring machinery can handle
any upstream registry. It does **not** mean our images are rewritten: only
artifacts declared through `helmChartConfiguration` are mirrored and granted a
pull policy, and nothing rewrites references at admission (see the webhook check
above). This module's own operator releases keep their original `ghcr.io`,
`docker.elastic.co` and `oci.external-secrets.io` references and fail to pull,
which is exactly what the run above observed. (A date-stamped
`.../images/pavo-private-link-validation-20260912/...` prefix also exists; that is
Maziar's one-off POC sync, not the standard shape. Do not write cosign globs
against it.)

### Two ECR paths exist, and one of them is dead

Worth naming so nobody follows the wrong one. `scripts/bootstrap-ecr-repos.sh`
creates repositories at

```
493807289773.dkr.ecr.us-east-1.amazonaws.com/pavo/<service>
oci://493807289773.dkr.ecr.us-east-1.amazonaws.com/pavo-charts/<chart>
```

Same account, **different region** from Omnistrate's mirror (`us-east-2`) and a
different prefix. It has never been run: there are zero ECR repositories in
`us-east-1` in that account, and nothing in the repo or the spec consumes that
path. It is scaffolding from the per-customer sync-job design that was superseded
on 10 Sep.

So do not treat it as a canonical target. Either delete it or repoint it once the
mirroring question below is answered, but populating it today produces
repositories nothing reads.

**2. That ECR is in our own account, but pushing to it is not sufficient.**
`493807289773` is Pavo AI — the account Omnistrate call our "provisioner account",
and we have admin on it. It is tempting to conclude we can simply push our own
repos. **We cannot, not on its own.** Cross-account pull is granted by a
**per-repository** policy that Omnistrate's tooling writes:

```json
{ "Sid": "OmnistrateManagedArtifactsPull388371826980",
  "Principal": { "AWS": "arn:aws:iam::388371826980:root" },
  "Action": ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", ...] }
```

There is **no registry-level policy** (`GetRegistryPolicy` returns
`RegistryPolicyNotFoundException`), so a repository we create carries no grant and
a customer cell cannot pull from it. Maziar's POC repos confirm this is a written
step rather than an inherited one: they carry a differently-named, hand-added
`PavoPrivateLinkValidationPull388371826980`.

**3. Reachability is already solved** by `K8sDebugAccessEnabled` plus
`update-kubeconfig`, above.

## Observed, not argued — 2026-09-15 on `hc-d75sozh69`

This module was applied to the private-only cell with `kubeconfig_path` pointing at
an `update-kubeconfig` kubeconfig.

Terraform reached the private API and **planned** cleanly: 43 to add, 0 to change,
0 to destroy. That is the reachability half proven, and it is a plan summary, not
an apply result.

The **apply** then split. Everything AWS-side succeeded: all eight `/pavo/**` SSM
parameters, the IAM boundary and ESO role, the provider-mirror bucket, both
gateway endpoints and the runner EKS access entry. The Kubernetes side did not.
Four Helm releases errored with `context deadline exceeded`, and the private CA
failed separately on a wrong cert-manager namespace (fixed elsewhere). The four
releases are left in Helm's `failed` state and are *not* in Terraform state, so a
re-apply hits `cannot re-use a name that is still in use` until they are
`helm uninstall`ed.

The operators failed to start because the *cluster* cannot reach the registries
their images live on. That is reachability rather than credentials or policy, and
the kubelet says so directly:

```
Failed to pull image "ghcr.io/stakater/reloader:v1.1.0": ... failed to resolve
image: failed to do request: Head "https://ghcr.io/v2/stakater/reloader/manifests/
v1.1.0": dial tcp 140.82.113.33:443: i/o timeout

Failed to pull image "docker.elastic.co/eck/eck-operator:3.4.0": ... dial tcp
34.56.16.77:443: i/o timeout

Failed to pull image "oci.external-secrets.io/external-secrets/external-secrets:
v0.10.4": ... dial tcp 34.213.189.139:443: i/o timeout
```

`dial tcp ... i/o timeout` is a TCP connect that never completed. An auth problem
would surface as `401 Unauthorized` or `403 Forbidden` from the registry, and an
admission or policy rejection would not reach the pull at all. The four affected
releases:

```
cosign-system    policy-controller-webhook   ErrImagePull
  ghcr.io/sigstore/policy-controller/policy-controller@sha256:0bcd60be…
elastic-system   elastic-operator-0          ImagePullBackOff
  docker.elastic.co/eck/eck-operator:3.4.0
reloader         reloader-reloader           ImagePullBackOff
  ghcr.io/stakater/reloader:v1.1.0
external-secrets external-secrets (×3)       ImagePullBackOff
  oci.external-secrets.io/external-secrets/external-secrets:v0.10.4
```

Two corrections to the earlier list fall out of this. The registries that matter are
the **image** registries, not the chart repositories: `docker.elastic.co` and
`oci.external-secrets.io` never appeared in the chart-repo list above. Enumerate
from running images, not from `helm_release.repository`.

Also confirmed while checking: there is **no image-rewriting mutating webhook** on
the cell. The only pod-mutating webhooks are `aws-load-balancer-webhook`,
`pod-identity-webhook` and `vpc-resource-mutating-webhook`. The ECR references on
Omnistrate's own workloads are baked in at chart-render time by their tooling, so
nothing rewrites ours at admission. That rules out the one mechanism that would
have made this problem disappear on its own.

## Conclusion: split the two problems, because only one is closed

**Reachability is closed.** `K8sDebugAccessEnabled` plus the documented
`update-kubeconfig` reaches a private cell's API, the switch is the customer's,
and the only code we owe is the `providers.tf` host override. **No amenity is
needed for this, and no question for Omnistrate.**

**Mirroring is not closed.** What decides whether an artifact reaches a customer
cell is not where it is pushed but whether **Omnistrate's tooling mirrored it**,
because that tooling is what writes the per-repository pull policy. Artifacts
declared through `helmChartConfiguration` get mirrored and granted. The seven
operators this module installs through its own `helm_release` resources are
declared to nobody, so they are never mirrored, never granted, and a BCNC cell
cannot pull them.

Two viable answers, and this needs a decision rather than a default:

| | What it costs |
| --- | --- |
| **Declare the seven to Omnistrate** (custom amenities are the declaration mechanism) so their tooling mirrors and grants them | The refactor, plus the three concerns above: `ClusterImagePolicy` becomes Omnistrate-applied, per-account tags carry per-cell flags, and a `disable` on a missing tag fails a whole cell's sync. We run zero custom amenities today, so it is a first as well as a change |
| **Create the repos ourselves and write the pull policy per customer** | No refactor, and we keep the admission policy. But it reintroduces per-customer registry work on every onboarding and every version bump, and offboarding becomes a policy statement we must remember to remove — which is most of what the PrivateLink design was meant to delete |

Either way **the question for Omnistrate is small and specific**, and is worth
asking before choosing: *can your mirroring be pointed at artifacts we declare
(custom amenities, or a supplied list), so it writes the same
`OmnistrateManagedArtifactsPull<account>` policy it writes for everything else?*
If yes, the first option shrinks to a declaration rather than a migration. If no,
the second is the only path and we should start building it now.
