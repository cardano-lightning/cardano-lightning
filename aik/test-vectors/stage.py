#!/usr/bin/env python3.11

import argparse
import json
import random
import sys
from dataclasses import dataclass, asdict
from typing import Dict, List, Tuple, Optional

from pyken import Blueprint

####################### Aiken Types #######################
#
# // ## Cheques
# pub type HtlcLock = Bytes32
# 
# pub type HtlcSecret {
#   Sha2_256Secret(ByteArray)
#   Sha3_256Secret(ByteArray)
#   Blake2b_256Secret(ByteArray)
# }
#
# pub type Cheque {
#   Normal(Index, Amount)
#   Htlc(Index, Timeout, HtlcLock, Amount)
#   HtlcUnlocked(Index, Timeout, HtlcSecret, Amount)
# }
# 
# // ## Channel
# 
# /// Unique 20 byte channel ID formed formed on init
# pub type ChannelId =
#   ByteArray
# 
# // ## Snapshot
# 
# pub type Exclude =
#   List<Index>
# 
# pub type Squash =
#   (Amount, Index, Exclude)
# 
# pub type Snapshot =
#   (Squash, Squash)
# 
# // ## Receipt
# pub type Receipt =
#   (Option<Signed<Snapshot>>, List<Signed<Cheque>>)
# 
# pub type HtlcLockedReduced = (Amount, Timeout, HtlcLock)
# 
# // ## Pend
# 
# pub type Pend = List<HtlcLockedReduced>
# 
# // ## Spend Redeemer
# 
# pub type Keys =
#   (VerificationKey, VerificationKey)
# 
# // ## Stages 
# pub type Stage {
#   Opened(Amount, Snapshot, Period)
#   Closed(Amount, Squash, Timeout, Pend)
#   Responded(Amount, Pend, Pend)
#   Resolved(Pend, Pend)
#   Elapsed(Pend)
# }
# type Snapshot = (Squash, Squash)
#
####################### Aiken Fixture Test/Gen Functions #######################
#
# pub fn serialise_stage_opened(amount: Amount, snapshot: t.Snapshot, period: Period) -> ByteArray {
# pub fn serialise_stage_closed(amount: Amount, squash: t.Squash, timeout: Timeout, pend: t.Pend) -> ByteArray {
#
#
## Basic flow:
#
# serialise_stage_opened = Blueprint('cl/tests/fixtures', 'serialise_stage_opened', debug=debug)
# cbor = serialise_stage_opened(0, ((0, 0, []), (0, 0, [])), 0, b"").result
# print(cbor.hex())

class BlueprintCache:
    """Cache for Blueprint functions to avoid recompilation"""
    _instance = None
    _cache: Dict[str, Blueprint] = {}

    def __new__(cls):
        if cls._instance is None:
            cls._instance = super(BlueprintCache, cls).__new__(cls)
        return cls._instance

    def __call__(self, module: str, function: str, debug: bool) -> Blueprint:
        """Get or create a Blueprint for the given module and function"""
        key = f"{module}::{function}"
        if key not in self._cache:
            self._cache[key] = Blueprint(module, function, debug=debug)
        return self._cache[key]

    def clear(self):
        self._cache.clear()

bp_cache = BlueprintCache()

@dataclass
class Amount:
    value: int
    @classmethod
    def random(cls) -> 'Amount':
        return cls(random.randint(0, 1_000_000_000_000_000))

    def to_data(self):
        return self.value

@dataclass
class Index:
    value: int
    @classmethod
    def random(cls) -> 'Index':
        return cls(random.randint(0, 1_000_000_000))

    def to_data(self):
        return self.value

@dataclass
class Period:
    value: int
    @classmethod
    def random(cls) -> 'Period':
        return cls(random.randint(1000, 10000))

    def to_data(self):
        return self.value

@dataclass
class Exclude:
    indices: List[int]
    @classmethod
    def random(cls) -> 'Exclude':
        size = random.randint(0, 10)
        return cls([random.randint(0, 1_000_000_000) for _ in range(size)])

    def to_data(self):
        return self.indices

@dataclass
class Squash:
    amount: Amount
    index: Index
    exclude: Exclude
    @classmethod
    def random(cls) -> 'Squash':
        return cls(
            Amount.random(),
            Index.random(),
            Exclude.random()
        )

    def to_data(self):
        return (self.amount.to_data(), self.index.to_data(), self.exclude.to_data())

@dataclass
class Snapshot:
    squash1: Squash
    squash2: Squash
    @classmethod
    def random(cls) -> 'Snapshot':
        return cls(Squash.random(), Squash.random())

    def to_data(self):
        return (self.squash1.to_data(), self.squash2.to_data())

@dataclass
class TestVector:
    constructor: str
    inputs: dict
    cbor: str

# Enable debug mode for Blueprint
debug = True

def generate_opened_vector() -> TestVector:
    """Generate a random test vector for Stage::Opened constructor"""
    amount = Amount.random()
    snapshot = Snapshot.random()
    period = Period.random()

    # Load and call the Aiken function
    serialise = bp_cache('cl/tests/fixtures', 'serialise_stage_opened', debug=debug)
    cbor_bytes = serialise(amount.to_data(), snapshot.to_data(), period.to_data()).result

    return TestVector(
        constructor="Opened",
        inputs={
            "amount": amount.to_data(),
            "snapshot": snapshot.to_data(),
            "period": period.to_data()
        },
        cbor=cbor_bytes.hex()
    )

def generate_vectors(args) -> List[TestVector]:
    """Generate specified number of test vectors"""
    vectors = [generate_opened_vector() for _ in range(args.count)]
    output = json.dumps([asdict(v) for v in vectors], indent=2)
    if args.output:
        with open(args.output, 'w') as f:
            f.write(output)
    else:
        print(output)

def register_gen_subparser(gen_subparsers):
    # stage subcommand
    stage_parser = gen_subparsers.add_parser('stage', help='Generate Stage test vectors')
    stage_parser.add_argument('--output', type=str, help='Output JSON file path')
    stage_parser.add_argument('--count', type=int, default=20, help='Number of test vectors to generate')
    stage_parser.set_defaults(func=generate_vectors)

