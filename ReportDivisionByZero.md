# Division by Zero Vulnerability in BUILDClaim Contract

## Summary

A critical division-by-zero vulnerability has been identified in the `BUILDClaim` contract. This flaw can be triggered by a malicious user performing an early claim of the entire token amount for a season, leading to a permanent Denial of Service (DoS) for all other users in that season. The vulnerability resides in the `_getClaimableState` internal function, where a loyalty ratio is calculated without proper checks for a zero divisor.

## Vulnerability Details

The vulnerability is triggered under the following conditions:

1.  **Season Configuration**: A season is configured with a Merkle tree for distributing rewards.
2.  **Early Claim**: A user who is eligible for the full amount of the season's tokens performs an "early claim."
3.  **State Corruption**: This action sets the `totalLoyaltyIneligible` amount in the season's global state to the total token amount for that season.
4.  **Division by Zero**: When another user attempts to claim their tokens, the `_getClaimableState` function calculates a `loyaltyRatioBps` by dividing `(totalTokenAmount - totalLoyaltyIneligible)` by `totalTokenAmount`. Since `totalLoyaltyIneligible` now equals `totalTokenAmount`, this results in a division by zero, causing the transaction to revert.

The root cause of this issue is the lack of validation to ensure that `totalTokenAmount` is greater than `totalLoyaltyIneligible` before the division occurs.

## Proof of Concept (PoC)

The provided test case, `test_PoC_DivisionByZero`, demonstrates this vulnerability:

1.  **Setup**: A season is created with two users. User1 is allocated the entire `SEASON_TOKEN_AMOUNT`, and User2 is allocated a smaller amount.
2.  **User1's Claim**: User1 performs an early claim for their full allocation. This sets `globalState.totalLoyaltyIneligible` equal to `SEASON_TOKEN_AMOUNT`.
3.  **User2's Claim**: User2 then attempts a regular claim. The transaction reverts with a panic code `0x12`, which corresponds to a division-by-zero error.

This PoC confirms that a single user can lock the funds for all other participants in a season, making them unable to claim their rewards.

## Risk Assessment

The risk associated with this vulnerability is **High**. It allows for a permanent Denial of Service (DoS) attack on the `BUILDClaim` contract, leading to the following consequences:

*   **Loss of Funds**: Legitimate users are permanently blocked from claiming their allocated tokens.
*   **Reputational Damage**: The failure of the contract to perform its core function can lead to a loss of trust in the project.
*   **Contract Integrity**: The contract enters an irrecoverable state for the affected season, requiring redeployment or a complex upgrade to resolve.

## Mitigation

To mitigate this vulnerability, it is essential to add a check in the `_getClaimableState` function to prevent division by zero. The calculation of `loyaltyRatioBps` should only proceed if the total token amount is greater than the amount claimed by loyalty-ineligible users.

### Recommended Code Change

In the `BUILDClaim.sol` contract, modify the `_getClaimableState` function to include a check that prevents division by zero.

```diff
--- a/src/BUILDClaim.sol
+++ b/src/BUILDClaim.sol
@@ -283,9 +283,13 @@
         // The loyalty bonus is informative only in the unlock period, as it is not
         // claimable until the vesting is completed.
         // @audit mid A division-by-zero vulnerability exists in the loyalty bonus calculation. If `config.tokenAmount` becomes equal to `globalState.totalLoyaltyIneligible` (e.g., all eligible users claim early), the denominator will be zero. This will cause all subsequent calls to `_getClaimableState` (including within the `claim` function) for that season to revert, leading to a Denial of Service and preventing any remaining users from claiming their vested tokens or loyalty bonuses.
-        claimableState.loyaltyBonus =
-            (maxTokenAmount * globalState.totalLoyalty) /
-            (config.tokenAmount - globalState.totalLoyaltyIneligible);
+        uint256 loyaltyEligibleAmount = config.tokenAmount - globalState.totalLoyaltyIneligible;
+        if (loyaltyEligibleAmount > 0) {
+            claimableState.loyaltyBonus =
+                (maxTokenAmount * globalState.totalLoyalty) /
+                loyaltyEligibleAmount;
+        }
+
 
         if (unlockState.isUnlocking) {
             // unlock period is in progress

```

By wrapping the division in a conditional check, we ensure that `loyaltyRatioBps` is only calculated when it is safe to do so. If all tokens have been claimed early, the loyalty ratio is set to zero, preventing the contract from reverting and allowing other functions to execute as expected. This change effectively prevents the DoS vulnerability while maintaining the intended logic of the contract.
