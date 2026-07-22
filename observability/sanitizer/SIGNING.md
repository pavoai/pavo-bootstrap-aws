# pavo-alert-sanitizer — signed CI + admission enrollment

The sanitizer image runs inside the **customer VPC** — it is the metadata-only
alert-egress boundary (projects each raw Alertmanager alert down to a fixed
allowlist before anything leaves), deployed by the `pavo-observability` amenity.
It is therefore subject to the cell Sigstore `ClusterImagePolicy`: an
unsigned/unenrolled `ghcr.io/pavoai/*` image is **rejected at admission** and the
pod never starts on a strict/prod cell. Unlike `ci-security-tools` (CI-internal),
it warrants a signed, attested, enrolled build before any strict/prod tenant —
the same treatment as `zitadel-provisioner`.

> The awstest E2E used an ECR image applied directly via `kubectl`, which bypassed
> both the amenity and the ClusterImagePolicy. The production path (ghcr image via
> the amenity on a bootstrap-aws cell) hits the webhook — hence this pipeline.

## Naming (decoupled — read this before enrolling)

The manifest **key** is `alert-sanitizer`; the GHCR image is `pavo-alert-sanitizer`.
They are intentionally different:

- `central-ci` and `pavo-bootstrap-aws` derive the **signer identity** and the
  **policy name** from the manifest *key* → `cloud-build-alert-sanitizer@…` /
  `ClusterImagePolicy/pavo-alert-sanitizer`.
- The image glob is keyed off `ghcr_name` → `ghcr.io/pavoai/pavo-alert-sanitizer*`.

The key is kept ≤ 18 chars because the signer SA `account_id`
(`cloud-build-<key>`) must stay **under GCP's 30-char limit**.
`cloud-build-pavo-alert-sanitizer` (32) would fail `terraform apply`;
`cloud-build-alert-sanitizer` (27) is safe.

## Pieces

| # | Piece | State |
|---|-------|-------|
| 1 | `cloudbuild-omnistrate.yaml` — signed pipeline (build → lint-trivyignore → scan-image → push → capture-digest → CycloneDX SBOM + cosign-vuln → cosign keyless sign+attest → verify-signature) | **in this PR** |
| 1 | `scripts/trivy-with-cache.sh` + `.trivyignore.yaml` (already in-repo from the zitadel PR) | reused |
| 2 | Cloud Build trigger `alert-sanitizer-omnistrate` running **as** `cloud-build-alert-sanitizer@onboarding-455713` | operator (gcloud) |
| 3 | Digest handoff → hand-pin the image in `pavo-bootstrap-aws/observability/manifests/sanitizer.yaml.tftpl` via a reviewable PR (human gate on adopting a customer-VPC image) | manual |
| 4 | Signer SA (`central-ci`) + `ClusterImagePolicy` enrollment (`pavo-bootstrap-aws`) | operator (terraform apply) |

## Ordered rollout (audit-then-enforce — do NOT reorder)

Enforcement must come LAST, or the currently-pinned unsigned image is rejected
at admission on the next `self_hosted` apply. (Today the amenity is not yet
applied to any strict cell, so there is no live image to break — but keep the
order so this stays true once it is.)

1. **Mint the signer SA:** (`alert-sanitizer` is already in
   `spec/image-manifest.json` from this PR) `terraform apply` `central-ci/` →
   creates `cloud-build-alert-sanitizer@onboarding-455713` with the signer roles
   (OIDC token-creator self-binding, ghcr-pat access).
2. **Create the trigger** (runs as that SA):
   ```shell
   gcloud builds triggers create github \
     --project=onboarding-455713 \
     --name=alert-sanitizer-omnistrate \
     --repo-owner=pavoai --repo-name=pavo-terraform-templates \
     --branch-pattern='^main$' \
     --build-config=pavo-bootstrap-aws/observability/sanitizer/cloudbuild-omnistrate.yaml \
     --included-files='pavo-bootstrap-aws/observability/sanitizer/**,scripts/trivy-with-cache.sh,.trivyignore.yaml' \
     --service-account=projects/onboarding-455713/serviceAccounts/cloud-build-alert-sanitizer@onboarding-455713.iam.gserviceaccount.com
   ```
3. **First signed build:** trigger it (push or manual run). It builds (amd64),
   signs, attests, and `verify-signature` confirms the `cloud-build-alert-sanitizer`
   identity. It prints the `@sha256:` digest.
4. **Pin** that digest into `pavo-bootstrap-aws/observability/manifests/sanitizer.yaml.tftpl` (the
   container `image:`) via a reviewable PR.
5. **Audit:** confirm the pinned image verifies (sig + both attestations).
   `scripts/audit-cosign-pre-enforce.sh` covers it — its `alert-sanitizer` arm
   verifies the digest pinned in `pavo-bootstrap-aws/observability/manifests/sanitizer.yaml.tftpl`.
6. **Enforce (LAST):** (`alert-sanitizer` is already in
   `pavo-bootstrap-aws/image-manifest.json` from this PR) `terraform apply`
   `pavo-bootstrap-aws/` on each cell → creates
   `ClusterImagePolicy/pavo-alert-sanitizer`. From here, only the signed image
   is admitted.

## Enrollment approach — pattern A (same as zitadel-provisioner)

The manifest system is spec-service-shaped (entries carry a `yq_path` helm-value
path; `audit-cosign-pre-enforce.sh` reads tags from `image-values/<svc>/`). The
sanitizer has neither — no chart, pinned by digest in a raw KubernetesManifest.
We enroll it by fitting it into the manifest (reusing the sanctioned `central-ci`
/ `pavo-bootstrap-aws` `for_each` mechanism):

- `spec/image-manifest.json` + `pavo-bootstrap-aws/image-manifest.json`: an
  `alert-sanitizer` entry with `ghcr_name: pavo-alert-sanitizer` and an inert
  `yq_path: ""` (no helm value to point at).
- `scripts/audit-cosign-pre-enforce.sh`: an `alert-sanitizer` arm that verifies
  the **digest** pinned in `pavo-bootstrap-aws/observability/manifests/sanitizer.yaml.tftpl` instead of a
  tag from `image-values/`.

Applying `central-ci` mints `cloud-build-alert-sanitizer@onboarding-455713`;
applying `pavo-bootstrap-aws` (LAST, per the rollout above) auto-creates
`ClusterImagePolicy/pavo-alert-sanitizer`.
