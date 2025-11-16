# cardano-lighting

Bidirectional payment channel implemented in Aiken.

Includes hash time locking mechanism fully compatible with Bitcoin's Lightning Network:
  * `payment_hash=sha256(secret)`
  * |secret| == 32 bytes
  * Timelock is expressed in Cardano slots (POSIX seconds in essence) which has to be translated to Bitcoin blocks during cross-chain composition.

## Repo structure

```shell
$ tree -L 1
.
├── aiken.lock    # Aiken dependencies
├── aiken.toml
├── bench         # Benchmarking results. Please check `bench/README.md` for more info.
├── env           # Aiken environment files used for testing and benchmarking
├── lib           # The actual smart cotract code
├── plutus.json   # Plutus script output
├── README.md
├── test-vectors  # Extra test vectors for interoperability testing
└── validators    # Thin layer of the validators which call into the lib/main.aik
```

## Developing

We provide a at the root of this rep nix shell for development but you can use any other method to install Aiken which is the only dependency. To enter the nix shell, run:

```shell
$ nix develop
```

## Testing

We provide an extensive test and benchmarking suite. In order for it to work we are unfortunately forced to mock the signature verification function as we are not able to produce signatures in Aiken (yet).

Testing covers the same functionality as the benchmarking suite but is faster to run:

```shell
$ aiken check --env testing
```

## Benchmarking

Please refer to `bench/README.md` for more information about the benchmarking suite and what kind of benchmarks we collect.

