#!/usr/bin/env python3
"""Local LLM helper: generate a PrometheusRule or release notes via an OpenAI-compatible
llama.cpp server, then validate the result. The model is never trusted without checks.

Usage:
  llm_gen.py rule  "описание алерта" [--out FILE]
  llm_gen.py notes [--range origin/main~5..HEAD] [--out FILE]
  llm_gen.py explain [LOG]   (объяснение провала canary/отката)
  llm_gen.py validate-rule FILE
Env: LLM_URL (default http://127.0.0.1:8090), LLM_MODEL (label for logs), LLM_LOG (jsonl log).
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
import urllib.request

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROMPTS = os.path.join(ROOT, "llm", "prompts")
URL = os.environ.get("LLM_URL", "http://127.0.0.1:8090")
MODEL = os.environ.get("LLM_MODEL", "qwen2.5-coder-1.5b-instruct-q4_k_m")
LOG = os.environ.get("LLM_LOG", os.path.join(ROOT, "llm", "out", "runs.jsonl"))
PROMTOOL_IMAGE = os.environ.get("PROMTOOL_IMAGE", "prom/prometheus:v2.54.1")
SEED = 42
# /metrics is written in main.py, not by prometheus_client: no process collector
# and no status/path labels. `up` is the Prometheus scrape result.
KNOWN_METRICS = "up, service_up, service_probe_latency_seconds, http_requests_total"
DURATION = re.compile(r"^\d+(ms|s|m|h|d)$")
ALERT = re.compile(r"^[A-Z][A-Za-z0-9]+$")
# process_resident_memory_bytes is not exported; rate() on it still fails if a task names it.
GAUGES = ("service_up", "service_probe_latency_seconds", "process_resident_memory_bytes", "up")
COUNTER_FUNC = re.compile(r"\b(rate|irate|increase)\s*\(\s*(\w+)")
EQ_REGEX = re.compile(r'\b\w+\s*=\s*"[^"]*(\.\*|\.\+|\[|\|)[^"]*"')
NAME = re.compile(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")


def chat(system, user, max_tokens=512, history=()):
    body = {
        "model": MODEL,
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}, *history],
        "chat_template_kwargs": {"enable_thinking": False},
        "temperature": 0,
        "seed": SEED,
        "max_tokens": max_tokens,
    }
    req = urllib.request.Request(URL + "/v1/chat/completions", json.dumps(body).encode(),
                                 {"Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=300) as r:
        data = json.load(r)
    text = re.sub(r"<think>.*?</think>", "", data["choices"][0]["message"]["content"], flags=re.S)
    return text, time.time() - t0, data.get("usage", {})


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
                if metric in GAUGES:
                    errs.append(f"{a}: {fn}() applied to gauge {metric}; compare the gauge value directly")
            if EQ_REGEX.search(expr):
                errs.append(f"{a}: regex in '=' matcher ({EQ_REGEX.search(expr).group(0)}); use =~ or drop the label")
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
    raw, sec, usage = chat(system, user)
    text = strip_fences(raw)
    errs = validate_rule_text(text)
    attempts = 1
    if errs and not args.no_repair:
        # one repair round: the validator's errors go back to the model, result is validated again
        print("validate: errors, asking model to repair once:\n  " + "\n  ".join(errs), file=sys.stderr)
        fix = [{"role": "assistant", "content": text},
               {"role": "user", "content": "Validation failed:\n- " + "\n- ".join(errs) + "\nReturn the corrected full YAML only."}]
        raw, sec2, usage = chat(system, user, history=fix)
        text, sec, attempts = strip_fences(raw), sec + sec2, 2
        errs = validate_rule_text(text)
    out = args.out or os.path.join(ROOT, "llm", "out", "prometheusrule.generated.yaml")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        f.write(text)
    log_run({"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "task": "rule", "model": MODEL, "seed": SEED,
             "temperature": 0, "prompt_file": "llm/prompts/prometheusrule.system.txt", "user": user,
             "seconds": round(sec, 2), "attempts": attempts, "usage": usage, "valid": not errs, "errors": errs, "out": out})
    print(text)
    print(f"# model={MODEL} time={sec:.1f}s tokens={usage.get('completion_tokens')} out={out}", file=sys.stderr)
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
    raw, sec, usage = chat(system, user, max_tokens=600)
    errs = [f"missing section '{s}'" for s in ("## Что изменилось", "## Риски", "## Как проверить") if s not in raw]
    out = args.out or os.path.join(ROOT, "llm", "out", "release-notes.md")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        f.write(raw.strip() + f"\n\n<!-- generated by {MODEL}, temperature 0, seed {SEED}; reviewed by a human before publishing -->\n")
    log_run({"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "task": "notes", "model": MODEL, "seed": SEED,
             "temperature": 0, "prompt_file": "llm/prompts/release-notes.system.txt", "range": args.range, "user": user,
             "seconds": round(sec, 2), "usage": usage, "valid": not errs, "errors": errs, "out": out})
    print(raw)
    print(f"# model={MODEL} time={sec:.1f}s out={out}", file=sys.stderr)
    if errs:
        print("VALIDATION FAILED: " + "; ".join(errs), file=sys.stderr)
        return 1
    return 0


def cyrillic_share(text):
    letters = [c for c in text if c.isalpha()]
    return sum("а" <= c.lower() <= "я" or c in "ёЁ" for c in letters) / max(len(letters), 1)


def cmd_explain(args):
    system = open(os.path.join(PROMPTS, "rollback-explain.system.txt"), encoding="utf-8").read()
    src = sys.stdin.read() if args.log == "-" else open(args.log, encoding="utf-8").read()
    src = src[-3500:]  # fits -c 2048 together with the prompt
    user = "Лог:\n" + src + "\n\nОбъясни по-русски, по формату из системного сообщения."
    raw, sec, usage = chat(system, user, max_tokens=400)
    attempts = 1
    if cyrillic_share(raw) < 0.5:
        # language check with one retry: the model drifts to English on English logs
        fix = [{"role": "assistant", "content": raw},
               {"role": "user", "content": "Ответ не на русском. Перепиши тот же ответ полностью на русском языке, тот же формат."}]
        raw, sec2, usage = chat(system, user, max_tokens=400, history=fix)
        sec, attempts = sec + sec2, 2
    # grounding check: every number with 3+ digits (HTTP codes, timestamps) must occur in the log
    invented = sorted({n for n in re.findall(r"\b\d{3,}\b", raw) if n not in src})
    share = cyrillic_share(raw)
    errs = (["empty answer"] if not raw.strip() else []) + [f"number not in log: {n}" for n in invented]
    if share < 0.5:
        errs.append(f"not Russian: cyrillic share {share:.2f}")
    log_run({"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "task": "explain", "model": MODEL, "seed": SEED,
             "temperature": 0, "prompt_file": "llm/prompts/rollback-explain.system.txt", "log": args.log, "user": user,
             "seconds": round(sec, 2), "attempts": attempts, "cyrillic_share": round(share, 2),
             "usage": usage, "valid": not errs, "errors": errs})
    print(raw)
    print(f"# model={MODEL} time={sec:.1f}s attempts={attempts} cyrillic={share:.2f}", file=sys.stderr)
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
