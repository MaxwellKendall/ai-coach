#!/usr/bin/env python3
"""FIT-364: the UI score, 0–100. The automated 60 points come from reading the Swift; the simulator's 40 come from
sim.json, which the skill's simulator pass writes. Run from the repo root: python3 .claude/skills/ui-score/score.py
[--json] [--findings]. Rules are the Appllama app design skill's laws, adapted to SwiftUI and App/Theme.swift."""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SKILL = Path(__file__).resolve().parent
SOURCES = ["App", "Features"]
# The design system itself defines the raw values everything else uses.
THEME = "App/Theme.swift"

# Theme.swift: cards 24, rows and buttons 18, chips and inputs 12, small marks 8 (0 is square, a Capsule is a pill).
RADII = {0, 8, 12, 18, 24}
HUES = "blue|purple|pink|orange|green|yellow|teal|indigo|mint|cyan|brown|gray"
ALLOW = re.compile(r"//\s*ui-score:\s*allow\s+([\w-]+)")
ALLOW_FILE = re.compile(r"//\s*ui-score:\s*allow-file\s+([\w-]+)")


def lines_with(pattern, text):
    return [i for i, line in enumerate(text.splitlines(), 1) if re.search(pattern, line)]


def allowed(text, check, line):
    """`// ui-score: allow <check>: why` on the line or the line above exempts it; `allow-file <check>: why` exempts
    the file (an image rendered at a fixed size, say)."""
    if any(m.group(1) == check for m in ALLOW_FILE.finditer(text)):
        return True
    lines = text.splitlines()
    for n in (line - 1, line - 2):
        if 0 <= n < len(lines):
            m = ALLOW.search(lines[n])
            if m and m.group(1) == check:
                return True
    return False


def color_tokens(path, text):
    # Colours come from Theme's tokens, the plate, or semantic system colours. `.red` stays: it's iOS's destructive
    # and error colour, and adapts to dark mode. `.black` and `.white` stay for shadows and text on photos.
    if path == THEME:
        return None
    raw = r"Color\((red|white|hue|light):|UIColor\(red:|Color\(#|Color\(hex"
    hue = rf"(foregroundStyle|foregroundColor|tint|fill|background|stroke|strokeBorder)\(\s*(Color)?\.({HUES})\b|Color\.({HUES})\b"
    return lines_with(raw, text) + lines_with(hue, text)


def dynamic_type(path, text):
    # Fixed point sizes don't follow the user's text size; Font.display (Theme) and the text styles do.
    if path == THEME:
        return None
    return lines_with(r"\.system\(size:|Font\.system\(size:|\.custom\((?!.*relativeTo)", text)


def radius_scale(path, text):
    hits = []
    for i, line in enumerate(text.splitlines(), 1):
        for m in re.finditer(r"cornerRadius:\s*([0-9.]+)\b(?!\s*[*/+-])", line):
            if float(m.group(1)) not in RADII:
                hits.append(i)
        if re.search(r"\.cornerRadius\(", line):
            hits.append(i)
    return hits


def icon_labels(path, text):
    # An icon-only button needs words for VoiceOver: a Label, Text, or .accessibilityLabel.
    hits = []
    pattern = re.compile(r"Button\s*(\([^)]*\))?\s*\{[^{}]*\}\s*label:\s*\{\s*Image\(systemName:[^)]*\)[^{}]*?\}"
                         r"|Button\s*\(action:[^)]*\)\s*\{\s*Image\(systemName:[^)]*\)[^{}]*?\}", re.S)
    for m in pattern.finditer(text):
        after = text[m.start(): m.end() + 240]
        if "accessibilityLabel" not in after and "Label(" not in m.group(0) and "Text(" not in m.group(0):
            hits.append(text.count("\n", 0, m.start()) + 1)
    return hits


def empty_states(path, text):
    # A screen listing what the user saved says what to do when there's none (the skill's "full state cycles").
    names = re.findall(r"@Query[^\n]*?\bvar\s+(\w+)", text)
    loops = [i for name in names for i in lines_with(rf"ForEach\(\s*{name}\b", text)]
    if not loops:
        return None
    return [] if re.search(r"isEmpty|ContentUnavailableView", text) else loops[:1]


def modern_api(path, text):
    old = (r"\bNavigationView\b|\.navigationBarTitle\(|\.foregroundColor\(|\.actionSheet\(|UIScreen\.main"
           r"|\.animation\([^,()]*(\([^)]*\))?\)\s*$|\)\s*\+\s*Text\(|Text\([^)]*\)\s*\+\s*Text")
    return lines_with(old, text)


