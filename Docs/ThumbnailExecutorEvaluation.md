# Bounded thumbnail executor evaluation

Evaluated 29 October 2026 with Xcode 27.1 (27A9275), Swift 6 mode and macOS 27.2 on Apple Silicon. This change makes thumbnail decode work explicitly use the concurrent executor while retaining the existing six-slot admission bound.

## Problem and change

The package enables MainActor default isolation and NonisolatedNonsendingByDefault. An asynchronous closure and a concurrency limiter do not by themselves ensure that synchronous decode work runs concurrently. A standalone probe of the pinned implementation observed one overlapping decode despite six admitted slots; the candidate observed six. Increasing caller count increased individual request latency while batch throughput stayed similar.

Move the existing decode body to a private static async helper marked @concurrent, called inside thumbnailDecodeLimiter.run. The slot remains held until decoding returns. Preserve the existing shared request map, priority, cancellation checks, rendered-image / RAW 9 / embedded-thumbnail / format fallback order, orientation normalization and NSImage construction. No public API, limiter implementation or full-size preview path changes.

## Evidence

The evaluated baseline was RawParserKit revision 07801a34a82d7720d301a80724c36a5b8c9f1d6c. Upstream main at preparation (4b3bf40) has identical RawImageLoader.swift and Package.swift content. The submitted implementation differs from the measured candidate only by an explanatory source comment.

Standalone Release experiments completed 54 runs; output pixels matched across all 82 Sony ARW inputs (56-file large cohort and 26-file small cohort). At 56 callers, large-batch elapsed time was about 399–401 ms baseline versus 110–113 ms candidate; small batches about 187–188 versus 57–60 ms. Candidate CPU usage increased and measured peak memory was about 6 MB higher. This is a throughput/latency tradeoff, not a CPU-saving claim.

Three new paired sandboxed RawBrowse Release app trials per variant used empty disposable thumbnail caches, followed by fresh processes reusing those caches. App sources, settings, window dimensions and inputs matched across variants. Builds/tests did not overlap timing runs. OS/storage caches were not flushed. Time is earliest model request to last accepted image assignment in each fixed initial cohort, not first painted frame or whole-catalog completion:

| Condition | Baseline trials (ms) | Candidate trials (ms) | Baseline median | Candidate median |
| --- | --- | --- | ---: | ---: |
| Empty, 56 images | 991.56 / 978.46 / 904.87 | 381.83 / 362.14 / 382.75 | 978.46 | 381.83 |
| Empty, 26 images | 429.53 / 540.71 / 391.46 | 126.16 / 118.97 / 121.77 | 429.53 | 121.77 |
| Warm disk, 56 images | 59.79 / 69.35 / 58.41 | 72.55 / 58.60 / 73.89 | 59.79 | 72.55 |
| Warm disk, 26 images | 56.15 / 52.94 / 60.40 | 59.08 / 57.43 / 52.71 | 56.15 | 57.43 |

Empty-cache median windows decreased 61% and 72%. Warm disk made no parser calls and showed no established benefit; the larger warm candidate median is slower, with overlapping ranges. All fixed cohorts completed and registered image tasks drained in all twelve runs. Baseline empty trial 4 had long automation pauses outside cohort timing windows; subsequent sequences were compact. A separate earlier three-pair app cohort also showed an empty-cache improvement, but different binary identities are not pooled here.

One separate interaction sequence per variant exercised scroll down/up, keyboard selection, JPG preview navigation and folder switches. Each switched while 152 thumbnail requests were in flight, recorded 652 accepted and 152 cancelled presentation deliveries, and drained all image tasks. Settled screenshots looked correct. Time Profiler-only captures saved and exported samples, but action-window differences prevent quantitative CPU comparison. No hitch or painted-frame improvement is claimed.

## Review and integration limits

The previous uninstrumented candidate package passed 105 tests. The evaluated candidate app passed its full macOS suite and both app variants built in Release. On current upstream main plus this patch, both full Debug and Release package suites passed: 105 tests in 16 suites each.

Evidence covers these ARW inputs and existing format tests, not an exhaustive mixed-format or RAW 9 performance matrix. App CPU/memory attribution and painted-frame/hitch timings remain unmeasured. Synchronous decoding remains non-preemptive between existing cancellation checks. No claim of a stronger cancellation contract is made.

Review this bounded executor placement independently of any downstream dependency update. RawBrowse's production dependency pin is unchanged. No release or tag is created by this proposal.
