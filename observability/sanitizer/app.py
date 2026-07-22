#!/usr/bin/env python3
"""In-VPC alert sanitizer — the metadata-only egress boundary.

Alertmanager delivers a raw webhook batch (full labels, annotations,
generatorURL = the PromQL / index names, metric values, ...) to this service
over the in-cluster network. This service projects each alert down to a fixed
9-key allowlist and forwards ONLY that to DESTINATION_URL. Nothing else — no
extra labels, no annotations, no generatorURL, no metric values — ever leaves.

Deployed as pavo-alert-sanitizer (the Pavo metadata leg, best_effort_ack). The
same image also serves the customer leg only when the customer chooses sanitized
external delivery (retry_via_alertmanager); the default customer leg is raw and
goes straight from Alertmanager via url_file, no sanitizer.

Stdlib only — no third-party deps, so the image is tiny and air-gap friendly.

Security rules enforced here:
  * The output is EXACTLY the 9 allowlisted keys. Missing inputs -> "unknown";
    unexpected keys are never echoed.
  * DESTINATION_URL comes from the environment (injected from a k8s Secret) and
    is NEVER logged.
  * The raw request body is NEVER logged. Logs carry only: request-id, alert
    count, HTTP status, and the sanitized alert *names*.
"""
import json
import logging
import os
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ---- config (from env; DESTINATION_URL is Secret-injected, never a literal) ----
DESTINATION_URL = os.environ.get("DESTINATION_URL", "")
DELIVERY_POLICY = os.environ.get("DELIVERY_POLICY", "best_effort_ack")
CUSTOMER_NAME = os.environ.get("CUSTOMER_NAME", "unknown")
DEPLOYMENT_ID = os.environ.get("DEPLOYMENT_ID", "unknown")
INSTANCE_ID = os.environ.get("INSTANCE_ID", "unknown")
AWS_REGION = os.environ.get("AWS_REGION", "unknown")
PORT = int(os.environ.get("PORT", "8080"))
FORWARD_TIMEOUT_SECONDS = float(os.environ.get("FORWARD_TIMEOUT_SECONDS", "5"))
MAX_BODY_BYTES = int(os.environ.get("MAX_BODY_BYTES", str(1 << 20)))  # 1 MiB cap

_VALID_POLICIES = ("best_effort_ack", "retry_via_alertmanager")

# The ONLY keys that ever leave. Do not extend without a security review.
ALLOWED_KEYS = (
    "customer_name",
    "deployment_id",
    "instance_id",
    "region",
    "alertname",
    "severity",
    "status",
    "startsAt",
    "endsAt",
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("sanitizer")


def _alerts_of(payload):
    """The alert list from a batch, or [] for any malformed shape (never raises)."""
    if not isinstance(payload, dict):
        return []
    alerts = payload.get("alerts", [])
    return alerts if isinstance(alerts, list) else []


def _alertname(a):
    """alertname for logging; 'unknown' for any malformed alert (never raises)."""
    if isinstance(a, dict) and isinstance(a.get("labels"), dict):
        return a["labels"].get("alertname", "unknown")
    return "unknown"


def sanitize(payload):
    """Project a raw Alertmanager batch to a list of 9-key metadata events.

    Defensive against malformed input (null alerts, non-dict labels, non-list
    alerts): such entries are skipped rather than crashing the handler.
    """
    out = []
    for a in _alerts_of(payload):
        if not isinstance(a, dict):
            continue
        labels = a.get("labels")
        if not isinstance(labels, dict):
            labels = {}
        out.append(
            {
                "customer_name": CUSTOMER_NAME,
                "deployment_id": DEPLOYMENT_ID,
                "instance_id": INSTANCE_ID,
                "region": AWS_REGION,
                "alertname": labels.get("alertname", "unknown"),
                "severity": labels.get("severity", "unknown"),
                "status": a.get("status", "unknown"),
                "startsAt": a.get("startsAt", "unknown"),
                "endsAt": a.get("endsAt", "unknown"),
            }
        )
    return out


def _forward_once(body):
    req = urllib.request.Request(
        DESTINATION_URL,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=FORWARD_TIMEOUT_SECONDS) as resp:
        return 200 <= resp.status < 300


def forward(events):
    """Send the sanitized batch to DESTINATION_URL. Single attempt.

    Alertmanager already retries the primary (customer) leg on non-2xx, so an
    in-process retry loop here would just duplicate that resilience and block the
    request thread. Returns True on success; never raises; never logs URL/body.
    """
    body = json.dumps({"alerts": events}).encode("utf-8")
    try:
        return _forward_once(body)
    except (urllib.error.URLError, OSError, ValueError):
        return False  # swallow detail — must not log destination/body


class Handler(BaseHTTPRequestHandler):
    timeout = 10  # socket-level: bounds a slow/stalled read from tying up a thread

    # Silence the default handler logging (it prints request lines / paths).
    def log_message(self, *args):
        pass

    def _send(self, code):
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        if self.path == "/healthz":
            self._send(200)
        else:
            self._send(404)

    def do_POST(self):
        req_id = self.headers.get("X-Request-Id", "-")
        if self.path != "/alert":
            self._send(404)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length < 0 or length > MAX_BODY_BYTES:
                # negative (read(-1) would read until close) or oversized -> ack + drop
                log.warning("req=%s bad_request content_length=%d", req_id, length)
                self._send(200)
                return
            raw = self.rfile.read(length) if length else b"{}"
            payload = json.loads(raw or b"{}")
        except (ValueError, TypeError):
            # A permanently-malformed body will never parse — ack (2xx) so
            # Alertmanager drops it instead of hot-looping on the same bad body.
            log.warning("req=%s bad_request malformed_json", req_id)
            self._send(200)
            return

        events = sanitize(payload)
        names = [_alertname(a) for a in _alerts_of(payload)]
        ok = forward(events) if events else True

        if ok:
            log.info("req=%s count=%d status=delivered alerts=%s", req_id, len(events), names)
            self._send(200)
            return

        # Delivery failed — behaviour depends on the policy.
        if DELIVERY_POLICY == "retry_via_alertmanager":
            # Customer leg is PRIMARY: return non-2xx so Alertmanager retries.
            log.warning("req=%s count=%d status=delivery_failed policy=retry alerts=%s",
                        req_id, len(events), names)
            self._send(502)
        else:
            # Pavo leg is best-effort: ack anyway, log the sanitized failure.
            log.warning("req=%s count=%d status=delivery_failed policy=best_effort alerts=%s",
                        req_id, len(events), names)
            self._send(200)


def main():
    if DELIVERY_POLICY not in _VALID_POLICIES:
        log.error("invalid DELIVERY_POLICY=%r (want one of %s)", DELIVERY_POLICY, _VALID_POLICIES)
        sys.exit(2)
    if not DESTINATION_URL:
        log.error("DESTINATION_URL is empty (must be injected from a Secret)")
        sys.exit(2)
    log.info("sanitizer up port=%d policy=%s region=%s", PORT, DELIVERY_POLICY, AWS_REGION)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
