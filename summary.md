# Kurtosis Benchmark: Baseline vs Patched

**Runner:** x86_64 / Linux
**Date:** 2026-03-04T05:05:36Z
**Baseline:** bench-baseline (cf51988)
**Patched:** refactor/boot-perf (9b50ace)

## Wall Clock Comparison

| Config | Package | Baseline | Patched | Delta | Improvement |
|--------|---------|----------|---------|-------|-------------|
| multi-client | local | 119.35s | 97.33s | -22.02s | 18.4% |
| multi-client | remote | 102.52s | 104.78s | 2.26s | -2.2% |
| single-client | local | 35.64s | 30.20s | -5.44s | 15.3% |
| single-client | remote | 33.93s | 28.13s | -5.80s | 17.1% |

## APIC Phase Breakdown: multi-client / local

| Phase | Baseline | Patched | Delta |
|-------|----------|---------|-------|
| GetAvailableCPUAndMemory | 2.03s | 0.00s | -2.03s |
| GetServiceNames | 0.00s | 0.00s | 0.00s |
| ImagesValidator.Validate | 1.62s | 0.02s | -1.60s |
| RunStarlarkPackage setup | 0.00s | 0.00s | -0.00s |
| RunStarlarkPackage total | 117.59s | 96.05s | -21.54s |
| StartosisRunner.Run total | 117.59s | 96.05s | -21.54s |
| StartosisValidator.Validate total | 3.65s | 0.02s | -3.62s |
| UploadStarlarkPackage total | 0.15s | 0.13s | -0.02s |
| execution phase | 113.04s | 95.37s | -17.68s |
| getServiceNameToPortIDsMap | 0.00s | 0.00s | 0.00s |
| interpretation | 0.89s | 0.65s | -0.24s |
| package store/decompress | 0.11s | 0.10s | -0.00s |
| runStarlarkPackageSetup: package resolution | 0.00s | 0.00s | -0.00s |
| validateAndUpdateEnvironment | 0.00s | 0.00s | 0.00s |
| validateImagesAccountingForProgress | 1.62s | 0.02s | -1.60s |
| validation phase | 3.65s | 0.03s | -3.62s |
| validator env setup total | 2.03s | 0.00s | -2.03s |

## APIC Phase Breakdown: multi-client / remote

| Phase | Baseline | Patched | Delta |
|-------|----------|---------|-------|
| GetAvailableCPUAndMemory | 2.03s | 0.00s | -2.03s |
| GetServiceNames | 0.00s | 0.00s | 0.00s |
| ImagesValidator.Validate | 0.03s | 0.03s | 0.00s |
| RunStarlarkPackage setup | 1.18s | 1.21s | 0.03s |
| RunStarlarkPackage total | 101.25s | 103.65s | 2.40s |
| StartosisRunner.Run total | 100.07s | 102.44s | 2.37s |
| StartosisValidator.Validate total | 2.05s | 0.03s | -2.02s |
| execution phase | 97.24s | 101.62s | 4.38s |
| getServiceNameToPortIDsMap | 0.00s | 0.00s | 0.00s |
| interpretation | 0.77s | 0.78s | 0.01s |
| runStarlarkPackageSetup: package resolution | 1.18s | 1.21s | 0.03s |
| validateAndUpdateEnvironment | 0.00s | 0.00s | 0.00s |
| validateImagesAccountingForProgress | 0.03s | 0.03s | 0.00s |
| validation phase | 2.05s | 0.03s | -2.02s |
| validator env setup total | 2.03s | 0.00s | -2.03s |

## APIC Phase Breakdown: single-client / local

| Phase | Baseline | Patched | Delta |
|-------|----------|---------|-------|
| GetAvailableCPUAndMemory | 2.03s | 0.00s | -2.03s |
| GetServiceNames | 0.00s | 0.00s | 0.00s |
| ImagesValidator.Validate | 0.02s | 0.02s | 0.00s |
| RunStarlarkPackage setup | 0.00s | 0.00s | 0.00s |
| RunStarlarkPackage total | 32.32s | 27.72s | -4.59s |
| StartosisRunner.Run total | 32.32s | 27.72s | -4.60s |
| StartosisValidator.Validate total | 2.05s | 0.02s | -2.03s |
| UploadStarlarkPackage total | 0.14s | 0.14s | -0.00s |
| execution phase | 29.41s | 27.01s | -2.40s |
| getServiceNameToPortIDsMap | 0.00s | 0.00s | 0.00s |
| interpretation | 0.86s | 0.69s | -0.17s |
| package store/decompress | 0.10s | 0.10s | -0.00s |
| runStarlarkPackageSetup: package resolution | 0.00s | 0.00s | 0.00s |
| validateAndUpdateEnvironment | 0.00s | 0.00s | 0.00s |
| validateImagesAccountingForProgress | 0.02s | 0.02s | 0.00s |
| validation phase | 2.05s | 0.02s | -2.03s |
| validator env setup total | 2.03s | 0.00s | -2.03s |

## APIC Phase Breakdown: single-client / remote

| Phase | Baseline | Patched | Delta |
|-------|----------|---------|-------|
| GetAvailableCPUAndMemory | 2.03s | 0.00s | -2.03s |
| GetServiceNames | 0.00s | 0.00s | 0.00s |
| ImagesValidator.Validate | 0.01s | 0.01s | 0.00s |
| RunStarlarkPackage setup | 1.18s | 1.18s | -0.00s |
| RunStarlarkPackage total | 33.02s | 27.18s | -5.83s |
| StartosisRunner.Run total | 31.84s | 26.00s | -5.84s |
| StartosisValidator.Validate total | 2.04s | 0.02s | -2.03s |
| execution phase | 29.33s | 25.49s | -3.83s |
| getServiceNameToPortIDsMap | 0.00s | 0.00s | 0.00s |
| interpretation | 0.46s | 0.49s | 0.03s |
| runStarlarkPackageSetup: package resolution | 1.18s | 1.18s | -0.00s |
| validateAndUpdateEnvironment | 0.00s | 0.00s | -0.00s |
| validateImagesAccountingForProgress | 0.01s | 0.02s | 0.00s |
| validation phase | 2.04s | 0.02s | -2.03s |
| validator env setup total | 2.03s | 0.00s | -2.03s |

