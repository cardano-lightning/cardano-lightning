# cardano-lightning

## Why Lightning?

- Secure: The integrity of the L1
- Near instant settlement
- Highly scalable

## Overview

Bidirectional payment channels inspired and compatible with Bitcoin Lightning Network. Core protocol design (L1 and L2) together with smart contracts.

Unidirectional but still composable payment channels with instant settlement are implemented separately in the [konduit](https://github.com/cardano-lightning/konduit) repo.

## Repo overview

```shell
$tree -L 1
.
├── aik           # Smart contracts together with tests and benchmarks
├── docs          # Documentation, ADRs, meeting notes.
├── flake.lock    # Dev env
├── flake.nix
└── README.md
```

Please refer to specific READMEs in each subdir for more information.

## Development

### Using nix

For the base devel flow (Aiken compiler):

```shell
$ nix develop
```

For a shell with additional tools required for more testing and **documentation** (mermaid-cli, plantuml):

```shell
$ nix develop .#extras
```
