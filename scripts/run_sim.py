"""Run the self-checking testbenches in Vivado xsim (batch mode).

Usage:
    python scripts/run_sim.py            run every testbench in sim/
    python scripts/run_sim.py tb_vga     run the testbenches whose names contain "tb_vga"
    python scripts/run_sim.py --list     list the testbenches
    python scripts/run_sim.py --changed  run only the testbenches whose inputs changed since
                                         they last passed (the others are reported as skipped)

A testbench passes only if it prints "TB_RESULT <name> PASS checks=<n>" and xsim reports no
errors or failures. A header line "RUN_VARIANTS: NAME=value NAME=value" runs it once per
setting; commas join several generics in one setting ("BOOT_ART=false,CHECK_FRAMES=12").

--changed: each pass is recorded in <SIM_WORK>/passed.json with a fingerprint of the
testbench, every design file it reaches (components and "use work." clauses, transitively),
the golden and build/ files it names, its generics and this script.

Environment (optional):
    SIM_WORK   work directory (default build/sim), so several runs can go in parallel
    SIM_ONLY   comma-separated path fragments; only RTL, models and testbenches whose
               path contains one are compiled (packages always are), e.g. "common/,ps2"
    SIM_GENERIC  space-separated NAME=value settings replacing RUN_VARIANTS, e.g.
               "BOOT_ART=false"
    SIM_JOBS   parallel simulations (default: every CPU core). Elaboration is sequential;
               each simulation runs in its own directory next to the work directory (same
               depth, so the testbenches' "../../" paths hold), sharing xsim.dir
    VIVADO_BIN Vivado bin directory (default D:/Xilinx/2025.1/Vivado/bin)

Speed: xelab --O3 (about 8% faster than --O2 on tb_game_core); the slowest testbenches
(SLOW_FIRST) are elaborated first; the system test runs as two variants side by side.
"""

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORK = (Path(os.environ["SIM_WORK"]) if os.environ.get("SIM_WORK") else ROOT / "build" / "sim").resolve()
JOBS = int(os.environ.get("SIM_JOBS") or os.cpu_count() or 1)
ONLY = [f for f in os.environ.get("SIM_ONLY", "").split(",") if f]
GENERICS = os.environ.get("SIM_GENERIC", "").split()
VIVADO_BIN = Path(os.environ.get("VIVADO_BIN", "D:/Xilinx/2025.1/Vivado/bin"))
# Longest runs first, so they start while the short ones are still being elaborated
SLOW_FIRST = ["tb_shooter_top", "tb_game_core", "tb_game_top", "tb_bringup_top", "tb_asset_loader"]


def tool(name):
    return str(VIVADO_BIN / (name + (".bat" if os.name == "nt" else "")))


UNIT_RE = re.compile(r"^\s*(?:entity|package)\s+(\w+)\s+is\b", re.I | re.M)
REF_RE = re.compile(r"^\s*(?:use\s+work\.|component\s+)(\w+)", re.I | re.M)
DATA_RE = re.compile(r'"\.\./\.\./([^"]+)"')


def code_of(path):
    """File text without "--" comments (good enough for the patterns above)."""
    return "\n".join(l.split("--", 1)[0] for l in path.read_text(encoding="utf-8").splitlines())


def make_fingerprints(files):
    """Returns fingerprint(tb_path, generic): a hash of everything the run depends on."""
    units = {}
    for f in files:
        for name in UNIT_RE.findall(code_of(f)):
            units[name.lower()] = f
    cache = {}

    def deps(tb):
        if tb not in cache:
            seen, todo = set(), [tb]
            while todo:
                f = todo.pop()
                if f in seen:
                    continue
                seen.add(f)
                todo += [units[n.lower()] for n in REF_RE.findall(code_of(f)) if n.lower() in units]
            data = set()
            for f in seen:
                text = f.read_text(encoding="utf-8")
                for rel in DATA_RE.findall(text):
                    p = ROOT / rel
                    if p.is_dir():
                        # A directory constant joined with names ("../../sim/golden/" &
                        # "ray4_poses.txt", or "frame4_" & k): the files those names start
                        # with, or the whole directory if no name matches
                        names = set(re.findall(r'"([\w.]+)"', text))
                        hits = [q for s in names for q in p.glob(s + "*") if q.is_file()]
                        data.update(hits or [q for q in p.iterdir() if q.is_file()])
                    else:
                        # A name prefix such as "../../build/level" stands for build/level*.bin
                        data.update([p] if p.is_file() else p.parent.glob(p.name + "*"))
            cache[tb] = sorted(seen | data | {Path(__file__).resolve()})
        return cache[tb]

    def fingerprint(tb, generic):
        h = hashlib.sha1((generic or "").encode())
        for p in deps(tb):
            h.update(str(p.relative_to(ROOT)).encode())
            h.update(p.read_bytes() if p.is_file() else b"")
        return h.hexdigest()
    return fingerprint


