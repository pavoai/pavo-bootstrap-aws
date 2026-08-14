# SES email onboarding (per AWS account)

AWS instances send transactional email through Amazon SES, reached over a SES
VPC interface endpoint so the call never leaves the customer VPC. Terraform
provisions the SES sending identity, the VPC endpoint, and the `ses:SendEmail`
grant automatically when `email_enabled = true`. Two steps cannot be automated
by terraform and must be done once per AWS account before go-live.

## 1. Publish the DKIM records

`terraform-omnistrate-aws` creates a SES v2 domain identity for the instance's
`app_domain` with Easy DKIM and exposes the tokens as the `ses_dkim_tokens`
output. Publish three CNAME records on the sending domain:

```text
<token>._domainkey.<app_domain>   CNAME   <token>.dkim.amazonses.com
```

- **BYOC** (customer AWS account, customer domain): the customer publishes these
  on their DNS.
- **Multi-tenant** (`app.pavoai.com`, Pavo's account): Pavo publishes them on
  `pavoai.com`.

SES will not send from an unverified domain, so this must land before the first
send.

## 2. Move the account out of the SES sandbox

A fresh SES account starts in the sandbox: it can only send to verified
addresses and is capped (~200/day). Open an AWS support request ("Request
production access" in the SES console) for the account and region. Until this is
granted, `SendEmail` on an unverified recipient returns `MessageRejected`, which
the app surfaces as a 5xx (invitations) or a failed OTP send.

## 3. Strict / air-gapped instances: turn email off

There is no first-party private-email path on GCP, and a truly air-gapped AWS
instance may not want SES delivery either. For those, set:

```hcl
email_enabled = false
```

This wires no email backend, returns 403 from the OTP endpoints, and makes
invitation flows return a copyable `invitation_link` in the API response instead
of sending mail. Applies to BCNC (AWS, air-gapped) and any GCP-strict cell.

Until the `network_posture` flag exists to enforce it at plan time, this is an
operational rule: verify a strict instance's plan shows no SES identity /
endpoint (AWS) and that `email_enabled=false` (GCP) before go-live.

## Migration note

Instances that previously set `enable_email_login = false` (self-hosted
IdP-only) map to `email_enabled = false`. Cloud instances that relied on the old
"cloud is always on" behavior need no change: `email_enabled` defaults to `true`.
