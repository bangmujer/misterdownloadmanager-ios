#!/usr/bin/env python3
"""Convert EasyList + EasyPrivacy (the filter lists Ghostery's adblocker engine
is built on) into WKContentRuleList JSON for the MDM iOS browser.

Why a conversion, not the engine itself: ghostery/adblocker is a JavaScript
library for Node.js / WebExtensions (webRequest / declarativeNetRequest).
WKWebView cannot run it: subresource blocking on iOS only happens through
Apple's content-blocker engine (WKContentRuleList). So the app ships the
same lists Ghostery uses, converted to the format WebKit understands.

Usage:
    python3 tools/build-ghostery-rules.py easylist.txt easyprivacy.txt

Outputs (in Sources/Resources/, committed to the repo), chunked so no
single list approaches WebKit's per-list rule limits:
    ghostery-rules-1.json .. -3.json  network rules, ~40k per chunk
    ghostery-rules-4.json              cosmetic (element-hiding) rules
Exception (@@) rules are duplicated at the end of every network chunk:
WKContentRuleList's ignore-previous-rules only cancels earlier rules in
the SAME list, so blocks-before-exceptions ordering per chunk is what
makes exceptions win, as they do in Adblock Plus semantics. The Swift
side appends the user's custom filters + allowlist to every chunk the
same way, so the allowlist keeps working across chunks.

Regenerate whenever the lists should be refreshed, then update
AdBlockRules.ghosterySnapshot in Sources/Browser.swift to the new date.

Sources (fetched 2026-11-22, versions in the list headers):
    https://easylist.to/easylist/easylist.txt
    https://easylist-downloads.adblockplus.org/easyprivacy.txt
"""

import json
import re
import sys
from collections import Counter

SEP = r"([^A-Za-z0-9_%.-]|$)"
REGEX_SPECIALS = set("\\.^$|?*+()[]{}")

TYPE_MAP = {
    "script": "script",
    "image": "image",
    "stylesheet": "style-sheet",
    "xmlhttprequest": "xmlhttprequest",
    "xhr": "xmlhttprequest",
    "subdocument": "document",
    "document": "document",
    "font": "font",
    "media": "media",
    "websocket": "websocket",
    "popup": "popup",
    "other": "other",
    "object": "other",
    "object-subrequest": "other",
    "ping": "ping",
    "beacon": "ping",
}
TYPE_TOKENS = set(TYPE_MAP) | {"object", "object-subrequest", "ping", "beacon", "other"}

KNOWN_OPTS = set(TYPE_MAP) | {
    "elemhide", "generichide", "genericblock", "badfilter",
    "third-party", "first-party", "3p", "1p",
    "strict3p", "strict-first-party",
    "all", "important", "match-case",
    "empty", "mp4", "network", "ghide", "gblock",
    "inline-script", "inline-font", "specifichide",
    "csp", "redirect", "rewrite", "removeparam", "header",
    "cookie", "permissions", "replace", "jsonprune", "hls",
    "dnstype", "method", "sitekey", "redirect-rule", "removeheader",
    "app", "port", "ipaddress", "webrtc", "stylesheet",
}
KNOWN_KEYS = {
    "domain", "from", "to", "csp", "redirect", "rewrite", "removeparam",
    "header", "cookie", "permissions", "sitekey", "dnstype", "method",
    "referrerpolicy", "hls", "jsonprune", "replace", "redirect-rule",
    "removeheader", "urlskip", "important",
}
# Filters carrying any of these (non-negated) are skipped: WebKit content
# blockers cannot express them, and applying them partially would mis-block.
SKIP_OPTS = {
    "elemhide", "generichide", "genericblock", "badfilter",
    "csp", "redirect", "rewrite", "removeparam", "header",
    "cookie", "permissions", "replace", "jsonprune", "hls",
    "dnstype", "method", "sitekey", "inline-script", "inline-font",
    "specifichide", "empty", "mp4", "network", "ghide", "gblock",
    "redirect-rule", "removeheader",
}
SKIP_KEYS = {
    "csp", "redirect", "rewrite", "removeparam", "header", "cookie",
    "permissions", "sitekey", "dnstype", "method", "hls", "jsonprune",
    "replace", "to", "redirect-rule", "removeheader",
}