def sources():
    # Packages first (other files depend on them), then everything else. Entities are bound
    # at elaboration through component declarations, so their compile order does not matter.
    pkgs = sorted((ROOT / "rtl" / "pkg").glob("*.vhd"))
    rtl = sorted(p for p in (ROOT / "rtl").rglob("*.vhd") if p not in pkgs)
    sim_pkgs = sorted((ROOT / "sim" / "pkg").glob("*.vhd"))
    models = sorted((ROOT / "sim" / "models").glob("*.vhd"))
    tbs = sorted((ROOT / "sim").glob("tb_*.vhd"))
    if ONLY:
        def keep(p):
            rel = p.relative_to(ROOT).as_posix()
            return any(f in rel for f in ONLY)
        rtl = [p for p in rtl if keep(p)]
        models = [p for p in models if keep(p)]
        tbs = [p for p in tbs if keep(p)]
    return pkgs + rtl + sim_pkgs + models + tbs, tbs


def run(cmd, log_name, cwd=None):
    WORK.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(cmd, cwd=cwd or WORK, capture_output=True, text=True,
                            shell=(os.name == "nt"))
    out = result.stdout + result.stderr
    (WORK / log_name).write_text(out, encoding="utf-8", errors="replace")
    return result.returncode, out


def compile_all(files):
    """The design (rtl/) is VHDL-93, sim/ is VHDL-2008; both go into one work
    library, the design first. The file list goes in a --prj file because about 100 absolute
    paths can pass Windows' 8,191-character command-line limit."""
    rtl = [f for f in files if (ROOT / "rtl") in Path(f).parents]
    sim = [f for f in files if f not in rtl]
    for label, kind, group in (("rtl", "vhdl", rtl), ("sim", "vhdl2008", sim)):
        if not group:
            continue
        prj = WORK / ("compile_%s.prj" % label)
        WORK.mkdir(parents=True, exist_ok=True)
        prj.write_text("".join('%s work "%s"\n' % (kind, Path(f).as_posix()) for f in group))
        cmd = [tool("xvhdl"), "--nolog", "--prj", str(prj)]
        code, out = run(cmd, "compile_%s.txt" % label)
        errors = [l for l in out.splitlines() if l.startswith("ERROR")]
        if code != 0 or errors:
            print("\n".join(errors) or out)
            print("Compile failed (log in %s)" % (WORK / ("compile_%s.txt" % label)))
            sys.exit(1)


def variants(tb_path):
    """Generic settings from a "RUN_VARIANTS: A=1 A=2" line in the testbench header
    (or from SIM_GENERIC, which takes precedence)."""
    if GENERICS:
        return GENERICS
    for line in tb_path.read_text(encoding="utf-8").splitlines():
        m = re.search(r"RUN_VARIANTS:\s*(.*)", line)
        if m:
            return m.group(1).split()
    return [None]


def tag_of(name, generic):
    return name + ("_" + generic.replace("=", "").replace(",", "_") if generic else "")


