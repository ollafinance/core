# Problems with implementation

1. We can probably not assume that the available stake when initiating unstake is the same as when the unstake finalizes.
1. Also, available to unstake should be calculated when unstakeInternal is called (validators may have been slashed)
1. Is "active" a good word for the validators? Some might be ZOMBIE (because they go slashed too much)