COSMETIC_SKIP_FRAGMENTS = (
    ":has(", ":contains(", ":-abp-", ":matches-", ":xpath(", ":if(",
    ":style(", ":remove(", ":upward(", ":has-text", "+js(", ">>>",
    ":nth-ancestor", ":watch-attr", ":remove-attr", ":remove-class",
)
CHUNK_SIZE = 40000


def escape_regex(s):
    return "".join("\\" + c if c in REGEX_SPECIALS else c for c in s)


def convert_chars(body):
    """Convert ABP pattern syntax to regex: * -> .*, ^ -> separator class."""
    out = []
    for c in body:
        if c == "*":
            out.append(".*")
        elif c == "^":
            out.append(SEP)
        else:
            out.append("\\" + c if c in REGEX_SPECIALS else c)
    return "".join(out)


def pattern_to_regex(pat):
    """ABP network pattern -> url-filter regex (unanchored search semantics)."""
    if pat.startswith("/") and pat.endswith("/") and len(pat) > 2:
        return pat[1:-1]
    if pat.startswith("||"):
        rest = pat[2:]
        cut = len(rest)
        for i, ch in enumerate(rest):
            if ch in "/^":
                cut = i
                break
        domain, tail = rest[:cut], rest[cut:]
        if not domain:
            return None
        regex = ".*://([^/]*\\.)?" + convert_chars(domain)
        if tail:
            regex += convert_chars(tail)
        else:
            regex += "([/?#:].*)?$"
        return regex
    anchored_start = pat.startswith("|")
    anchored_end = pat.endswith("|")
    if anchored_start:
        pat = pat[1:]
    if anchored_end and pat:
        pat = pat[:-1]
    if not pat:
        return None
    regex = ("^" if anchored_start else ".*") + convert_chars(pat)
    regex += "$" if anchored_end else ".*"
    return regex


def split_options(line):
    """Split 'pattern$options' if the suffix validates as ABP options."""
    idx = line.rfind("$")
    if idx <= 0:
        return line, []
    suffix = line[idx + 1:]
    if not suffix or any(c in suffix for c in "/ \t"):
        return line, []
    tokens = suffix.split(",")
    for tok in tokens:
        t = tok[1:] if tok.startswith("~") else tok
        if "=" in t:
            if t.split("=", 1)[0] not in KNOWN_KEYS:
                return line, []
        elif t not in KNOWN_OPTS:
            return line, []
    return line[:idx], tokens


def parse_domains(value):
    """$domain=a.com,~b.com -> (if-domain, unless-domain)."""
    if_domains, unless_domains = [], []
    for part in re.split(r"[,|]", value):
        part = part.strip()
        if not part:
            continue
        if part.startswith("~"):
            unless_domains.append(part[1:].removeprefix("*."))
        else:
            if_domains.append(part.removeprefix("*."))
    return if_domains, unless_domains


def network_rule(line, stats):
    is_exception = line.startswith("@@")
    if is_exception:
        line = line[2:]
    pattern, tokens = split_options(line)
    if not pattern:
        stats["empty_pattern"] += 1
        return None

    has_unsupported = False
    resource_types = set()
    had_type_token = False
    negated_type = False
    load_types = set()
    if_domains, unless_domains = [], []
    case_sensitive = False
    is_document = False
    for tok in tokens:
        negated = tok.startswith("~")
        t = tok[1:] if negated else tok
        if "=" in t:
            key, value = t.split("=", 1)
            if key in SKIP_KEYS:
                return None
            if key in ("domain", "from"):
                inc, exc = parse_domains(value)
                if_domains.extend(inc)
                unless_domains.extend(exc)
            continue
        if t in SKIP_OPTS and not negated:
            return None
        if t in TYPE_TOKENS:
            had_type_token = True
            if negated:
                negated_type = True
            elif t in TYPE_MAP:
                resource_types.add(TYPE_MAP[t])
            continue
        if t in ("third-party", "3p", "strict3p"):
            load_types.add("third-party" if not negated else "first-party")
        elif t in ("first-party", "1p", "strict-first-party"):
            load_types.add("first-party" if not negated else "third-party")
        elif t == "document":
            is_document = True
        elif t == "match-case":
            case_sensitive = True
        # 'all', 'important' and the rest need no translation.
    if negated_type:
        stats["skip_negated_type"] += 1
        return None
    if had_type_token and not resource_types and not is_document:
        stats["skip_unmapped_type"] += 1
        return None

    regex = pattern_to_regex(pattern)
    if regex is None:
        stats["bad_pattern"] += 1
        return None
    try:
        re.compile(regex)
    except re.error:
        stats["bad_regex"] += 1
        return None

    trigger = {"url-filter": regex}
    if resource_types and not (is_exception and is_document):
        trigger["resource-type"] = sorted(resource_types)
    elif is_document and not is_exception:
        trigger["resource-type"] = ["document"]
    if load_types:
        trigger["load-type"] = sorted(load_types)
    if if_domains:
        trigger["if-domain"] = sorted(set(if_domains))
    if unless_domains:
        trigger["unless-domain"] = sorted(set(unless_domains))
    if case_sensitive:
        trigger["url-filter-is-case-sensitive"] = True
    action = {"type": "ignore-previous-rules" if is_exception else "block"}
    return {"trigger": trigger, "action": action}


