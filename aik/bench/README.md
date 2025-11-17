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

### Setup

There is a helper script to run the benchmarks. Please run it from the `aik`
directory:

```shell
$ ./bin/bench.sh suite --max-size 50 --output-dir ./bench/vX.Y.Z/
```

This script will go over predefined capacities and run the benchmarks for each
of them. For every capacity it will output three JSON files:

- One containing the raw results.

- One containing the results expressed as percentages of the maximum execution
  budget.

- One containing the summary of the results pointing to the maximum capacity
  which was able to fit into the execution budget.

We preserve only the last file in the repo to not bloat it too much.

### Reading the results

#### v0.1.0

We have three results for the maximum number of steps per transaction for
different maxima of pending cheques.

- This is with maximum of 1 pending cheques
  (` bench/v0.1.0/cheques-1-max-channels.json`):
  ```json
  {
    "bench_new_channels": 60,
    "bench_add_steps": 46,
    "bench_close_steps": 36,
    "bench_respond_steps": 36,
    "bench_elapse_steps": 44,
    "bench_free_in_closed_steps": 43,
    "bench_end_resolved_steps": 60,
    "bench_elapse_end_steps": 55,
    "bench_respond_end_steps": 52
  }
  ```
- We provide also results for 10 and 20 maximum pending cheques
  (` bench/v0.1.0/cheques-10-max-channels.json` and
  ` bench/v0.1.0/cheques-20-max-channels.json`). Those eestimates show that in
  the pessimistic scenario we should be still able to execute many steps per
  transaction (most costly case is 8 resolve-end steps).

## Batching limits estimation

The happy settlement path when there are no or small number of pending cheques
is presented in the above JSON. We can see that in such a case we can batch
around 40 steps per transaction.

In order to estimate the real batching limits on the chain we should take into
account also the size of the single channel which contributes to the total
transaction size. We don't have yet full transactions builders for bidirectional
CL validators (we have them for a unidirectional channels in konduit repo) so we
can only estimate the batching limits. Let's roughly estimate that size:

- ~ 300 bytes per channel:
  - input ~33 (txout-ref)
  - output ~200 address : 32-64 value : 56 datum : own_hash : 28 keys : 64 stage
    : 10-20 min ada buffer :5 CBOR wrapping: ~10
  - redeemer: purpose : 4 value : 10 + 64
- ~ 500 bytes const for the tx

Given the 16kb tx size limit on Cardano we can estimate the maximum number of
channels in a single transaction as:

```
(16kb - .5) / .3 == 50
```

In other words we can expect that the CL batching limits will be around 30-50
channels per transaction. We will update this estimation once we have full tx
builders for bidirectional channels.
