---
title: "Introduction"
description: "Morpheus is Olymposuite's media-archive compression app: one-way h264 to h265 transcodes, verified before an atomic replace."
order: 0
---

# Morpheus

Morpheus is Olymposuite's **media-archive compression and optimization** app — part of the [Olymposuite](../) suite. It re-encodes video files so the archive stays storage-optimal, filling the same slot Tdarr, Unmanic, or FileFlows fill in the *arr ecosystem. The only direction is **h264 → h265 (HEVC)**; the reverse direction was removed by owner decision and is not coming back. Output is always Matroska (MKV), whatever the source container.

Morpheus works on the archive you **already have** — it is not a download-time tool. Point it at existing libraries, let it scan and rank, and apply rulesets when you are ready. Every replace is reversible for the trash retention window (7 days by default).

The trust model is **verify before replace**. A worker transcodes into a staging file; the original is never touched until every verification gate passes server-side — codec and container, duration, stream layout, a full decode, and a minimum savings threshold. Only then does an atomic rename put the new file in place, with the original hard-linked into a trash folder first, so the original path is never absent. Any failure deletes the staging file and keeps the original intact.

Morpheus ships as **two Docker images**: a management image (web UI + API + SQLite, with an embedded worker for single-container setups) and a headless worker image that claims jobs over a long-poll HTTP protocol. Scale transcode capacity by adding workers, each with its own kernel-enforced CPU quota.

- **Savings-first queue** — jobs are prioritized by expected savings in bytes, with a machine-learned estimator that calibrates itself from real outcomes.
- **Rulesets** — reusable quality/speed/verification profiles, assigned per file or per library, frozen into each job at enqueue.
- **Hardware acceleration** — CPU x265 plus Intel QSV/VAAPI in the base worker image; NVIDIA NVENC components download at runtime on GPU hosts.
- **Optional VMAF quality gate** — opt-in per ruleset, off by default, requires a libvmaf-capable ffmpeg.
- **Mount mode (experimental)** — workers process files in place over shared SMB/NFS storage, no download/upload.
- **Scheduling and guards** — night windows, pause/drain queue modes, staging disk guards, a wall-clock watchdog.
- **Realized-savings stats** — per-library counters and daily history of verified, replaced savings.

## Philosophy

A small set of non-negotiable principles runs through everything (the full list, with enforcement points, is [Invariants](./invariants)):

1. **The original is sacred.** It is never touched until every verification gate passes server-side, and the replace is an atomic rename with the original hard-linked into trash first — the original path is never absent. Any failure deletes the staging file and keeps the original intact.
2. **One direction only.** h264 → h265 is the entire codec vocabulary; the reverse was removed by owner decision and is enforced at the type level, not by convention.
3. **Savings first.** The queue is ordered by expected savings in bytes, and the estimator calibrates itself from real outcomes — the archive's biggest wins go first.
4. **Workers are disposable.** A worker can die at any moment: its lease expires, the job is requeued, and another worker restarts from scratch. No state lives on a worker that the server cannot rebuild.
5. **Budgets are hard.** "Use half the CPU" means exactly half — kernel cgroup quota and affinity, not a polite request to ffmpeg.
6. **Scanning never enqueues.** Discovery and action are separate: work enters the queue only when you assign a ruleset or ask for a transcode.

## Where to start

1. [Install](./installation) the management container, run the first-run wizard, and create a worker API key.
2. Add an archive root and [scan](./libraries) it — the file list ranks every candidate by expected savings.
3. Assign a [ruleset](./rulesets) to a library (bulk run) or a single file, and watch the Jobs page. Every output is [verified](./verification) before it replaces the original.

## User Guide

| Page | What it covers |
|------|----------------|
| [Installation](./installation) | Two images, Docker Compose walkthrough, first-run setup, worker API keys, GPU prerequisites, bare-metal pnpm |
| [Configuration](./configuration) | Every setting with defaults and ranges, environment variables, ports |
| [Libraries and scanning](./libraries) | Archive roots, the probe cache, enqueue eligibility, queue controls |
| [Rulesets](./rulesets) | Reusable profiles, the file → library → global resolution chain, assignment and bulk enqueue |
| [Transcode pipeline](./transcode-pipeline) | Job lifecycle, savings priority, what ffmpeg does, CPU budgets |
| [Verification](./verification) | The seven gates, the permanent savings rejection, replacement and trash |
| [Workers](./workers) | Embedded vs dedicated workers, leases and heartbeats, scaling, GPU provisioning, overrides |
| [Mount mode](./mount-mode) | Experimental in-place processing over shared storage, path mappings |
| [Web UI](./web-ui) | Screen tour: dashboard, libraries, files, jobs, workers, settings, keys, stats |
| [Troubleshooting](./troubleshooting) | Low-memory nodes, verify timeouts, 409s, rejections, idle workers |

Developers can continue with the [Architecture](./architecture), [Worker protocol](./worker-protocol), [Transcode engine](./transcode-engine), [Verification internals](./verification-internals), [API reference](./api-reference), [Database](./database), [Invariants](./invariants), and [Testing](./testing) pages.