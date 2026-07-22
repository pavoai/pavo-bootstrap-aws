"""Security-boundary tests for the alert sanitizer.

The critical invariant: every emitted event has EXACTLY the 9 allowlisted keys —
strict set-equality, not a subset — so no raw label, annotation, generatorURL,
or metric value can ever leak through, regardless of the input shape.
"""
import app


ALLOWED = set(app.ALLOWED_KEYS)


def test_output_is_exactly_the_8_allowlisted_keys():
    # A hostile input carrying secrets in every raw field we must drop.
    payload = {
        "alerts": [
            {
                "status": "firing",
                "labels": {
                    "alertname": "ESClusterRed",
                    "severity": "critical",
                    "cluster": "phi-cluster-name-LEAK",
                    "namespace": "instance-secret",
                },
                "annotations": {"summary": "raw PHI-ish text LEAK"},
                "generatorURL": "http://prom/graph?g0.expr=secret_index_names_LEAK",
                "fingerprint": "deadbeef",
                "startsAt": "2026-07-13T00:00:00Z",
                "endsAt": "0001-01-01T00:00:00Z",
            }
        ]
    }
    out = app.sanitize(payload)
    assert len(out) == 1
    assert set(out[0].keys()) == ALLOWED  # strict equality
    # None of the forbidden raw content survived anywhere in the output.
    blob = repr(out)
    for forbidden in ("LEAK", "generatorURL", "fingerprint", "annotations", "cluster", "namespace"):
        assert forbidden not in blob


def test_missing_labels_become_unknown_not_echoed():
    out = app.sanitize({"alerts": [{"status": "resolved"}]})
    assert set(out[0].keys()) == ALLOWED
    assert out[0]["alertname"] == "unknown"
    assert out[0]["severity"] == "unknown"
    assert out[0]["status"] == "resolved"


def test_multi_alert_batch_projects_each():
    payload = {"alerts": [
        {"status": "firing", "labels": {"alertname": "A", "severity": "warning"}},
        {"status": "resolved", "labels": {"alertname": "B", "severity": "critical"}},
    ]}
    out = app.sanitize(payload)
    assert [e["alertname"] for e in out] == ["A", "B"]
    assert all(set(e.keys()) == ALLOWED for e in out)


def test_empty_batch_yields_nothing():
    assert app.sanitize({"alerts": []}) == []
    assert app.sanitize({}) == []


def test_malformed_alerts_do_not_crash():
    # null/non-dict alerts and non-list `alerts` are skipped; alerts with
    # non-dict labels are retained with fields normalized to "unknown". Never raises.
    assert app.sanitize({"alerts": [None]}) == []
    assert app.sanitize({"alerts": [{"labels": []}]})[0]["alertname"] == "unknown"
    assert app.sanitize({"alerts": "not-a-list"}) == []
    assert app.sanitize(None) == []
    out = app.sanitize({"alerts": [None, {"labels": {"alertname": "A", "severity": "warning"}}]})
    assert len(out) == 1 and out[0]["alertname"] == "A"
    assert set(out[0].keys()) == ALLOWED

