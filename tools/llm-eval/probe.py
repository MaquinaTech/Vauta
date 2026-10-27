#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Context and per-process resource sampler for the language-model A/B (docs/LANGUAGE_MODEL.md, "Measuring on a shared Mac").

usage: probe.py --out samples.jsonl [--interval 1.0] [--watch PID ...] [--watch-name PREFIX ...] [--until-file stop.flag] [--ioreport]

Every interval it writes one JSON line with: wall-clock time; load averages; GPU "Device Utilization %" from the IORegistry
(AGXAccelerator PerformanceStatistics); memory (free+inactive pages, swap used, kern.memorystatus_level); `pmset -g therm`
state; for every process of this user: the CPU time and energy deltas from `proc_pid_rusage(RUSAGE_INFO_V6)` (public, sudo-less),
summarised as the sum and the top few processes OTHER than the watched pids, and the deltas of each watched pid. It only READS
counters: it never signals, renices or opens files of any other process. Developer-side only.

The process under test must not count as "foreign": name it with `--watch PID` or, because every `llm-eval` run is a new process, with
`--watch-name Vauta` (every process whose name starts with it, looked up again each interval; this probe's own pid is always left
out). Its CPU and energy are then reported under `watched`, and `own_cpu_pct` / `own_watts` sum them.

`gpu_util_pct` is the GPU's "Device Utilization %" and includes the process under test (the integrated model runs on the GPU). The
GPU load of OTHER processes can only be read while the watched ones are idle, so `foreign_gpu_util_pct` is `gpu_util_pct` when
`own_cpu_pct` is below 5 and null otherwise. That is a necessary condition only (a GPU-bound decode can leave its host thread under 5% CPU):
aggregate.py also keeps only the samples that lie outside every run's window (from the traces) before it uses one as foreign GPU load.