def elaborate(name, generic=None):
    """Builds the snapshot; returns an error text or None."""
    tag = tag_of(name, generic)
    opts = ["--nolog", "--O3", "-L", "unisim", "-debug", "off", "-s", tag + "_snap"]
    for g in (generic.split(",") if generic else []):
        opts += ["-generic_top", g]
    # Options go through a file: the .bat wrapper splits arguments at "="
    WORK.mkdir(parents=True, exist_ok=True)
    (WORK / (tag + "_elab.opt")).write_text(" ".join(opts + ["work." + name]) + "\n")
    code, out = run([tool("xelab"), "-f", tag + "_elab.opt"], tag + "_elab.txt")
    if code != 0 or "ERROR" in out:
        print(out[-3000:])
        return "elaboration failed"
    # An entity left out (e.g. by SIM_ONLY) would be a black box with 'U' outputs and the
    # simulation would hang instead of failing, so stop here
    boxes = [l for l in out.splitlines() if "VRFC 10-4940" in l]
    if boxes:
        print("\n".join(boxes))
        return "unbound component (black box), see %s" % (WORK / (tag + "_elab.txt"))
    return None


def simulate(tag):
    """Runs one snapshot in its own directory, so parallel runs do not share journal
    and waveform files. xsim only looks under xsim.dir/ of its working directory (--xsimdir
    does not change that), so the snapshot (about 1 MB) is copied there."""
    rundir = WORK.parent / (WORK.name + "_run_" + tag)
    shutil.rmtree(rundir, ignore_errors=True)
    shutil.copytree(WORK / "xsim.dir" / (tag + "_snap"), rundir / "xsim.dir" / (tag + "_snap"))
    code, out = run([tool("xsim"), "--nolog", tag + "_snap", "-R"], tag + "_run.txt", cwd=rundir)
    shutil.rmtree(rundir, ignore_errors=True)
    bad = [l for l in out.splitlines()
           if re.match(r"\s*(Error|Failure|FATAL_ERROR|ERROR)", l)]
    m = re.search(r"TB_RESULT\s+(\S+)\s+PASS\s+checks=(\d+)", out)
    if bad or not m:
        return False, "see %s" % (WORK / (tag + "_run.txt")), bad[:20]
    return True, "checks=" + m.group(2), []


def main():
    files, tbs = sources()
    names = [t.stem for t in tbs]
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if "--list" in sys.argv:
        print("\n".join(names))
        return
    changed_only = "--changed" in sys.argv
    if args:
        names = [n for n in names if any(a in n for a in args)]
    compile_all(files)
    names.sort(key=lambda n: SLOW_FIRST.index(n) if n in SLOW_FIRST else len(SLOW_FIRST))
    runs = [(n, g) for n in names for g in variants(ROOT / "sim" / (n + ".vhd"))]
    results = {}
    skipped = []
    fingerprint = make_fingerprints(files)
    passed_file = WORK / "passed.json"
    try:
        passed = json.loads(passed_file.read_text())
    except (OSError, ValueError):
        passed = {}
    prints = {}

    def report(label, ok, info, bad):
        if bad:
            print("\n".join(bad))
        results[label] = (ok, info)
        if ok:
            passed[label] = prints[label]
        else:
            passed.pop(label, None)
        print("%-32s %s  %s" % (label, "PASS" if ok else "FAIL", info), flush=True)

    with ThreadPoolExecutor(max_workers=JOBS) as pool:
        pending = []
        for n, g in runs:
            label = n + (" " + g if g else "")
            prints[label] = fingerprint(ROOT / "sim" / (n + ".vhd"), g)
            if changed_only and passed.get(label) == prints[label]:
                skipped.append(label)
                print("%-32s SKIP  (unchanged since it last passed)" % label, flush=True)
                continue
            err = elaborate(n, g)
            if err:
                report(label, False, err, [])
                continue
            pending.append((label, pool.submit(simulate, tag_of(n, g))))
        # Report each run as it finishes (the long system test was started first)
        labels = {fut: label for label, fut in pending}
        for fut in as_completed(labels):
            ok, info, bad = fut.result()
            report(labels[fut], ok, info, bad)
    WORK.mkdir(parents=True, exist_ok=True)
    passed_file.write_text(json.dumps(passed, indent=1, sort_keys=True))
    failed = [l for l, (ok, _) in results.items() if not ok]
    print("%d of %d testbenches passed%s" % (len(results) - len(failed), len(results),
          ", %d skipped (unchanged)" % len(skipped) if skipped else ""))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
