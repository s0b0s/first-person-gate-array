"""Run the self-checking testbenches in Vivado xsim, batch mode, no GUI.

Usage:
    python scripts/run_sim.py            run every testbench in sim/
    python scripts/run_sim.py tb_vga     run the testbenches whose names contain "tb_vga"
    python scripts/run_sim.py --list     list the testbenches

Every testbench prints one line "TB_RESULT <name> PASS checks=<n>" when it finishes cleanly.
A testbench passes only if that line appears and xsim reports no errors or failures.
A "RUN_VARIANTS: NAME=value NAME=value" line in a testbench header runs it once per setting.

Environment (optional):
    SIM_WORK   work directory (default build/sim), so several runs can go in parallel
    SIM_ONLY   comma-separated path fragments; only RTL, models and testbenches whose
               path contains one are compiled (packages always are), e.g. "common/,ps2"
    SIM_GENERIC  space-separated NAME=value settings; each replaces the testbench's
               RUN_VARIANTS for this run (one run per setting), e.g. "BOOT_ART=false"
    SIM_JOBS   simulations running at the same time (default: every CPU core). Elaboration
               is sequential (xelab already compiles in parallel); each simulation starts as
               soon as its snapshot is ready, in its own directory next to the work directory
               (same depth, so the testbenches' "../../" paths still hold), sharing xsim.dir
    VIVADO_BIN Vivado bin directory (default D:/Xilinx/2025.1/Vivado/bin)
"""

import os
import re
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORK = (Path(os.environ["SIM_WORK"]) if os.environ.get("SIM_WORK") else ROOT / "build" / "sim").resolve()
JOBS = int(os.environ.get("SIM_JOBS") or os.cpu_count() or 1)
ONLY = [f for f in os.environ.get("SIM_ONLY", "").split(",") if f]
GENERICS = os.environ.get("SIM_GENERIC", "").split()
VIVADO_BIN = Path(os.environ.get("VIVADO_BIN", "D:/Xilinx/2025.1/Vivado/bin"))


def tool(name):
    return str(VIVADO_BIN / (name + (".bat" if os.name == "nt" else "")))


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
    """The design (rtl/, packages included) is VHDL-93, as in the course; the testbenches,
    models and sim packages use VHDL-2008 (protected types, external names). Both go into the
    same work library, the design first. The file list goes in a project file (--prj), not on
    the command line: about 100 absolute paths can pass Windows' 8,191-character limit when the
    repository sits in a deep folder."""
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
    return name + ("_" + generic.replace("=", "") if generic else "")


def elaborate(name, generic=None):
    """Builds the snapshot; returns an error text or None."""
    tag = tag_of(name, generic)
    opts = ["--nolog", "-L", "unisim", "-debug", "off", "-s", tag + "_snap"]
    if generic:
        opts += ["-generic_top", generic]
    # Options go through a file: the .bat wrapper splits arguments at "="
    WORK.mkdir(parents=True, exist_ok=True)
    (WORK / (tag + "_elab.opt")).write_text(" ".join(opts + ["work." + name]) + "\n")
    code, out = run([tool("xelab"), "-f", tag + "_elab.opt"], tag + "_elab.txt")
    if code != 0 or "ERROR" in out:
        print(out[-3000:])
        return "elaboration failed"
    # An entity left out of the compile (e.g. by SIM_ONLY) becomes a black box with 'U'
    # outputs; the simulation then tends to hang instead of failing, so stop here
    boxes = [l for l in out.splitlines() if "VRFC 10-4940" in l]
    if boxes:
        print("\n".join(boxes))
        return "unbound component (black box), see %s" % (WORK / (tag + "_elab.txt"))
    return None


def simulate(tag):
    """Runs one snapshot in its own directory, so parallel runs do not share xsim's journal
    and waveform files. xsim looks for the snapshot under xsim.dir/ in its working directory
    (--xsimdir does not change that), so the snapshot (about 1 MB) is copied there. The log
    goes to the work directory as before."""
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
    args = sys.argv[1:]
    if "--list" in args:
        print("\n".join(names))
        return
    if args:
        names = [n for n in names if any(a in n for a in args)]
    compile_all(files)
    runs = [(n, g) for n in names for g in variants(ROOT / "sim" / (n + ".vhd"))]
    results = {}

    def report(label, ok, info, bad):
        if bad:
            print("\n".join(bad))
        results[label] = (ok, info)
        print("%-32s %s  %s" % (label, "PASS" if ok else "FAIL", info), flush=True)

    with ThreadPoolExecutor(max_workers=JOBS) as pool:
        pending = []
        for n, g in runs:
            label = n + (" " + g if g else "")
            err = elaborate(n, g)
            if err:
                report(label, False, err, [])
                continue
            pending.append((label, pool.submit(simulate, tag_of(n, g))))
        for label, fut in pending:
            ok, info, bad = fut.result()
            report(label, ok, info, bad)
    failed = [l for l, (ok, _) in results.items() if not ok]
    print("%d of %d testbenches passed" % (len(results) - len(failed), len(results)))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
