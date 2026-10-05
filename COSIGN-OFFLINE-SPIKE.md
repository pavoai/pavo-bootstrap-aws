# Cosign offline verification — feasibility spike

**Status: spike / findings note. No ClusterImagePolicy change in this PR.**

## Problem

On a strict, zero-egress cell, image admission must NOT require egress to Sigstore.
Today `pavo-bootstrap-aws/main.tf` runs sigstore policy-controller (pinned
`0.10.6`) with **keyless** ClusterImagePolicies that reach the public good
instance at admission time:

- `fulcio.sigstore.dev` (cert identity), `rekor.sigstore.dev` (transparency log),
  and implicitly `tuf-repo-cdn.sigstore.dev` (the trust root).
- Each policy requires THREE artifacts: the image signature **plus** a CycloneDX
  SBOM attestation **and** a `cosign-vuln` attestation.

Images are signed keylessly by an out-of-repo **Cloud Build** pipeline, issuer
`accounts.google.com`. Each ClusterImagePolicy carries **two authorities**, so
there are **two accepted signer identities**:

| Authority | Subject |
| --- | --- |
| `pavo-cloud-build-<svc>` | `cloud-build-<svc>@<central_ci_project_id>.iam.gserviceaccount.com` |
| `pavo-cloud-build-shared-transition` | `cloud-build@<central_ci_project_id>.iam.gserviceaccount.com` |

`scripts/audit-cosign-pre-enforce.sh` tries the per-service identity and falls
back to the shared one. A follow-up that carries only the per-service identity
forward would reject valid transition-signed images. Every step below must be
run for **both identities × all three artifact types** (signature, SBOM
attestation, vuln attestation).

## Approach under test

policy-controller supports a **`TrustRoot`** CR with a *serialized / air-gapped*
mirror of a Sigstore trust root. With a TrustRoot pinned to the mirrored
**public-good** root, the controller can verify our existing keyless signatures
**without reaching fulcio/rekor/TUF at admission** — provided each artifact's
signature bundle already carries a **Rekor Signed Entry Timestamp (SET)**, which
cosign embeds in the `dev.sigstore.cosign/bundle` OCI annotation. Offline keyless
verify then checks the Fulcio cert chain plus the SET against the local trust
root; no network call.

**The SET is not a Merkle inclusion proof.** They are different guarantees and
the distinction matters for what we can claim to a security reviewer:

- **SET** — Rekor signed a statement that it accepted this entry at time T. It
  proves the log *saw* the entry. The legacy `dev.sigstore.cosign/bundle` format
  carries this and nothing stronger.
- **Inclusion proof** — a Merkle path proving the entry is *in* the published
  log, checkable against a signed tree head.

`cosign verify --offline` on a legacy bundle succeeds on the SET alone. So a
green result below establishes the SET guarantee, not log inclusion. Either
state the weaker guarantee when we describe this, or move to a bundle format and
verifier path that carries and checks `inclusionProof` and re-run the matrix.

If the bundles carry no SET at all, offline keyless is impossible and the options
narrow to keyful signing or a private Sigstore stack (see Outcomes).

## Test procedure (run on awstest)

### Pin the cosign version first

Fix the cosign binary to one version for the whole run rather than using
whatever is on PATH, and record it in the results next to the chart version
(`policy_controller_chart_version` defaults to `0.10.6`) and the app version the
chart actually deploys.

This is not housekeeping. cosign v2 stores signatures and attestations as
tag-based artifacts (`sha256-<digest>.sig` / `.att`), and **cosign v3, released
October 2025, defaults to OCI 1.1 Referrers instead**. A v3 binary would push
artifacts the 0.10.6 controller may not discover, so the run would be testing a
different storage scheme from the one admission uses and a pass would mean
nothing. Confirm which version the Cloud Build pipeline signs with and match it.

### Use a separate fixture per outcome

cosign keys artifacts to the **image digest**: the location of a signature is
computed by encoding the object's digest into a tag name. So one digest carries
one set of artifacts, and reusing a single digest across the cases would leave
the good-case signature and attestations discoverable for the rejection cases,
which would then pass without proving anything.

Build **three distinct, digest-qualified fixtures**
(`ghcr.io/pavoai/<svc>@sha256:<digest>`), one per outcome:

| Fixture | Artifacts present |
| --- | --- |
| good | signature + SBOM attestation + vuln attestation, correct signer |
| wrong-signer | signature from an identity outside both accepted authorities |
| missing-attestation | valid signature, one or both attestations absent |

Digest-qualified throughout, per `SECURITY.md` — a tag repoint mid-run changes
the artifacts under test and the result stops being reproducible. If three
fixtures are genuinely impractical, document the exact artifact deletion and
reset steps between cases instead, and show the registry is clean before each.

1. **Confirm the bundles carry a SET** for all three artifacts, for **both**
   signer identities:
   - `cosign verify --offline --certificate-identity <identity> --certificate-oidc-issuer https://accounts.google.com ghcr.io/pavoai/<svc>@sha256:<digest>`
     succeeds → the signature bundle carries a SET (not an inclusion proof; see above).
   - Repeat for both attestations (`cosign verify-attestation --offline --type cyclonedx …` and `--type vuln …`).
2. **Build a mirrored TrustRoot** (serialized public-good root) and apply it, then
   point a **test copy** of the ClusterImagePolicy at it — never the live policy.
   Set `trustRootRef` on **both `keyless` and `ctlog`, on both authorities** — four
   fields. Omitting `ctlog.trustRootRef` leaves CTLog verification on the Public
   Good instance, so admission still reaches `rekor.sigstore.dev` and the spike
   proves nothing. Both authorities today carry `keyless.url = https://fulcio.sigstore.dev`
   and `ctlog.url = https://rekor.sigstore.dev`; grep for those to find all four.
