# User actions

This document summarizes user-facing flows in Olla Core.

## Deposit

```mermaid
sequenceDiagram
    participant U as User
    participant V as OllaVault
    participant C as OllaCore
    participant SAF as SafetyModule
    participant AZ as AssetToken
    participant ST as StAztec

    U->>AZ: approve(V, assets)
    U->>V: deposit(assets, recipient, minSharesOut)
    V->>SAF: isPaused()
    SAF-->>V: false
    V->>C: convertToShares(assets)
    C-->>V: shares
    V->>V: require shares >= minSharesOut
    V->>SAF: checkDepositAllowed(assets, totalAssets)
    SAF-->>V: ok
    V->>AZ: transferFrom(U, V, assets)
    V->>ST: mint(to=recipient, amount=shares)
    ST-->>U: stAztec balance updated
```

## Deposit with permit

```mermaid
sequenceDiagram
    participant U as User
    participant V as OllaVault
    participant AZ as AssetToken
    participant ST as StAztec

    U->>V: depositWithPermit(assets, recipient, minSharesOut, deadline, v, r, s)
    V->>AZ: try permit(U, V, assets, deadline, v, r, s)
    alt permit succeeds
        AZ-->>V: allowance set
    else permit fails (frontrun / expired / bad sig)
        V->>AZ: allowance(U, V)
        alt allowance >= assets
            Note right of V: Proceed (frontrun protection)
        else allowance < assets
            V-->>U: revert OllaVault__PermitFailed
        end
    end
    V->>V: _deposit(U, assets, recipient)
    V->>AZ: transferFrom(U, V, assets)
    V->>ST: mint(to=recipient, amount=shares)
    ST-->>U: stAztec balance updated
```

## Request redeem (async queue)

The redemption queue lives inside `OllaVault`. A request is locked at the current `withdrawalRate`, the shares are burned immediately, and the user later claims when the rebalance loop has finalized the request and made assets available.

```mermaid
sequenceDiagram
    participant U as User
    participant V as OllaVault
    participant C as OllaCore
    participant SAF as SafetyModule
    participant ST as StAztec

    Note over U,V: Phase 1: user requests redemption

    U->>V: requestRedeem(shares, controller, owner)
    V->>C: withdrawalRate()
    C-->>V: rate
    V->>C: convertToAssetsGross(shares)
    C-->>V: assetsExpected
    V->>SAF: checkWithdrawalMinimum(shares)
    V->>V: requestId = _nextRequestId++
    V->>V: store WithdrawalRequest{shares, assetsExpected, rate, finalized=false}
    V->>V: pendingWithdrawalAssets += assetsExpected
    V->>V: pendingWithdrawalShares += shares
    V->>ST: burn(owner=U or vault, amount=shares)
    V-->>U: emit RedeemRequest, returns requestId

    Note over U,V: Phase 2: later, after rebalance liquidity is available

    Note over V: If slashing occurred between request and finalization:
    Note over V: payout = shares * min(currentRate, lockedRate) / 1e18
    Note over V: capped at the request's recorded assetsExpected

    U->>V: claimRequestById(requestId)
    V->>V: load request, require finalized
    V->>V: _finalizedUnclaimedAssets -= request.assetsClaimable
    V-->>U: transfer asset to controller, emit Withdraw
```

## Request redeem with permit

`requestRedeemWithPermit` consumes an EIP-2612 permit on `stAztec` to set the vault's allowance, then pulls the shares to the vault before queuing the request. If the permit was frontrun but the resulting allowance is sufficient, the request still proceeds.

```mermaid
sequenceDiagram
    participant U as User
    participant V as OllaVault
    participant ST as StAztec

    U->>V: requestRedeemWithPermit(shares, controller, deadline, v, r, s)
    V->>ST: try permit(U, V, shares, deadline, v, r, s)
    alt permit succeeds
        ST-->>V: allowance set
    else permit fails (frontrun / expired / bad sig)
        V->>ST: allowance(U, V)
        alt allowance >= shares
            Note right of V: Proceed (frontrun protection)
        else allowance < shares
            V-->>U: revert OllaVault__PermitFailed
        end
    end
    V->>ST: safeTransferFrom(U, V, shares)
    Note right of V: Shares pulled to vault, consuming allowance
    V->>V: enqueue request (see "Request redeem (async queue)")
    V->>ST: burn(owner=V, amount=shares)
    Note right of V: Burns from vault's balance (not user's)
```
