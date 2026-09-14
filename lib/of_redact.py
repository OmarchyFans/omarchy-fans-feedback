#!/usr/bin/env python3
"""Hide secrets before Feedback records any text.

  of_redact.py text               stdin -> redacted text on stdout, findings (JSON) on stderr

Passwords and secret values become ********. Keys, tokens and card or account numbers keep
only their first and last four characters with the middle cut out (ghp_…9f3e). Plain
identifiers (UUIDs, long hex ids, long digit runs) are shortened the same way but do not ask
the user to rotate anything. Every finding carries only the masked form, never the value.

redact() is idempotent: masked output never matches a rule again.
"""
import sys

sys.dont_write_bytecode = True

import json  # noqa: E402
import math  # noqa: E402
import re  # noqa: E402

STARS = "********"
COMPACT = {"card number", "bank account (IBAN)"}  # masked without their spaces
ELLIPSIS = "…"

# JSON keys whose string values are structure, not text a person or app typed.
STRUCTURAL_KEYS = {"class", "initialClass", "address", "namespace", "type", "event", "kind", "status",
                   "source", "monitor", "combo", "key", "mods", "path", "mime", "repo", "id", "workspace"}


def mask(value):
    v = value.strip()
    if len(v) <= 8:
        return STARS
    keep = 4 if len(v) >= 16 else 2
    return v[:keep] + ELLIPSIS + v[-keep:]


def luhn(value):
    digits = [int(c) for c in value if c.isdigit()]
    if not 13 <= len(digits) <= 19 or len(set(digits)) == 1:
        return False
    total = 0
    for i, d in enumerate(reversed(digits)):
        if i % 2:
            d = d * 2 - 9 if d > 4 else d * 2
        total += d
    return total % 10 == 0


def entropy(value):
    counts = {}
    for c in value:
        counts[c] = counts.get(c, 0) + 1
    return -sum(n / len(value) * math.log2(n / len(value)) for n in counts.values())


def random_token(value):
    """Long, mixed-alphabet, high-entropy strings: probably a key nobody would type."""
    counts = [len(re.findall(p, value)) for p in (r"[a-z]", r"[A-Z]", r"[0-9]")]
    words = [seg for seg in re.split(r"[-_]", value) if re.fullmatch(r"[a-z]{3,}", seg)]
    return min(counts) >= 2 and entropy(value) >= 4.0 and len(words) < 2   # "my-branch-name-2026" is a name


def digits_only(value):
    return re.sub(r"\D", "", value)


def timestamp(value):
    """Unix seconds or milliseconds between 2001 and 2100: not an account number."""
    n = int(value)
    return (len(value) == 10 and 978_307_200 <= n <= 4_102_444_800) or \
        (len(value) == 13 and 978_307_200_000 <= n <= 4_102_444_800_000)


