#!/usr/bin/env python3
"""Local LLM helper: generate a PrometheusRule or release notes via an OpenAI-compatible
llama.cpp server, then validate the result. The model is never trusted without checks.

Usage:
  llm_gen.py rule  "описание алерта" [--out FILE]
  llm_gen.py notes [--range origin/main~5..HEAD] [--out FILE]
  llm_gen.py explain [LOG]   (объяснение провала canary/отката)
  llm_gen.py validate-rule FILE
Env: LLM_URL (default http://127.0.0.1:8090), LLM_MODEL (optional request label), LLM_LOG (jsonl log).
The journal records the model from GET /v1/models, else the completion field, else LLM_MODEL, else llm/models.tsv.
Only Python stdlib + PyYAML; promtool is run through Docker if available (PROMTOOL_IMAGE).
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROMPTS = os.path.join(ROOT, "llm", "prompts")
WHITELIST_PATH = os.path.join(ROOT, "llm", "metrics_whitelist.yaml")
URL = os.environ.get("LLM_URL", "http://127.0.0.1:8090")
# Config label. Empty unless the operator set LLM_MODEL (Makefile passes LLM_NAME).
# The log does not use this when the server names the loaded model.
MODEL = os.environ.get("LLM_MODEL", "").strip()
LOG = os.environ.get("LLM_LOG", os.path.join(ROOT, "llm", "out", "runs.jsonl"))
PROMTOOL_IMAGE = os.environ.get("PROMTOOL_IMAGE", "prom/prometheus:v2.54.1")
SEED = 42
DURATION = re.compile(r"^\d+(ms|s|m|h|d)$")
ALERT = re.compile(r"^[A-Z][A-Za-z0-9]+$")
COUNTER_FUNC = re.compile(r"\b(rate|irate|increase)\s*\(\s*(\w+)")
EQ_REGEX = re.compile(r'\b\w+\s*=\s*"[^"]*(\.\*|\.\+|\[|\|)[^"]*"')
NAME = re.compile(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")
# Aggregation modifiers, not metric names. Dropped before selector scan.
_GROUP_CLAUSE = re.compile(r"\b(?:by|without|on|ignoring|group_left|group_right)\s*\([^)]*\)")
# (?<![\w.]) so the unit in a duration (5m, 15m) is not a metric name.
_SELECTOR = re.compile(
    r"(?<![\w.])(?P<name>[A-Za-z_:][A-Za-z0-9_:]*)(?:\s*\{(?P<labels>[^{}]*)\})?"
)
_LABEL = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)\s*(?:=~|!~|!=|=)")
_STRING = re.compile(r'"(?:\\.|[^"\\])*"')
# PromQL functions and keywords. An identifier followed by "(" is also treated as a call.
_KEYWORDS = frozenset("""
sum min max avg count stddev stdvar topk bottomk quantile group
and or unless bool offset inf nan
rate irate increase delta idelta deriv predict_linear
histogram_quantile histogram_count histogram_sum histogram_fraction histogram_avg
abs ceil floor round sqrt exp ln log2 log10 sgn clamp clamp_min clamp_max
absent absent_over_time changes resets vector scalar time timestamp
sort sort_desc
avg_over_time min_over_time max_over_time sum_over_time count_over_time
quantile_over_time stddev_over_time stdvar_over_time last_over_time present_over_time
day_of_month day_of_week day_of_year days_in_month hour minute month year pi
""".split())


def load_whitelist(path=None):
    path = path or WHITELIST_PATH
    with open(path, encoding="utf-8") as f:
        data = yaml.safe_load(f)
    metrics = data.get("metrics") if isinstance(data, dict) else None
    if not isinstance(metrics, dict) or not metrics:
        raise SystemExit(f"metrics whitelist: expected non-empty mapping 'metrics' in {path}")
    return metrics


WHITELIST = load_whitelist()


def format_known_metrics(whitelist=None):
    """One line for the user prompt: name{label,...} for every whitelisted series."""
    parts = []
    for name, spec in (whitelist or WHITELIST).items():
        labels = (spec or {}).get("labels") or []
        parts.append(f"{name}{{{','.join(labels)}}}" if labels else name)
    return ", ".join(parts)


KNOWN_METRICS = format_known_metrics()


def _blank_strings(expr):
    return _STRING.sub(lambda m: '"' + (" " * (len(m.group(0)) - 2)) + '"', expr)


def selectors(expr):
    """Metric selectors as (name, [label names]). Ignores functions and by/on clauses."""
    text = _blank_strings(_GROUP_CLAUSE.sub(" ", expr))
    found = []
    for m in _SELECTOR.finditer(text):
        name = m.group("name")
        labels_raw = m.group("labels")
        rest = text[m.end():].lstrip()
        if labels_raw is None and rest.startswith("("):
            continue
        if name in _KEYWORDS:
            continue
        labels = _LABEL.findall(labels_raw) if labels_raw is not None else []
        found.append((name, labels))
    return found


def histogram_quantile_spans(expr):
    """Second argument of each histogram_quantile(...) call."""
    spans = []
    for m in re.finditer(r"\bhistogram_quantile\s*\(", expr):
        i = m.end()
        depth = 1
        while i < len(expr) and depth:
            if expr[i] == "(":
                depth += 1
            elif expr[i] == ")":
                depth -= 1
            i += 1
        inner = expr[m.end():i - 1] if depth == 0 else expr[m.end():]
        depth = 0
        comma = None
        for j, ch in enumerate(inner):
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
            elif ch == "," and depth == 0:
                comma = j
                break
        spans.append("" if comma is None else inner[comma + 1:])
    return spans


def check_metric_whitelist(alert, expr, whitelist=None):
    """Unknown metric or label, and histogram_quantile not on a *_bucket series."""
    whitelist = whitelist or WHITELIST
    errs = []
    seen = set()
    for name, labels in selectors(expr):
        spec = whitelist.get(name)
        if spec is None:
            key = ("m", name)
            if key not in seen:
                seen.add(key)
                errs.append(f"{alert}: неизвестная метрика {name} (нет в llm/metrics_whitelist.yaml)")
            continue
        allowed = set(spec.get("labels") or [])
        for lab in labels:
            key = ("l", name, lab)
            if lab not in allowed and key not in seen:
                seen.add(key)
                errs.append(
                    f"{alert}: у метрики {name} нет метки {lab} (нет в llm/metrics_whitelist.yaml)"
                )
    for span in histogram_quantile_spans(expr):
        names = [n for n, _ in selectors(span)]
        bad = [n for n in names if not n.endswith("_bucket")]
        if names and not bad:
            continue
        if bad:
            shown = ", ".join(dict.fromkeys(bad))
            msg = f"{alert}: histogram_quantile только по метрике *_bucket, не по {shown}"
        else:
            msg = f"{alert}: histogram_quantile только по метрике *_bucket"
        if msg not in errs:
            errs.append(msg)
    return errs


def default_model_from_tsv():
    path = os.path.join(ROOT, "llm", "models.tsv")
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    return line.split("\t", 1)[0]
    except OSError:
        pass
    return "ternary-bonsai-2-4b"


def loaded_model():
    """Id of the model the llama-server actually loaded (GET /v1/models), or None."""
    try:
        with urllib.request.urlopen(URL + "/v1/models", timeout=10) as r:
            data = json.load(r)
    except (OSError, ValueError, urllib.error.URLError):
        return None
    rows = data.get("data") if isinstance(data, dict) else None
    if not isinstance(rows, list):
        return None
    for row in rows:
        if isinstance(row, dict):
            name = row.get("id")
            if isinstance(name, str) and name.strip():
                return name.strip()
    return None


def model_for_log(completion, loaded):
    """Prefer the loaded server model over the name echoed from the request."""
    if loaded:
        return loaded
    name = completion.get("model") if isinstance(completion, dict) else None
    if isinstance(name, str) and name.strip():
        return name.strip()
    if MODEL:
        return MODEL
    return default_model_from_tsv()


def chat(system, user, max_tokens=512, history=()):
    loaded = loaded_model()
    body = {
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}, *history],
        "chat_template_kwargs": {"enable_thinking": False},
        "temperature": 0,
        "seed": SEED,
        "max_tokens": max_tokens,
    }
    # Send the loaded id when we know it, so a stale LLM_MODEL default is not echoed back.
    send = loaded or MODEL
    if send:
        body["model"] = send
    req = urllib.request.Request(URL + "/v1/chat/completions", json.dumps(body).encode(),
                                 {"Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=300) as r:
        data = json.load(r)
    text = re.sub(r"<think>.*?</think>", "", data["choices"][0]["message"]["content"], flags=re.S)
    return text, time.time() - t0, data.get("usage", {}), model_for_log(data, loaded)


def strip_fences(text):
    m = re.search(r"```(?:ya?ml)?\s*\n(.*?)(```|$)", text, re.S)
    return (m.group(1) if m else text).strip() + "\n"


def validate_rule_text(text):
    """Return list of errors (empty = valid)."""
    errs = []
    try:
        doc = yaml.safe_load(text)
    except yaml.YAMLError as e:
        return [f"yaml: {e}"]
    if not isinstance(doc, dict):
        return ["yaml: not a mapping"]
    if doc.get("apiVersion") != "monitoring.coreos.com/v1":
        errs.append("apiVersion must be monitoring.coreos.com/v1")
    if doc.get("kind") != "PrometheusRule":
        errs.append("kind must be PrometheusRule")
    md = doc.get("metadata") or {}
    if not NAME.match(str(md.get("name", ""))):
        errs.append(f"metadata.name '{md.get('name')}' must be DNS-1123: lowercase letters, digits and '-' only")
    if (md.get("labels") or {}).get("release") != "mon":
        errs.append("metadata.labels.release must be mon (kube-prometheus-stack selector)")
    groups = (doc.get("spec") or {}).get("groups")
    if not isinstance(groups, list) or not groups:
        return errs + ["spec.groups must be a non-empty list"]
    for g in groups:
        rules = g.get("rules") if isinstance(g, dict) else None
        if not isinstance(rules, list) or not rules:
            errs.append("group without rules")
            continue
        for r in rules:
            if not isinstance(r, dict):
                errs.append("rule is not a mapping")
                continue
            a = str(r.get("alert", ""))
            if not ALERT.match(a):
                errs.append(f"alert name '{a}' must be CamelCase")
            if not str(r.get("expr", "")).strip():
                errs.append(f"{a}: empty expr")
            expr = str(r.get("expr", ""))
            for fn, metric in COUNTER_FUNC.findall(expr):
                spec = WHITELIST.get(metric)
                if spec and spec.get("type") == "gauge":
                    errs.append(f"{a}: {fn}() applied to gauge {metric}; compare the gauge value directly")
            if EQ_REGEX.search(expr):
                errs.append(f"{a}: regex in '=' matcher ({EQ_REGEX.search(expr).group(0)}); use =~ or drop the label")
            errs.extend(check_metric_whitelist(a, expr))
            if "for" in r and not DURATION.match(str(r["for"])):
                errs.append(f"{a}: bad duration for={r['for']}")
            if (r.get("labels") or {}).get("severity") not in ("warning", "critical"):
                errs.append(f"{a}: labels.severity must be warning|critical")
            ann = r.get("annotations") or {}
            for k in ("summary", "description"):
                if not ann.get(k):
                    errs.append(f"{a}: annotations.{k} missing")
    if not errs:
        errs += promtool_check(doc)
    return errs


def promtool_check(doc):
    """promtool check rules on spec (PromQL syntax). Without promtool and docker this is an error,
    unless LLM_SKIP_PROMTOOL=1 is set explicitly (unit tests)."""
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False, dir=tempfile.gettempdir()) as f:
        yaml.safe_dump(doc["spec"], f)
        path = f.name
    os.chmod(path, 0o644)
    if shutil.which("promtool"):
        cmd = ["promtool", "check", "rules", path]
    elif shutil.which("docker") and os.environ.get("LLM_NO_DOCKER") != "1":
        cmd = ["docker", "run", "--rm", "--entrypoint", "promtool", "-v", f"{path}:/r.yaml:ro",
               PROMTOOL_IMAGE, "check", "rules", "/r.yaml"]
    else:
        os.unlink(path)
        if os.environ.get("LLM_SKIP_PROMTOOL") == "1":
            print("validate: LLM_SKIP_PROMTOOL=1 — проверка PromQL пропущена явно", file=sys.stderr)
            return []
        return ["promtool недоступен (нет ни promtool, ни docker): PromQL не проверен"]
    p = subprocess.run(cmd, capture_output=True, text=True)
    os.unlink(path)
    if p.returncode != 0:
        return ["promtool: " + (p.stdout + p.stderr).strip()]
    print("validate: promtool check rules — SUCCESS", file=sys.stderr)
    return []


def log_run(entry):
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    with open(LOG, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")


def cmd_rule(args):
    system = open(os.path.join(PROMPTS, "prometheusrule.system.txt"), encoding="utf-8").read()
    user = f"Available metrics: {KNOWN_METRICS}.\nTask: {args.description}"
    raw, sec, usage, served = chat(system, user)
    text = strip_fences(raw)
    errs = validate_rule_text(text)
    attempts = 1
    if errs and not args.no_repair:
        # one repair round: the validator's errors go back to the model, result is validated again
        print("validate: errors, asking model to repair once:\n  " + "\n  ".join(errs), file=sys.stderr)
        fix = [{"role": "assistant", "content": text},
               {"role": "user", "content": "Validation failed:\n- " + "\n- ".join(errs) + "\nReturn the corrected full YAML only."}]
        raw, sec2, usage, served = chat(system, user, history=fix)
        text, sec, attempts = strip_fences(raw), sec + sec2, 2
        errs = validate_rule_text(text)
    out = args.out or os.path.join(ROOT, "llm", "out", "prometheusrule.generated.yaml")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        f.write(text)
    log_run({"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "task": "rule", "model": served, "seed": SEED,
             "temperature": 0, "prompt_file": "llm/prompts/prometheusrule.system.txt", "user": user,
             "seconds": round(sec, 2), "attempts": attempts, "usage": usage, "valid": not errs, "errors": errs, "out": out})
    print(text)
    print(f"# model={served} time={sec:.1f}s tokens={usage.get('completion_tokens')} out={out}", file=sys.stderr)
    if errs:
        print("VALIDATION FAILED:\n  " + "\n  ".join(errs), file=sys.stderr)
        return 1
    print("VALIDATION OK", file=sys.stderr)
    return 0


def cmd_notes(args):
    system = open(os.path.join(PROMPTS, "release-notes.system.txt"), encoding="utf-8").read()
    def git(*a):
        return subprocess.run(["git", "-C", ROOT, *a], capture_output=True, text=True, check=True).stdout

    user = "git log:\n" + git("log", "--oneline", args.range) + "\ndiffstat:\n" + git("diff", "--stat", args.range)[-3000:]
    raw, sec, usage, served = chat(system, user, max_tokens=600)
    errs = [f"missing section '{s}'" for s in ("## Что изменилось", "## Риски", "## Как проверить") if s not in raw]
    out = args.out or os.path.join(ROOT, "llm", "out", "release-notes.md")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        f.write(raw.strip() + f"\n\n<!-- generated by {served}, temperature 0, seed {SEED}; reviewed by a human before publishing -->\n")
    log_run({"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "task": "notes", "model": served, "seed": SEED,
             "temperature": 0, "prompt_file": "llm/prompts/release-notes.system.txt", "range": args.range, "user": user,
             "seconds": round(sec, 2), "usage": usage, "valid": not errs, "errors": errs, "out": out})
    print(raw)
    print(f"# model={served} time={sec:.1f}s out={out}", file=sys.stderr)
    if errs:
        print("VALIDATION FAILED: " + "; ".join(errs), file=sys.stderr)
        return 1
    return 0


def cyrillic_share(text):
    letters = [c for c in text if c.isalpha()]
    return sum("а" <= c.lower() <= "я" or c in "ёЁ" for c in letters) / max(len(letters), 1)


def numbers_absent(answer, src):
    """3+ digit numbers in the answer that are not a whole token in the log.

    Substring match is wrong: 202 is contained in the date 2026-10-16.
    """
    missing = []
    for n in sorted(set(re.findall(r"\b\d{3,}\b", answer))):
        if re.search(rf"\b{re.escape(n)}\b", src) is None:
            missing.append(n)
    return missing


def cmd_explain(args):
    system = open(os.path.join(PROMPTS, "rollback-explain.system.txt"), encoding="utf-8").read()
    src = sys.stdin.read() if args.log == "-" else open(args.log, encoding="utf-8").read()
    src = src[-3500:]  # fits -c 2048 together with the prompt
    user = "Лог:\n" + src + "\n\nОбъясни по-русски, по формату из системного сообщения."
    raw, sec, usage, served = chat(system, user, max_tokens=400)
    attempts = 1
    if cyrillic_share(raw) < 0.5:
        # language check with one retry: the model drifts to English on English logs
        fix = [{"role": "assistant", "content": raw},
               {"role": "user", "content": "Ответ не на русском. Перепиши тот же ответ полностью на русском языке, тот же формат."}]
        raw, sec2, usage, served = chat(system, user, max_tokens=400, history=fix)
        sec, attempts = sec + sec2, 2
    # grounding check: every number with 3+ digits (HTTP codes, timestamps) must be its own token in the log
    invented = numbers_absent(raw, src)
    share = cyrillic_share(raw)
    errs = (["empty answer"] if not raw.strip() else []) + [f"number not in log: {n}" for n in invented]
    if share < 0.5:
        errs.append(f"not Russian: cyrillic share {share:.2f}")
    log_run({"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "task": "explain", "model": served, "seed": SEED,
             "temperature": 0, "prompt_file": "llm/prompts/rollback-explain.system.txt", "log": args.log, "user": user,
             "seconds": round(sec, 2), "attempts": attempts, "cyrillic_share": round(share, 2),
             "usage": usage, "valid": not errs, "errors": errs})
    print(raw)
    print(f"# model={served} time={sec:.1f}s attempts={attempts} cyrillic={share:.2f}", file=sys.stderr)
    if errs:
        print("CHECK FAILED: " + "; ".join(errs), file=sys.stderr)
        return 1
    print("CHECK OK (русский язык, числа есть в логе)", file=sys.stderr)
    return 0


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("rule")
    r.add_argument("description")
    r.add_argument("--out")
    r.add_argument("--no-repair", action="store_true")
    n = sub.add_parser("notes")
    n.add_argument("--range", default="HEAD~5..HEAD")
    n.add_argument("--out")
    e = sub.add_parser("explain")
    e.add_argument("log", nargs="?", default=os.path.join(ROOT, "llm", "examples", "canary-fail.log"))
    v = sub.add_parser("validate-rule")
    v.add_argument("file")
    a = p.parse_args()
    if a.cmd == "validate-rule":
        errs = validate_rule_text(open(a.file, encoding="utf-8").read())
        print("\n".join(errs) or "VALIDATION OK")
        return 1 if errs else 0
    return {"rule": cmd_rule, "notes": cmd_notes, "explain": cmd_explain}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
