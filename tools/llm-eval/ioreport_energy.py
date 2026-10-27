#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Chip-level energy from the IOReport "Energy Model" group (sudo-less, the counters `macmon` reads), for the language-model A/B.

usage: ioreport_energy.py [--interval 1.0] [--count N] [--out energy.jsonl]      (or `import ioreport_energy` from probe.py)

Prints one JSON line per interval: watts of CPU, GPU, ANE, DRAM and the rest of the "Energy Model" channels over the interval.
LABEL IT AS WHAT IT IS: these are CHIP-LEVEL totals, so on a shared Mac they include every other process (a pytest run in
another workload, the window server); the per-process figure (`proc_pid_rusage` `ri_energy_nj`, probe.py) is the one to attribute
to a job. Use these watts only as a secondary, load-annotated figure next to the load, GPU and foreign-CPU context of probe.py.

IOReport is a private framework (`/usr/lib/libIOReport.dylib`): this file is a developer tool, it is never part of the app, and
the app's source scan forbids the name in the language-model code. It only reads counters and writes to its own output file.
"""
import argparse, ctypes, ctypes.util, json, sys, time

cf = ctypes.CDLL(ctypes.util.find_library("CoreFoundation"))
ior = ctypes.CDLL("/usr/lib/libIOReport.dylib")

CFTypeRef = ctypes.c_void_p
cf.CFStringCreateWithCString.restype = CFTypeRef
cf.CFStringCreateWithCString.argtypes = [CFTypeRef, ctypes.c_char_p, ctypes.c_uint32]
cf.CFDictionaryGetValue.restype = CFTypeRef
cf.CFDictionaryGetValue.argtypes = [CFTypeRef, CFTypeRef]
cf.CFArrayGetCount.restype = ctypes.c_long
cf.CFArrayGetCount.argtypes = [CFTypeRef]
cf.CFArrayGetValueAtIndex.restype = CFTypeRef
cf.CFArrayGetValueAtIndex.argtypes = [CFTypeRef, ctypes.c_long]
cf.CFStringGetCString.restype = ctypes.c_bool
cf.CFStringGetCString.argtypes = [CFTypeRef, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
cf.CFRelease.argtypes = [CFTypeRef]
cf.CFDictionaryCreateMutableCopy.restype = CFTypeRef
cf.CFDictionaryCreateMutableCopy.argtypes = [CFTypeRef, ctypes.c_long, CFTypeRef]

ior.IOReportCopyChannelsInGroup.restype = CFTypeRef
ior.IOReportCopyChannelsInGroup.argtypes = [CFTypeRef, CFTypeRef, ctypes.c_uint64, ctypes.c_uint64, ctypes.c_uint64]
ior.IOReportCreateSubscription.restype = CFTypeRef
ior.IOReportCreateSubscription.argtypes = [CFTypeRef, CFTypeRef, ctypes.POINTER(CFTypeRef), ctypes.c_uint64, CFTypeRef]
ior.IOReportCreateSamples.restype = CFTypeRef
ior.IOReportCreateSamples.argtypes = [CFTypeRef, CFTypeRef, CFTypeRef]
ior.IOReportCreateSamplesDelta.restype = CFTypeRef
ior.IOReportCreateSamplesDelta.argtypes = [CFTypeRef, CFTypeRef, CFTypeRef]
ior.IOReportChannelGetChannelName.restype = CFTypeRef
ior.IOReportChannelGetChannelName.argtypes = [CFTypeRef]
ior.IOReportChannelGetUnitLabel.restype = CFTypeRef
ior.IOReportChannelGetUnitLabel.argtypes = [CFTypeRef]
ior.IOReportSimpleGetIntegerValue.restype = ctypes.c_int64
ior.IOReportSimpleGetIntegerValue.argtypes = [CFTypeRef, ctypes.c_int32]

K_UTF8 = 0x08000100
UNIT_TO_JOULES = {"mJ": 1e-3, "uJ": 1e-6, "nJ": 1e-9, "J": 1.0}


def cfstr(s):
    return cf.CFStringCreateWithCString(None, s.encode(), K_UTF8)


def pystr(ref):
    if not ref:
        return ""
    buf = ctypes.create_string_buffer(256)
    return buf.value.decode() if cf.CFStringGetCString(ref, buf, 256, K_UTF8) else ""


class EnergySampler:
    """Take `sample()` twice; `watts(a, b)` gives the average power per channel between them."""

    def __init__(self):
        channels = ior.IOReportCopyChannelsInGroup(cfstr("Energy Model"), None, 0, 0, 0)
        if not channels:
            raise RuntimeError("IOReport has no Energy Model group on this Mac")
        self.channels = cf.CFDictionaryCreateMutableCopy(None, 0, channels)
        self.sub_channels = CFTypeRef()
        self.sub = ior.IOReportCreateSubscription(None, self.channels, ctypes.byref(self.sub_channels), 0, None)
        if not self.sub:
            raise RuntimeError("IOReport subscription failed")
        self.intervals = 0
        self.moved = set()   # the summary channels that have ever changed

    def sample(self):
        return time.monotonic(), ior.IOReportCreateSamples(self.sub, self.sub_channels, None)

    def joules(self, a, b):
        """Energy per channel in joules between two samples."""
        delta = ior.IOReportCreateSamplesDelta(a[1], b[1], None)
        items = cf.CFDictionaryGetValue(delta, cfstr("IOReportChannels"))
        out = {}
        for i in range(cf.CFArrayGetCount(items)):
            ch = cf.CFArrayGetValueAtIndex(items, i)
            name, unit = pystr(ior.IOReportChannelGetChannelName(ch)), pystr(ior.IOReportChannelGetUnitLabel(ch))
            out[name] = out.get(name, 0.0) + ior.IOReportSimpleGetIntegerValue(ch, 0) * UNIT_TO_JOULES.get(unit, 0.0)
        cf.CFRelease(delta)
        self.intervals += 1
        self.moved |= {k for k, v in out.items() if v > 0}
        return out

    def frozen(self, minimum_intervals=5):
        """The summary groups whose counters never moved over at least `minimum_intervals` intervals: on macOS 27.0.1 the CPU,
        DRAM and ANE energy channels stay constant for a process that is not root (only the GPU one moves), so a 0 W there is a
        counter that is not updating, not an idle chip."""
        if self.intervals < minimum_intervals:
            return []
        groups = {"cpu": ("CPU Energy", "ECPU", "PCPU"), "dram": ("DRAM",), "ane": ("ANE",), "gpu": ("GPU",)}
        return [g for g, keys in groups.items() if not any(m.startswith(k) for m in self.moved for k in keys)]

    def watts(self, a, b):
        dt = max(b[0] - a[0], 1e-6)
        return {k: round(v / dt, 3) for k, v in self.joules(a, b).items()}


def summarise(w):
    """CPU, GPU, ANE, DRAM and the total (the sum of the CPU, GPU, ANE and DRAM channels, as macmon reports 'all')."""
    pick = lambda *keys: round(sum(v for k, v in w.items() if any(k.upper().startswith(x) for x in keys)), 3)
    cpu, gpu, ane, dram = pick("CPU", "ECPU", "PCPU", "EACC", "PACC"), pick("GPU"), pick("ANE"), pick("DRAM")
    return {"cpu_w": cpu, "gpu_w": gpu, "ane_w": ane, "dram_w": dram, "all_w": round(cpu + gpu + ane + dram, 3)}


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--interval", type=float, default=1.0)
    ap.add_argument("--count", type=int, default=0)
    ap.add_argument("--out")
    a = ap.parse_args()
    s = EnergySampler()
    prev = s.sample()
    n = 0
    f = open(a.out, "a") if a.out else sys.stdout
    while a.count == 0 or n < a.count:
        time.sleep(a.interval)
        cur = s.sample()
        w = s.watts(prev, cur)
        f.write(json.dumps({"t": time.time(), "interval_s": round(cur[0] - prev[0], 3), "chip": summarise(w), "channels": w, "scope": "chip-level, includes every process"}) + "\n")
        f.flush()
        prev = cur
        n += 1
