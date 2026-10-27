#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Summarises a `Vauta llm-eval` run: usage: aggregate.py <out-dir> [probe.jsonl]

With a probe file recorded with `--ioreport` it prints the chip-level GPU energy of each run (the PRIMARY energy figure for GPU work: GPU
watts integrated over the run, also net of the GPU's idle power) and writes it per run to `energy.json`; the CPU, DRAM and ANE channels do not
update for a non-root process on macOS 27.0.1 and are reported as frozen. That figure includes every process on the GPU, so read it with the
foreign load next to it. The per-process `own energy` (ri_energy_nj) is CPU only (about 2% of a Gemma job's energy) and is the secondary figure;
Apple's model runs in another process whose counters are not readable.

Prints, per task and load bucket, the within-pair ratios (integrated / Apple) of wall time, time to first token and own-process
energy and CPU, JSON validity, retries, kept/dropped items, and (live answers) verified-claim and gold-match rates. Ratios inside a
pair cancel slow drift in the foreign load; absolute numbers are given per load bucket (quiet = load1 < 4, moderate 4-10, heavy > 10).
The probe file (probe.py) adds the foreign CPU and GPU context of each run. Nothing here is a quality judgement.
"""
import json, statistics as st, sys, collections, os

out = sys.argv[1]
rows = [json.loads(l) for l in open(os.path.join(out, "traces.jsonl"))]
probe = [json.loads(l) for l in open(sys.argv[2])] if len(sys.argv) > 2 else []


# The windows of the runs (the process under test works in them) with the probe's interval after each: a probe sample inside one is
# never "the Mac without the process under test", whatever the process's CPU was (a GPU-bound decode can leave its host thread
# below the probe's 5% idle line while the GPU is busy with it).
RUN_WINDOWS = sorted((r["startedAt"], r["endedAt"] + 2.0) for r in rows)


def between_runs(p):
    return not any(a <= p["t"] <= b for a, b in RUN_WINDOWS)


def ctx(r):
    """The load around a run from the probe. CPU: the samples of the run. GPU: only the samples where the process under test was idle
    count as foreign load (`foreign_gpu_util_pct`) AND that lie outside every run's window, so the 30 s before the run are read
    (probes from before 11a.1 have no such key and counted the model's own GPU use as foreign)."""
    w = [p for p in probe if r["startedAt"] <= p["t"] <= r["endedAt"]]
    if not w:
        return None
    before = [p for p in probe if r["startedAt"] - 30 <= p["t"] < r["startedAt"] and between_runs(p)]
    foreign_gpu = [p["foreign_gpu_util_pct"] for p in before if p.get("foreign_gpu_util_pct") is not None]
    if not foreign_gpu and r.get("gpuUtilPct") is not None:
        foreign_gpu = [r["gpuUtilPct"]]   # the trace read it before the run began, with the process idle
    return {"foreign_cpu_pct": round(st.mean(p["foreign_cpu_pct_sum"] for p in w), 0),
            "gpu_util_pct": round(st.mean(foreign_gpu), 1) if foreign_gpu else None,
            "load1": round(st.mean(p["load"][0] for p in w), 1)}


def med(xs):
    xs = [x for x in xs if x is not None]
    return round(st.median(xs), 3) if xs else None


pairs = collections.defaultdict(dict)
for r in rows:
    pairs[(r["task"], r["pair"])][r["provider"]] = r
for task in sorted({r["task"] for r in rows}):
    rs = [r for r in rows if r["task"] == task]
    print(f"== {task}: {len(rs)} runs, {sum(1 for r in rs if r.get('error'))} errors")
    for prov in sorted({r["provider"] for r in rs}):
        pr = [r for r in rs if r["provider"] == prov and not r.get("error")]
        calls = [c for r in pr for c in r["calls"]]
        print(f"  {prov}: wall median {med([r['wallSeconds'] for r in pr])} s (p90 {sorted(r['wallSeconds'] for r in pr)[int(0.9 * (len(pr) - 1))] if pr else None}); "
              f"calls {len(calls)}, JSON valid {sum(c['jsonValid'] for c in calls)}/{len(calls)}, truncated {sum(c['finishReason'] == 'length' for c in calls)}, "
              f"first token median {med([c['timeToFirstTokenSeconds'] for c in calls])} s; own CPU {med([r['ownProcess']['userSeconds'] + r['ownProcess']['systemSeconds'] for r in pr])} s, "
              f"own energy {med([r['ownProcess']['energyJoules'] for r in pr])} J; peak footprint {med([r['peakFootprintMB'] for r in pr])} MB; prompt tokens median {med([sum(c['promptTokens'] for c in r['calls']) for r in pr])}")
        eng = [c.get("engineFirstTokenSeconds") for c in calls]
        if any(e is not None for e in eng):
            print(f"    engine-internal first token median {med(eng)} s (from the start of the generation loop; the figure above is from the entry of chat())")
        ct = [c["constraintTiming"] for c in calls if c.get("constraintTiming")]
        if ct:
            print(f"    grammar masks: {sum(t['masks'] for t in ct)} in {len(ct)} calls; per-call p50 median {med([t['p50Seconds'] * 1000 for t in ct])} ms, "
                  f"p99 median {med([t['p99Seconds'] * 1000 for t in ct])} ms, max {round(max(t['maxSeconds'] for t in ct) * 1000, 2)} ms, first mask median {med([t['firstSeconds'] * 1000 for t in ct])} ms, "
                  f"constraint setup median {med([t['setupSeconds'] * 1000 for t in ct])} ms (max {round(max(t['setupSeconds'] for t in ct) * 1000, 1)}), additive-mask upload total median {med([t['uploadSeconds'] for t in ct])} s per call")
    for bucket in ("quiet", "moderate", "heavy"):
        ratios = collections.defaultdict(list)
        for (t, _), pair in pairs.items():
            if t != task or set(pair) != {"apple", "integrated"} or pair["apple"].get("error") or pair["integrated"].get("error"):
                continue
            if pair["apple"]["loadBucket"] != bucket:
                continue
            a, g = pair["apple"], pair["integrated"]
            ratios["wall"].append(g["wallSeconds"] / max(a["wallSeconds"], 1e-9))
            ta = med([c["timeToFirstTokenSeconds"] for c in a["calls"]]); tg = med([c["timeToFirstTokenSeconds"] for c in g["calls"]])
            if ta and tg:
                ratios["ttft"].append(tg / ta)
        if ratios["wall"]:
            print(f"  load {bucket}: {len(ratios['wall'])} pairs; Gemma / Apple wall time median {round(st.median(ratios['wall']), 2)}x"
                  + (f", time to first token {round(st.median(ratios['ttft']), 2)}x" if ratios["ttft"] else ""))
    if task == "live-answer":
        for prov in sorted({r["provider"] for r in rs}):
            pr = [r for r in rs if r["provider"] == prov and not r.get("error")]
            ans = [r for r in pr if r["detail"].get("answerable") == "true"]
            un = [r for r in pr if r["detail"].get("answerable") == "false"]
            num = lambda rr, k: [float(r["detail"][k]) for r in rr if r["detail"].get(k) not in (None, "")]
            mean = lambda xs: round(st.mean(xs), 3) if xs else None
            warm = [r for r in pr if r["detail"].get("warmPrefix") == "true"]
            cold = [r for r in pr if r["detail"].get("warmPrefix") != "true" and r["calls"]]
            ttft = lambda rr: med([c["timeToFirstTokenSeconds"] for r in rr for c in r["calls"]])
            # A refusal is an explicit found=false. An answer that was found with no verified claim is "unverified": it is not a
            # refusal and it is not counted as one. Traces from before 11a.1 have no `refused` key: no claims was the refusal then.
            # A reply with found=false and an answer of its own written under it (`refusedWithAnswer`; the app does not show that text)
            # is its own bucket: the model tried to answer, so it is neither a plain refusal nor an answer that was found.
            refused = lambda r: r["detail"].get("refused", r["detail"].get("noEvidence")) == "true"
            with_text = lambda r: r["detail"].get("refusedWithAnswer") == "true"
            unverified = lambda r: not refused(r) and not with_text(r) and int(r["detail"].get("verifiedClaims", 0)) == 0
            print(f"  {prov}: answerable {len(ans)}: with a verified claim {sum(int(r['detail']['verifiedClaims']) > 0 for r in ans)}, "
                  f"found but unverified {sum(unverified(r) for r in ans)}, refused (found=false) {sum(refused(r) for r in ans)}, "
                  f"found=false with an answer written under it {sum(with_text(r) for r in ans)}, "
                  f"citation recall {mean(num(ans, 'citationRecall'))}, precision {mean(num(ans, 'citationPrecision'))}; "
                  f"unanswerable {len(un)}: refused {sum(refused(r) for r in un)}, answered anyway {sum(not refused(r) for r in un)} (of which found=false with text {sum(with_text(r) for r in un)}); "
                  f"time to first token median cold {ttft(cold)} s ({len(cold)}), warm-prefix {ttft(warm)} s ({len(warm)}); "
                  f"wall p50/p90 {med([r['wallSeconds'] for r in pr])}/{sorted(r['wallSeconds'] for r in pr)[int(0.9 * (len(pr) - 1))] if pr else None} s")
    if task == "minutes":
        for prov in sorted({r["provider"] for r in rs}):
            pr = [r for r in rs if r["provider"] == prov and not r.get("error")]
            print(f"  {prov}: kept {sum(int(r['detail'].get('kept', 0)) for r in pr)}, dropped {sum(int(r['detail'].get('dropped', 0)) for r in pr)}, "
                  f"unconfirmed {sum(int(r['detail'].get('unconfirmed', 0)) for r in pr)}, model calls {sum(len(r['calls']) for r in pr)}")
if probe:
    print("== context (probe) of the runs")
    for r in rows[:0]:
        pass
    byb = collections.defaultdict(list)
    for r in rows:
        c = ctx(r)
        if c:
            byb[r["loadBucket"]].append(c)
    for b, cs in byb.items():
        print(f"  {b}: foreign CPU {med([c['foreign_cpu_pct'] for c in cs])}%, GPU {med([c['gpu_util_pct'] for c in cs])}%, load1 {med([c['load1'] for c in cs])} over {len(cs)} runs")

chip = [p for p in probe if isinstance(p.get("chip_energy"), dict) and "gpu_w" in p["chip_energy"] and p["chip_energy"].get("interval_s")]
if chip:
    # PRIMARY energy figure for GPU work: the chip's GPU energy over each run, integrated from the probe's intervals (each interval
    # counts for the part of it that falls inside the run). It includes every process on the GPU, so it is read with the foreign GPU
    # load next to it; `net` takes off the GPU's idle power (the median over the samples where the process under test was idle and
    # the GPU was below 5%). The per-process `own energy` (ri_energy_nj, CPU only) is the secondary figure and is not an energy
    # figure for the GPU at all.
    print("== chip-level GPU energy per run (IOReport Energy Model; PRIMARY for GPU work; includes every process on the GPU)")
    frozen = sorted({g for p in chip for g in p["chip_energy"].get("frozen_groups", [])})
    print(f"  channels that never moved (not measurable here): {frozen or 'none'}")
    idle_w = [p["chip_energy"]["gpu_w"] for p in chip if p.get("own_cpu_pct", 100) < 5 and (p.get("gpu_util_pct") or 0) < 5 and between_runs(p)]
    baseline = st.median(idle_w) if idle_w else 0.0
    print(f"  GPU idle power (samples between runs with the process under test idle and the GPU below 5%): {round(baseline, 3)} W over {len(idle_w)} samples")
    energy = []
    for r in rows:
        if r.get("error"):
            continue
        gross, covered = 0.0, 0.0
        for p in chip:
            end = p["t"] + p["chip_energy"]["interval_s"] / 2
            start = end - p["chip_energy"]["interval_s"]
            overlap = min(end, r["endedAt"]) - max(start, r["startedAt"])
            if overlap > 0:
                gross += p["chip_energy"]["gpu_w"] * overlap
                covered += overlap
        if covered >= 0.5 * (r["endedAt"] - r["startedAt"]):
            wall = r["endedAt"] - r["startedAt"]
            gross *= wall / covered   # the part of the run the probe did not cover is taken at the average of what it saw
            c = ctx(r) or {}
            energy.append({"task": r["task"], "provider": r["provider"], "item": r["item"], "wallSeconds": round(wall, 2), "gpuJoules": round(gross, 2),
                           "gpuJoulesNet": round(gross - baseline * wall, 2), "ownProcessJoules": round(r["ownProcess"]["energyJoules"], 2),
                           "foreignCpuPct": c.get("foreign_cpu_pct"), "foreignGpuPct": c.get("gpu_util_pct"), "quiet": r.get("quiet")})
    for task in sorted({e["task"] for e in energy}):
        for prov in sorted({e["provider"] for e in energy if e["task"] == task}):
            es = [e for e in energy if e["task"] == task and e["provider"] == prov]
            print(f"  {task} {prov}: GPU energy per run median {med([e['gpuJoules'] for e in es])} J (net of idle {med([e['gpuJoulesNet'] for e in es])} J) over {len(es)} runs; "
                  f"secondary, own-process CPU energy median {med([e['ownProcessJoules'] for e in es])} J; foreign CPU median {med([e['foreignCpuPct'] for e in es])}%")
    with open(os.path.join(out, "energy.json"), "w") as f:
        json.dump({"gpuIdleWatts": round(baseline, 3), "runs": energy}, f, indent=1, sort_keys=True)
    print(f"  per-run figures written to {os.path.join(out, 'energy.json')}")
