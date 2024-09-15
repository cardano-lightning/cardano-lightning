# cardano-lightning

## Why Lightning?

- Secure: The integrity of the L1
- Near instant settlement
- Highly scalable

## Repo overview

Currently we use monorepo approach for creating the preliminary specification and POC implementation. Later on we will split this into separate repositories.

This repo uses nix flakes.

```sample
$tree -L 1
.
├── bin           # helpers
├── adrs          # Architectural Decision Records
├── design        # Sepcs and material related to the design of the protocol
├── meeting-notes # Memos recording meetings, particularly decisions and actionables
├── flake.lock
├── flake.nix
└── README.md
```
