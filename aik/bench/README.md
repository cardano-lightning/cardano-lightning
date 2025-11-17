# Benchmarking

We group the benchmarks by the validators version. Please create a dedicated
directory for each version. It is quite probable that the structure of the
benchmarks will evolve over time together with the protocol changes but there
will be still some commonalities. What we really want to understand is an
approximate batching limit of a given operation imposed by the on-chain maximum
execution budget. This limit should be parametrized by the number of pending
cheques. That capacity threshold should be adjusted to the usage pattern of a
given channel - a gateway to gateway channel which rarely settles could afford a
higher capacity than a channel between a customer and a gateway which settles
often and should be aggressively batched.

We provide an extra script which takes the results and computes the percentile
of the limits for a given operation which was tested:

## Running the benchmarks

There is a helper script to run the benchmarks. Please run it from the `aik` directory:

```shell
$ ./bin/bench.sh suite --max-size 50 --output-dir ./bench/vX.Y.Z/
```

This script will go over predefined capacities and run the benchmarks for each of them. For every capacity it will output three JSON files:

* One containing the raw results.

* One containing the results expressed as percentages of the maximum execution budget.

* One containing the summary of the results pointing to the maximum capacity which was able to fit
  into the execution budget.

The execution budget used in the computations is according to the current Cardano protocol parameters.

## Benchmark results


