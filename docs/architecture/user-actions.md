# User actions

This document summarizes user-facing flows in Olla Core.

## Deposit

```mermaid
sequenceDiagram
    participant U as User
    participant C as OllaCore
    participant SAF as SafetyModule
    participant AZ as AssetToken
    participant ST as StAztec

    U->>C: deposit(assets, recipient)
    C->>SAF: isPaused()
    SAF-->>C: false
    C->>SAF: checkDepositAllowed(assets, totalAssets)
    SAF-->>C: true
    C->>C: shares = convertToShares(assets)
    C->>C: bufferedAssets += assets
    U->>AZ: approve(C, assets)
    C->>AZ: transferFrom(U, C, assets)
    C->>C: syncBufferedWithBalance()
    C->>ST: mint(to=recipient, amount=shares)
    ST-->>U: stAztec balance updated
```

## Withdrawal (queue)

```mermaid
sequenceDiagram
    participant U as User
    participant C as OllaCore
    participant SAF as SafetyModule
    participant ST as StAztec
    participant WQ as WithdrawalQueue
    participant AZ as AssetToken

    Note over U,C: Phase 1 - user requests withdrawal

    U->>C: requestRedeem(shares, recipient)
    C->>C: require no active request for U
    C->>C: rate = exchangeRate
    C->>C: assetsExpected = shares * rate / 1e18
    C->>SAF: checkWithdrawalMinimum(shares)
    C->>WQ: nextRequestId()
    C->>ST: burn(owner=U, amount=shares)
    C->>WQ: requestWithdrawal(recipient, shares, assetsExpected, rate)
    WQ->>WQ: enqueue withdrawalRequest (FIFO)

    Note over U,WQ: Phase 2 - later, after liquidity and operator action
    Note over WQ: If slashing occurred after request, finalization adjusts:
    Note over WQ: payout = shares * min(currentRate, lockedRate) / 1e18

    U->>C: claimRequestById(requestId)
    C->>WQ: claimWithdrawal(requestId)
    WQ-->>C: assetsClaimed
    C->>AZ: transfer(recipient, assetsClaimed)
```

## Instant redemption

```mermaid
sequenceDiagram
    participant U as User
    participant C as OllaCore
    participant SAF as SafetyModule
    participant ST as StAztec
    participant AZ as AssetToken

    U->>C: redeem(shares, recipient)
    C->>SAF: isPaused()
    SAF-->>C: false
    C->>C: syncBufferedWithBalance()
    Note right of C: bufferedAssets = balance - _finalizedUnclaimedAssets
    C->>SAF: checkWithdrawalMinimum(shares)
    C->>C: grossAssets = convertToAssets(shares)
    C->>C: fee = grossAssets * feeBP / BP_DIVISOR
    C->>C: netAssets = grossAssets - fee
    C->>C: available = bufferedAssets - pendingWithdrawalAssets
    C->>C: require netAssets <= available
    C->>ST: burn(owner=U, amount=shares)
    C->>C: bufferedAssets -= netAssets
    Note right of C: Fee stays in buffer, accruing to remaining shareholders
    C->>AZ: transfer(recipient, netAssets)
    C-->>U: netAssets
```
