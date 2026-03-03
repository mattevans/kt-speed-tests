# kt-speed-tests

Benchmarking [ethereum-package](https://github.com/ethpandaops/ethereum-package) boot times under different conditions using [Kurtosis](https://github.com/kurtosis-tech/kurtosis).

## What this measures

Each workflow boots an ethereum-package network 3 times:

1. **Cold cache** (`--image-download always`) — All images force-pulled from registries. Simulates a first-ever boot.
2. **Warm cache** (`--image-download missing`) — Images already cached locally from run 1. Measures pure orchestration overhead.
3. **Warm + always pull** (`--image-download always`) — Images cached but registry checks still happen. Measures the cost of pull checks alone.

## Workflows

| Workflow | Config | Participants |
|----------|--------|-------------|
| `bench-single-client` | `configs/single-client.yaml` | 1x geth/lighthouse |
| `bench-multi-client` | `configs/multi-client.yaml` | 9x (3 EL types x 3 CL types) |

Both run on `workflow_dispatch` (manual) and on push to `main`.

## Running locally

```bash
# Requires: kurtosis, docker, jq, bc

# Single benchmark run:
./scripts/run-benchmark.sh configs/single-client.yaml my-test missing

# Full benchmark suite:
export RESULTS_DIR=./results
./scripts/run-benchmark.sh configs/single-client.yaml single-cold always
./scripts/run-benchmark.sh configs/single-client.yaml single-warm missing
./scripts/summarize.sh ./results
```

## Results

Results are uploaded as GitHub Actions artifacts and rendered in the job summary.
