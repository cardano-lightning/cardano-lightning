# cardano-lighting

Bidirectional payment channel implemented in Aiken. Implements hash time locking mechanism fully compatible with Bitcoin's Lightning Network:
  * `payment_hash=sha256(secret)`
  * |secret| == 32 bytes
  * Timelock is expressed in Cardano slots (POSIX seconds in essence) which has to be translated to Bitcoin blocks during cross-chain composition.

## Developing

We provide a at the root of this rep nix shell for development but you can use any other method to install Aiken which is the only dependency. To enter the nix shell, run:

```shell
$ nix develop
```

## Testing

We provide an extensive test and benchmarking suite. In order for it to work we are unfortunately forced to mock the signature verification function as we are not able to produce signatures in Aiken (yet).

Testing covers the same functionality as the benchmarking suite but is faster to run:

```shell
$ aiken check --env mock_verify_sig
```

To run benchmarks with the mock signature verification, use:

```shell
$ aiken bench --env mock_verify_sig
```

