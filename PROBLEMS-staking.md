# Problems with implementation

1. We can probably not assume that the available stake when initiating unstake is the same as when the unstake finalizes.
1. Also, available to unstake should be calculated when unstakeInternal is called (validators may have been slashed)