With `--ioreport` every sample also carries `chip_energy`: the watts of the IOReport "Energy Model" channels over the interval
(ioreport_energy.py, a private framework, sudo-less, like macmon). That is a CHIP-LEVEL figure: it includes every process of the Mac,
so on a shared Mac it is read next to `foreign_cpu_pct_sum` and `foreign_gpu_util_pct`. For GPU work it is the PRIMARY energy figure
(the per-process `watts` of ri_energy_nj leave the GPU out: about 2% of a Gemma job's energy); the per-process figure is the
secondary one, for CPU work. A channel that reads 0 under load (the CPU ones on some OS versions) is reported as measured, not as
"no power". Each chip_energy carries the `interval_s` it covers (the first interval of a run is never reported: it has no start).
"""
import argparse, ctypes, ctypes.util, json, os, re, subprocess, sys, time

libproc = ctypes.CDLL(ctypes.util.find_library("proc"))
RUSAGE_INFO_V6 = 6


class RusageInfoV6(ctypes.Structure):
    _fields_ = [("ri_uuid", ctypes.c_uint8 * 16), ("ri_user_time", ctypes.c_uint64), ("ri_system_time", ctypes.c_uint64),
                ("ri_pkg_idle_wkups", ctypes.c_uint64), ("ri_interrupt_wkups", ctypes.c_uint64), ("ri_pageins", ctypes.c_uint64),
                ("ri_wired_size", ctypes.c_uint64), ("ri_resident_size", ctypes.c_uint64), ("ri_phys_footprint", ctypes.c_uint64),
                ("ri_proc_start_abstime", ctypes.c_uint64), ("ri_proc_exit_abstime", ctypes.c_uint64),
                ("ri_child_user_time", ctypes.c_uint64), ("ri_child_system_time", ctypes.c_uint64),
                ("ri_child_pkg_idle_wkups", ctypes.c_uint64), ("ri_child_interrupt_wkups", ctypes.c_uint64),
                ("ri_child_pageins", ctypes.c_uint64), ("ri_child_elapsed_abstime", ctypes.c_uint64),
                ("ri_diskio_bytesread", ctypes.c_uint64), ("ri_diskio_byteswritten", ctypes.c_uint64),
                ("ri_cpu_time_qos_default", ctypes.c_uint64), ("ri_cpu_time_qos_maintenance", ctypes.c_uint64),
                ("ri_cpu_time_qos_background", ctypes.c_uint64), ("ri_cpu_time_qos_utility", ctypes.c_uint64),
                ("ri_cpu_time_qos_legacy", ctypes.c_uint64), ("ri_cpu_time_qos_user_initiated", ctypes.c_uint64),
                ("ri_cpu_time_qos_user_interactive", ctypes.c_uint64), ("ri_billed_system_time", ctypes.c_uint64),
                ("ri_serviced_system_time", ctypes.c_uint64), ("ri_logical_writes", ctypes.c_uint64),
                ("ri_lifetime_max_phys_footprint", ctypes.c_uint64), ("ri_instructions", ctypes.c_uint64),
                ("ri_cycles", ctypes.c_uint64), ("ri_billed_energy", ctypes.c_uint64), ("ri_serviced_energy", ctypes.c_uint64),
                ("ri_interval_max_phys_footprint", ctypes.c_uint64), ("ri_runnable_time", ctypes.c_uint64),
                ("ri_flags", ctypes.c_uint64), ("ri_user_ptime", ctypes.c_uint64), ("ri_system_ptime", ctypes.c_uint64),
                ("ri_pinstructions", ctypes.c_uint64), ("ri_pcycles", ctypes.c_uint64), ("ri_energy_nj", ctypes.c_uint64),
                ("ri_penergy_nj", ctypes.c_uint64), ("ri_secure_time_in_system", ctypes.c_uint64),
                ("ri_secure_ptime_in_system", ctypes.c_uint64), ("ri_neural_footprint", ctypes.c_uint64),
                ("ri_lifetime_max_neural_footprint", ctypes.c_uint64), ("ri_interval_max_neural_footprint", ctypes.c_uint64),
                ("ri_reserved", ctypes.c_uint64 * 9)]


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


libc = ctypes.CDLL(ctypes.util.find_library("c"))
tb = Timebase()
libc.mach_timebase_info(ctypes.byref(tb))
NS = tb.numer / tb.denom   # Mach time units to nanoseconds


def rusage(pid):
    r = RusageInfoV6()
    if libproc.proc_pid_rusage(pid, RUSAGE_INFO_V6, ctypes.byref(r)) != 0:
        return None
    return r


def pname(pid):
    buf = ctypes.create_string_buffer(256)
    libproc.proc_name(pid, buf, 256)
    return buf.value.decode(errors="replace")


def my_pids():
    out = subprocess.run(["ps", "-U", str(os.getuid()), "-o", "pid="], capture_output=True, text=True).stdout
    return [int(x) for x in out.split()]


def gpu_utilisation():
    out = subprocess.run(["ioreg", "-r", "-d", "1", "-w0", "-c", "AGXAccelerator"], capture_output=True, text=True).stdout
    m = re.search(r'"Device Utilization %"=(\d+)', out)
    return int(m.group(1)) if m else None


def sysctl(name):
    r = subprocess.run(["sysctl", "-n", name], capture_output=True, text=True).stdout.strip()
    return r


def memory():
    vm = subprocess.run(["vm_stat"], capture_output=True, text=True).stdout
    page = int(re.search(r"page size of (\d+)", vm).group(1))
    get = lambda k: int(re.search(k + r":\s+(\d+)", vm).group(1)) * page
    swap = sysctl("vm.swapusage")
    m = re.search(r"used = ([\d.,]+)M", swap)
    return {"free_mb": get("Pages free") >> 20, "inactive_mb": get("Pages inactive") >> 20, "swap_used_mb": float(m.group(1).replace(",", ".")) if m else None,
            "memorystatus_level": int(sysctl("kern.memorystatus_level") or -1)}


def thermal():
    out = subprocess.run(["pmset", "-g", "therm"], capture_output=True, text=True).stdout
    return " ".join(out.split())[:200]


ap = argparse.ArgumentParser()
ap.add_argument("--out", required=True)
ap.add_argument("--interval", type=float, default=1.0)
ap.add_argument("--watch", type=int, nargs="*", default=[])
ap.add_argument("--watch-name", nargs="*", default=[], help="process names (prefixes) that are the process under test, found again every interval")
ap.add_argument("--until-file")
ap.add_argument("--ioreport", action="store_true", help="add the chip-level IOReport energy of each interval (secondary, load-biased)")
a = ap.parse_args()
prev = {}
chip, chip_prev, chip_error = None, None, None
if a.ioreport:
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import ioreport_energy
        chip = ioreport_energy.EnergySampler()
        chip_prev = chip.sample()
    except Exception as e:   # no IOReport on this Mac: say so in every sample
        chip_error = str(e)
with open(a.out, "a") as f:
    while not (a.until_file and os.path.exists(a.until_file)):
        t0 = time.time()
        cur, rows = {}, []
        watching = set(a.watch)
        for pid in my_pids():
            r = rusage(pid)
            if r is None:
                continue
            if a.watch_name and pid != os.getpid() and any(pname(pid).startswith(n) for n in a.watch_name):
                watching.add(pid)
            cur[pid] = (r.ri_user_time + r.ri_system_time, r.ri_energy_nj, r.ri_instructions, r.ri_cycles, r.ri_phys_footprint)
        dt = None
        if prev:
            dt = t0 - prev["t"]
            for pid, (cpu, en, ins, cyc, fp) in cur.items():
                if pid in prev["p"]:
                    p = prev["p"][pid]
                    rows.append((pid, (cpu - p[0]) * NS / 1e9 / dt * 100, (en - p[1]) / 1e9 / dt, (ins - p[2]), (cyc - p[3]), fp >> 20))
        watched = {str(w): next(({"cpu_pct": round(r[1], 1), "watts": round(r[2], 3), "instructions": r[3], "cycles": r[4], "footprint_mb": r[5]} for r in rows if r[0] == w), None) for w in sorted(watching)}
        own = [r for r in rows if r[0] in watching]
        own_cpu = round(sum(r[1] for r in own), 1)
        foreign = sorted((r for r in rows if r[0] not in watching and r[0] != os.getpid()), key=lambda r: -r[1])
        names = {r[0]: pname(r[0]) for r in foreign[:5]}
        gpu = gpu_utilisation()
        sample = {"t": t0, "load": os.getloadavg(), "gpu_util_pct": gpu, "foreign_gpu_util_pct": gpu if prev and own_cpu < 5 else None,
                  "own_cpu_pct": own_cpu, "own_watts": round(sum(r[2] for r in own), 3), "memory": memory(), "thermal": thermal(),
                  "foreign_cpu_pct_sum": round(sum(r[1] for r in foreign), 1),
                  "foreign_top": [{"pid": r[0], "name": names[r[0]], "cpu_pct": round(r[1], 1), "watts": round(r[2], 3)} for r in foreign[:5]],
                  "watched": watched}
        if a.ioreport:
            if chip is not None:
                now = chip.sample()
                w = chip.watts(chip_prev, now)
                interval = now[0] - chip_prev[0]
                chip_prev = now
                # The first interval has no start of its own (the sampler was just created): its watts would be an artefact.
                if prev:
                    sample["chip_energy"] = {"scope": "chip-level, includes every process", "interval_s": round(interval, 3), **ioreport_energy.summarise(w), "frozen_groups": chip.frozen()}
            else:
                sample["chip_energy"] = {"error": chip_error}
        f.write(json.dumps(sample) + "\n")
        f.flush()
        prev = {"t": t0, "p": cur}
        time.sleep(max(0.0, a.interval - (time.time() - t0)))