def cosmetic_rule(line, stats):
    if "#@#" in line:
        stats["cosmetic_exception"] += 1
        return None
    domains_part, _, selector = line.partition("##")
    selector = selector.strip()
    if not selector or selector.startswith("+js"):
        stats["cosmetic_skip"] += 1
        return None
    if len(selector) > 300 or any(f in selector for f in COSMETIC_SKIP_FRAGMENTS):
        stats["cosmetic_extended"] += 1
        return None
    if_domains, unless_domains = [], []
    if domains_part:
        for part in domains_part.split(","):
            part = part.strip()
            if not part or "*" in part:
                stats["cosmetic_skip"] += 1
                return None
            if part.startswith("~"):
                unless_domains.append(part[1:])
            else:
                if_domains.append(part)
    trigger = {"url-filter": ".*"}
    if if_domains:
        trigger["if-domain"] = sorted(set(if_domains))
    if unless_domains:
        trigger["unless-domain"] = sorted(set(unless_domains))
    return {"trigger": trigger,
            "action": {"type": "css-display-none", "selector": selector}}


def convert_file(path, stats):
    rules, cosmetics = [], []
    with open(path, encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("!") or line.startswith("["):
                continue
            if "##" in line and "#$#" not in line and "#?#" not in line:
                rule = cosmetic_rule(line, stats)
                if rule is not None:
                    cosmetics.append(rule)
                continue
            if "#$#" in line or "#?#" in line or "#@#" in line:
                stats["skip_extended"] += 1
                continue
            rule = network_rule(line, stats)
            if rule is not None:
                rules.append(rule)
    return rules, cosmetics


def dedupe(rules):
    seen, out = set(), []
    for rule in rules:
        key = json.dumps(rule, sort_keys=True)
        if key not in seen:
            seen.add(key)
            out.append(rule)
    return out


def main():
    inputs = sys.argv[1:]
    if len(inputs) < 2:
        print("usage: build-ghostery-rules.py easylist.txt easyprivacy.txt")
        return 2
    stats = Counter()
    all_network, all_cosmetic = [], []
    for path in inputs:
        network, cosmetics = convert_file(path, stats)
        print(f"{path}: {len(network)} network, {len(cosmetics)} cosmetic")
        all_network.extend(network)
        all_cosmetic.extend(cosmetics)
    all_cosmetic = dedupe(all_cosmetic)[:CHUNK_SIZE]
    # Blocks first, exceptions last, per ABP semantics: ignore-previous-rules
    # only cancels earlier rules in the same list.
    blocks = [r for r in all_network if r["action"]["type"] == "block"]
    exceptions = [r for r in all_network if r["action"]["type"] != "block"]
    chunks = []
    for i in range(0, len(blocks), CHUNK_SIZE):
        chunks.append(blocks[i:i + CHUNK_SIZE] + exceptions)
    chunks.append(all_cosmetic)
    out_dir = "Sources/Resources"
    import os
    os.makedirs(out_dir, exist_ok=True)
    for n, chunk in enumerate(chunks, 1):
        path = f"{out_dir}/ghostery-rules-{n}.json"
        with open(path, "w", encoding="utf-8") as f:
            json.dump(chunk, f, separators=(",", ":"))
        print(f"{path}: {len(chunk)} rules")
    print(f"network blocks: {len(blocks)}, exceptions: {len(exceptions)} "
          f"(duplicated in each of {len(chunks) - 1} network chunks)")
    print(f"cosmetic rules: {len(all_cosmetic)}")
    print(f"total chunks: {len(chunks)}")
    print("skipped:", dict(stats))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
