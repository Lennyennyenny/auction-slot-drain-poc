## Auction Slot Drain PoC

This repository contains a proof-of-concept (PoC) demonstrating a storage slot drainage vulnerability in auction-style smart contracts, where improper state isolation and bid lifecycle management can lead to unintended value extraction or state corruption.

## Overview

The PoC simulates an on-chain auction mechanism where bids are tracked via storage slots. Due to flawed accounting and improper cleanup of bid state, an attacker can manipulate the system to:

Drain or overwrite reserved auction storage slots
Trigger inconsistent bid finalization states
Exploit stale or orphaned bid entries
Influence settlement logic in edge-case conditions

This is primarily a security research and educational project intended to highlight how subtle storage and lifecycle mistakes in Solidity-based auction systems can lead to exploitable behaviour.

## Key Issue Demonstrated

The vulnerability stems from a combination of:

Incomplete bid state deletion after resolution or cancellation
Weak coupling between bidder state and auction settlement logic
Reuse or mismanagement of storage slots across auction rounds
Assumptions that off-chain or front-end state reflects on-chain truth

These conditions can result in storage slot collision or “drain” scenarios, where contract state becomes inconsistent or economically exploitable.

## Impact

Depending on implementation, this class of bug can lead to:

Loss or misallocation of funds within the auction contract
Incorrect winner settlement
Persistent ghost bids affecting future auctions
Potential downstream protocol insolvency in integrated systems
Disclaimer

This project is for educational and security research purposes only. It is not intended for production use, and the patterns demonstrated here should be audited and mitigated before deployment in any live environment.

## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

- **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
- **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
