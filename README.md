# Olla

*Pronounced O-Ya*

The Liquid staking protocol on Aztec network

## Overview

Olla enables decentralized staking with liquid tokens, automatic delegation, compounding, and reward tracking.

## Architecture

```mermaid
graph TD
    subgraph Users
        U1[Deposit Assets]
        U2[Receive oAztec Tokens]
    end

    subgraph "Liquid Staking Pool"
        LSP1[Collect Deposits]
        LSP2[Delegate to Validators]
        LSP3[Distribute Rewards]
        LSP4[Reinvest Rewards]
        LSP5[ERC-7540 Support]
    end

    subgraph "Validators/Node Operators"
        V1[Secure Network]
        V2[Generate Rewards]
        V3[Selected by DAO]
    end

    subgraph "oAztec Token"
        OT1[ERC-20 Standard]
        OT2[ERC-2612 Permits]
        OT3[ERC-1271 Signatures]
        OT4[Liquid & Yield-Bearing]
    end

    subgraph "Olla DAO"
        D1[Govern Protocol]
        D2[Manage Parameters]
        D3[ERC20Votes]
        D4[Governor Contracts]
    end

    U1 --> LSP1
    LSP1 --> LSP2
    LSP2 --> V1
    V1 --> V2
    V2 --> LSP3
    LSP3 --> LSP4
    LSP4 --> OT1
    OT1 --> U2
    D1 --> LSP1
    D1 --> V3
    D1 --> OT4
```

## Components

### Liquid Staking Pool

Collects deposits, delegates to validators, distributes and reinvests rewards. Supports ERC-7540 for async deposits/redemptions.

### oAztec Token

Yield-bearing ERC-20 tokens representing staked positions. Supports ERC-2612 and ERC-1271 for approvals and signatures.

### Olla DAO

Governs protocol parameters, validator selection, and upgrades. Uses ERC20Votes and Governor for on-chain voting.

### Node Operators

Run validators, secure network, generate rewards. Monitored by DAO for performance.

