# Core Invariants and Accounting

## Main invariant

```solidity
// Must hold after each updateAccounting
uint256 exchangeRate = totalAssets() / stAztec.totalSupply();
```

```solidity
function totalAssets() internal view returns (uint256) {
    return bufferedAssets          // idle AZTEC sitting in OllaCore
        + stakedPrincipal          // from StakingManager.totalStaked()
        + rewardsVaultBalance      // RV.balance()
        + rewardsDelta             // from AztecRollupContract (claimable)
        - slashingDelta;           // net slashing impact (>= 0)
}
```

## Deposit

```solidity
uint256 stAztecReceived = depositAmount * stAztec.totalSupply() / totalAssets();

bufferedAssets      += depositAmount;
cumulativeDeposits  += depositAmount;
```

## User value

```solidity
uint256 userValue = userStAztecBalance * exchangeRate;
```

## Withdrawal

```solidity
uint256 assetsExpected = stAztecAmount * exchangeRateAtRequest;

cumulativeWithdrawals += assetsExpected;
```

## Accounting flow

```mermaid
sequenceDiagram
    participant OP as Operator
    participant C as OllaCore
    participant SR as StakingManager
    participant RV as RewardsVault
    participant AR as AztecRollupContract
    participant STK as stAztec
    participant T as Treasury
    participant NO as NodeOperator
    
    Note over OP,NO: Accounting = update exchange rate and mint protocol fees<br/>No AZTEC moves during accounting

    OP->>C: updateAccounting()

    Note right of C: Load previous state:<br/>- oldTotalAssets<br/>- oldSupply<br/>- lastReportDeposits<br/>- lastReportWithdrawals

    C->>C: read cumulativeDeposits and cumulativeWithdrawals
    C->>C: netDeposits = cumulativeDeposits - lastReportDeposits
    C->>C: netWithdrawals = cumulativeWithdrawals - lastReportWithdrawals
    C->>C: netFlows = netDeposits - netWithdrawals

    Note right of C: Rebuild newTotalAssets snapshot<br/>from current real plus pending balances

    C->>SR: totalStaked()
    SR-->>C: stakedPrincipal

    C->>RV: balance()
    RV-->>C: rewardsVaultBalance

    C->>AR: getValidatorState()
    AR-->>C: rewardsDelta, slashingDelta

    C->>C: newTotalAssets = bufferedAssets + stakedPrincipal + rewardsVaultBalance+ pendingRewards<br/>- slashingDelta

    C->>C: changeInAssets = newTotalAssets - oldTotalAssets
    C->>C: grossRewards = changeInAssets - netFlows

    alt grossRewards <= 0
        Note right of C: No positive rewards -> no fee minted
        C->>C: newRate = newTotalAssets / oldSupply
        C->>C: store newRate
        C->>C: lastReportDeposits = cumulativeDeposits
        C->>C: lastReportWithdrawals = cumulativeWithdrawals
        C-->>OP: AccountingUpdated(no fees)
    else grossRewards > 0
        Note right of C: Compute protocol fees<br/>protocolFeeAssets = grossRewards * feeBP / BP_DIVISOR

        C->>C: baseRate = newTotalAssets / oldSupply
        C->>C: protocolSharesTotal = protocolFeeAssets / baseRate

        C->>C: treasuryShares = protocolSharesTotal * treasurySplitBP / BP_DIVISOR
        C->>C: providerShares = protocolSharesTotal - treasuryShares

        C->>STK: mint(T, treasuryShares)
        STK-->>T: treasury stAztec increased

        C->>STK: mint(NO, providerShares)
        STK-->>NO: nodeOperator stAztec increased

        C->>C: newSupply = oldSupply + protocolSharesTotal
        C->>C: newRate = newTotalAssets / newSupply
        C->>C: store newRate

        C->>C: lastReportDeposits = cumulativeDeposits
        C->>C: lastReportWithdrawals = cumulativeWithdrawals

        C-->>OP: AccountingUpdated(fees minted)
    end
```