# (label, pattern, group, style, alert, check). Earlier rules win where matches overlap.
# style "stars" hides the whole value; "truncate" keeps the ends. alert = ask the user to rotate.
_V = r"[A-Za-z0-9._~+/=-]"
RULES = [
    ("private key", re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|$)"),
     0, "stars", True, None),
    ("password in a URL", re.compile(r"\b[a-z][a-z0-9+.-]*://[^/\s:@]+:([^/\s@]+)@", re.I), 1, "stars", True, None),
    # "--password=x" / "password=x": one token. "Password: two words": up to a separator or the end.
    ("password", re.compile(r"(?i)(?<![A-Za-z0-9])(?:--?)?(?:pass(?:word|wd|phrase)?|pwd|passcode|pin)=[\"']?([^\s\"'&,;]{3,})"),
     1, "stars", True, None),
    ("password", re.compile(r"(?i)(?<![A-Za-z0-9])(?:pass(?:word|wd|phrase)?|pwd|passcode|pin)\s*:\s*[\"']?([^\n|;,\"']{3,}?)(?=\s+[-—|·]\s|[\n|;,\"']|\s*$)"),
     1, "stars", True, None),
    ("GitHub token", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{30,255}|github_pat_[A-Za-z0-9_]{40,255})\b"), 0, "truncate", True, None),
    ("GitLab token", re.compile(r"\bglpat-[A-Za-z0-9_-]{20,}\b"), 0, "truncate", True, None),
    ("Anthropic key", re.compile(r"\bsk-ant-[A-Za-z0-9_-]{20,}"), 0, "truncate", True, None),
    ("OpenAI key", re.compile(r"\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{20,}"), 0, "truncate", True, None),
    ("AWS access key", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"), 0, "truncate", True, None),
    ("Slack token", re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}"), 0, "truncate", True, None),
    ("Stripe key", re.compile(r"\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}"), 0, "truncate", True, None),
    ("Google API key", re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b"), 0, "truncate", True, None),
    ("Hugging Face token", re.compile(r"\bhf_[A-Za-z0-9]{30,}\b"), 0, "truncate", True, None),
    ("npm token", re.compile(r"\bnpm_[A-Za-z0-9]{36}\b"), 0, "truncate", True, None),
    ("JSON web token", re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"), 0, "truncate", True, None),
    ("secret", re.compile(r"(?i)(?<![A-Za-z0-9])(?:--?)?(?:api[_-]?key|apikey|secret(?:[_-]?key)?|client[_-]?secret|"
                          r"access[_-]?token|auth[_-]?token|refresh[_-]?token|token|private[_-]?key)\s*[:=]\s*[\"']?(" + _V + r"{8,})"),
     1, "truncate", True, None),
    ("bearer token", re.compile(r"(?i)\b(?:bearer|authorization:\s*(?:bearer|token|basic))\s+(" + _V + r"{12,})"), 1, "truncate", True, None),
    ("secret in a URL", re.compile(r"(?i)[?&](?:access_token|id_token|token|api_key|apikey|key|sig|signature|secret|password|auth|code)=([^&#\s]{6,})"),
     1, "truncate", True, None),
    ("card number", re.compile(r"(?<![\d.])\d(?:[ -]?\d){12,18}(?![\d.])"), 0, "truncate", True, luhn),
    ("bank account (IBAN)", re.compile(r"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){3,7}(?: ?[A-Z0-9]{1,3})?\b"), 0, "truncate", True,
     lambda v: len(v.replace(" ", "")) >= 15),
    ("ID number", re.compile(r"(?<![\d-])\d{3}-\d{2}-\d{4}(?![\d-])"), 0, "truncate", True, None),
    # No "/" and no ".": paths and file names are not keys.
    ("possible token", re.compile(r"(?<![A-Za-z0-9_+/=.-])[A-Za-z0-9_+=-]{32,}(?![A-Za-z0-9_+/=.-])"), 0, "truncate", True, random_token),
    ("identifier", re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"), 0, "truncate", False, None),
    ("identifier", re.compile(r"\b[0-9a-f]{32,}\b"), 0, "truncate", False, None),
    ("account or ID number", re.compile(r"(?<![\d.])\d{9,18}(?![\d.])"), 0, "truncate", False, lambda v: not timestamp(v)),
]


def scan(text):
    """Spans (start, end, label, style, alert) of sensitive parts of text, non-overlapping, in order."""
    if not isinstance(text, str) or not text:
        return []
    spans = []
    for label, rx, group, style, alert, check in RULES:
        for m in rx.finditer(text):
            s, e = m.span(group)
            if s < 0 or e <= s:
                continue
            value = text[s:e]
            if ELLIPSIS in value or value == STARS:
                continue
            if check and not check(value):
                continue
            if any(s < b and a < e for a, b, *_ in spans):
                continue
            spans.append((s, e, label, style, alert))
    return sorted(spans)


def redact(text):
    """(clean text, findings). Findings: [{"kind", "masked", "alert"}], deduplicated."""
    spans = scan(text)
    if not spans:
        return text, []
    out, pos, findings = [], 0, []
    for s, e, label, style, alert in spans:
        value = text[s:e]
        if label in COMPACT:
            value = re.sub(r"[ -]", "", value)
        masked = STARS if style == "stars" else mask(value)
        out.append(text[pos:s])
        out.append(masked)
        pos = e
        f = {"kind": label, "masked": masked, "alert": alert}
        if f not in findings:
            findings.append(f)
    out.append(text[pos:])
    return "".join(out), findings


def redact_obj(obj, findings=None):
    """Redact every free-text string inside a JSON value; returns (clean, findings)."""
    findings = [] if findings is None else findings

    def walk(v, key=None):
        if isinstance(v, str):
            if key in STRUCTURAL_KEYS:
                return v
            clean, found = redact(v)
            for f in found:
                if f not in findings:
                    findings.append(f)
            return clean
        if isinstance(v, list):
            return [walk(x, key) for x in v]
        if isinstance(v, dict):
            return {k: walk(x, k) for k, x in v.items()}
        return v

    return walk(obj), findings


def main(argv):
    if argv[:1] != ["text"]:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    clean, findings = redact(sys.stdin.read())
    sys.stdout.write(clean)
    print(json.dumps(findings), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