def reduce_motion(path, text):
    # Spatial motion becomes a fade when Reduce Motion is on.
    motion = lines_with(r"repeatForever|\.transition\([^\n]*\.(move|slide|scale|offset|push|asymmetric)\b", text)
    if not motion:
        # Theme's motionTransition fades with Reduce Motion on.
        return [] if "motionTransition(" in text else None
    return [] if "accessibilityReduceMotion" in text else motion


CHECKS = [
    ("color-tokens", 12, "Colours from Theme tokens, the plate, or semantic system colours", color_tokens),
    ("dynamic-type", 14, "Text follows Dynamic Type (text styles or Font.display), no fixed sizes", dynamic_type),
    ("radius-scale", 6, "Corner radii from the scale 8 / 12 / 18 / 24", radius_scale),
    ("icon-labels", 8, "Icon-only buttons have an accessibility label", icon_labels),
    ("empty-states", 8, "Lists of saved things handle having none", empty_states),
    ("modern-api", 6, "No deprecated SwiftUI (NavigationView, foregroundColor, Text + Text, value-less .animation)", modern_api),
    ("reduce-motion", 6, "Spatial or looping motion respects Reduce Motion", reduce_motion),
]


def automated():
    files = sorted(p for d in SOURCES for p in (ROOT / d).rglob("*.swift"))
    views = [(str(p.relative_to(ROOT)), p.read_text()) for p in files]
    views = [(p, t) for p, t in views if re.search(r":\s*(some\s+)?View\b|ButtonStyle|ViewModifier", t)]
    results = []
    for key, points, title, check in CHECKS:
        applicable, clean, findings, exempt = 0, 0, [], 0
        for path, text in views:
            hits = check(path, text)
            if hits is None:
                continue
            kept = [h for h in hits if not allowed(text, key, h)]
            exempt += len(hits) - len(kept)
            applicable += 1
            if kept:
                findings += [f"{path}:{h}" for h in sorted(set(kept))]
            else:
                clean += 1
        share = clean / applicable if applicable else 1
        results.append({"check": key, "title": title, "max": points, "points": round(points * share, 1),
                        "clean": clean, "files": applicable, "exempt": exempt, "findings": findings})
    return results


def simulator():
    """sim.json: {"date", "commit", "items": [{"id", "max", "points", "note", "hard_fail"?}]}, written by the skill."""
    path = SKILL / "sim.json"
    if not path.exists():
        return None
    return json.loads(path.read_text())


def main():
    auto = automated()
    sim = simulator()
    auto_total = sum(r["points"] for r in auto)
    sim_total = sum(i["points"] for i in sim["items"]) if sim else 0
    hard = [i for i in sim["items"] if i.get("hard_fail")] if sim else []
    score = auto_total + sim_total
    # A broken screen in the simulator (unreadable, clipped primary action, a dead end) caps the score.
    if hard:
        score = min(score, 79)
    out = {"score": round(score, 1), "automated": round(auto_total, 1), "simulator": round(sim_total, 1) if sim else None,
           "capped": bool(hard), "checks": auto, "sim": sim}
    if "--json" in sys.argv:
        print(json.dumps(out, indent=2))
        return
    print(f"UI score: {out['score']} / 100" + ("  (capped at 79: a hard fail in the simulator)" if hard else ""))
    print(f"  automated {out['automated']} / 60")
    for r in auto:
        ex = f", {r['exempt']} exempt" if r["exempt"] else ""
        print(f"    {r['points']:>4} / {r['max']:<2}  {r['check']:<14} {r['clean']}/{r['files']} files clean{ex}")
    if sim:
        print(f"  simulator {out['simulator']} / 40  (sim.json, {sim.get('date', '?')} at {sim.get('commit', '?')})")
        for i in sim["items"]:
            flag = "  HARD FAIL" if i.get("hard_fail") else ""
            print(f"    {i['points']:>4} / {i['max']:<2}  {i['id']:<22} {i.get('note', '')}{flag}")
    else:
        print("  simulator  0 / 40  (no sim.json yet: run the skill's simulator pass)")
    if "--findings" in sys.argv:
        for r in auto:
            for f in r["findings"]:
                print(f"{r['check']}\t{f}")


if __name__ == "__main__":
    main()