3. **Block egress at the network layer** to `fulcio.sigstore.dev`,
   `rekor.sigstore.dev` and `tuf-repo-cdn.sigstore.dev`, keeping **GHCR reachable**.
   Use the strict-cell NetworkPolicy in `terraform-omnistrate-aws/network_policies.tf`.
   Do NOT use a hosts-file block: it only intercepts name resolution in the pod
   that has it, so a controller holding a cached IP or resolving elsewhere still
   egresses, and the test passes while the real strict cell would fail.
4. **Assert** end to end, for both signer identities:
   - a known-good image is **admitted** with all three artifacts verified offline;
   - a wrong-signer image and a missing-attestation image are **rejected**;
   - no connection to any Sigstore endpoint was attempted during either.

## Step 1 results — 2026-09-15: SET IS PRESENT, offline verify works

Step 1 only. Steps 2–4 (mirrored TrustRoot, test policy, egress block, admission
assertions) have **not** been run.

Method note: the bundle annotations were read straight off the registry with
`crane manifest` rather than inferred from a `cosign verify` exit code. Local
cosign is **v3.0.6**, and this document warns that a v3 binary exercises OCI 1.1
Referrers rather than the tag-based scheme admission uses — so a v3 pass on its
own would not have been evidence. Reading the annotation is format-independent.

Fixture: `ghcr.io/pavoai/intern@sha256:66b384d00ef91bf466403addf640fc5205026d2a93ab6ab0e2698f33950f7228`
(the `temporal_codec_image` pinned on awstest).

**Storage scheme is tag-based** (`sha256-<digest>.sig` / `.att`), i.e. cosign v2
semantics, which policy-controller 0.10.6 discovers. The v3 Referrers hazard does
not apply to what the pipeline currently produces.

Two independent evidence sources, kept apart deliberately. The bundle column is
read from the registry with `crane manifest`; the verify column is a cosign exit
code. Both were actually run; neither is inferred from the other.

| Artifact | Bundle evidence (`crane manifest`) | Rekor logIndex | Cosign command run | Result |
| --- | --- | --- | --- | --- |
| signature | `SignedEntryTimestamp` present | 2602195414 | `cosign verify --offline` | pass |
| CycloneDX SBOM attestation | `SignedEntryTimestamp` present | 2602196781 | `cosign verify-attestation --offline --type cyclonedx` | pass |
| cosign-vuln attestation | `SignedEntryTimestamp` present | 2602197921 | `cosign verify-attestation --offline --type vuln` | pass |

All three run against the per-service identity
`cloud-build-intern@onboarding-455713.iam.gserviceaccount.com` with
`--certificate-oidc-issuer https://accounts.google.com`.

Two things worth recording beyond the pass/fail:

- **`inclusionProof` is absent from every bundle.** Exactly as this document
  predicted: the legacy `dev.sigstore.cosign/bundle` format carries the SET and
  nothing stronger. So the guarantee we can claim is "Rekor signed that it
  accepted this entry at time T", **not** log inclusion. State the weaker
  guarantee to security reviewers; do not describe it as transparency-log
  inclusion.
- **The shared-transition identity does not match this image.** Verifying as
  `cloud-build@onboarding-455713...` fails with "none of the expected identities
  matched ... got subjects [cloud-build-intern@...]". That is the correct result
  and it means `intern` has already migrated to its per-service signer. It is
  **not** evidence that the transition authority can be dropped — that needs the
  same check across every service in `image-manifest.json`.

**Consequence for the decision, scoped to what was tested.** One image, one
signer. The "SET absent" branch is ruled out **for the `intern` fixture**, which
is enough to say the pipeline is capable of producing offline-verifiable bundles
and therefore enough to stop treating keyful signing as the likely answer. It is
**not** enough to conclude that every image in `image-manifest.json` carries a
SET.

That distinction has a real failure mode: a `TrustRoot` rollout verifies every
admitted image, so a single service whose bundles lack a SET would be rejected at
admission after the switch, not before. **Complete the matrix — every service in
`image-manifest.json` × both signer identities × all three artifact types —
before wiring `trustRootRef`.** `scripts/audit-cosign-pre-enforce.sh` already
walks the image list and is the natural place to add the check.

One conclusion does generalise safely: Omnistrate's pending artifact re-signing
does not gate us either way, because we sign and push our own images and cosign
stores the signature beside the image in the same repository.

## Outcomes and recommendation

- **If the SET is present (expected):** ship a `TrustRoot` (mirrored public-good
  root) for strict cells and point the strict ClusterImagePolicy at it. Strict
  admission then needs zero Sigstore egress. Trade-off: **we own rotation** of the
  mirrored root (the serialized/air-gapped mode does not auto-refresh TUF).
- **If the SET is absent:** offline keyless is not possible. Prefer **keyful
  signing** — have the Cloud Build pipeline additionally sign with a static cosign
  key and add a keyful authority (`key.data`/`key.kms`) to the strict policy; this
  removes fulcio/rekor entirely. A private in-VPC Sigstore (fulcio/rekor) stack is
  the heavier fallback and is not recommended.

**Recommendation:** proceed with the TrustRoot approach — it is the smallest change
and modern cosign embeds the bundle, so it is very likely feasible. Validate on
awstest first; only then wire a strict `trustRootRef` (a follow-up PR, gated on
`network_posture=strict`). Until then, strict cells keep `image_policy_mode=enforce`
and the fulcio/rekor admission egress remains the one open cosign item, tracked in
the BCNC egress ledger.
