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

```haskell
maxTxExecutionCPU = 10_000_000_000

maxTxExecutionMemory = 14_000_000

maxBlockExecutionCPU = 20_000_000_000

maxBlockExecutionMemory = 62_000_000
```
