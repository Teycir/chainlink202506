# Vulnerability Report: Permanent Locking of Unclaimed Funds

## Summary

A critical vulnerability exists in the `BUILDFactory` contract that allows for the permanent locking of unclaimed funds within a project's `BUILDClaim` contract. After a season has started and at least one user has claimed their allocation, any remaining, unclaimed funds from that season become impossible to withdraw by the project admin. This is due to a flaw in the logic used to calculate the maximum available amount for withdrawal.

## Vulnerability Details

The root cause of the vulnerability lies in the `_calcMaxAvailableForWithdrawalOrNewSeason` function within the `BUILDFactory.sol` contract. This function is responsible for determining the amount of surplus funds that can be withdrawn by the project admin or allocated to a new season.

The current implementation calculates the available amount as follows:

`available = totalDeposited + totalRefunded - totalWithdrawn - totalAllocatedToAllSeasons`

The critical flaw is that this calculation **does not account for funds that have already been claimed by users**. When a user claims their tokens, the `totalAllocatedToAllSeasons` value is not updated to reflect that a portion of the allocation has been fulfilled. The factory contract incorrectly assumes that the entire allocated amount is still locked and unavailable for withdrawal.

As a result, the `maxAvailable` amount returned by the function is artificially low. Any attempt by the project admin to withdraw the actual surplus funds will fail because the contract's internal accounting believes those funds are not available.

### Faulty Code

The vulnerability is located at **line 606** in `src/BUILDFactory.sol`:

```solidity
// src/BUILDFactory.sol:606
function _calcMaxAvailableForWithdrawalOrNewSeason(
    TokenAmounts memory tokenAmounts
) private pure returns (uint256) {
    // @audit high The calculation for available funds is incorrect. It subtracts `totalAllocatedToAllSeasons` but never accounts for tokens that have been claimed by users from those seasons. This causes the `maxAvailable` amount to be artificially low, permanently locking a portion of the project's funds in the `BUILDClaim` contract, as they can neither be withdrawn nor allocated to new seasons.
    return
        tokenAmounts.totalDeposited +
        tokenAmounts.totalRefunded -
        tokenAmounts.totalWithdrawn -
        tokenAmounts.totalAllocatedToAllSeasons;
}
```

## Proof of Concept (`PocFundLock.t.sol`)

The provided proof of concept, `test/PocFundLock.t.sol`, effectively demonstrates this vulnerability:

1.  **Setup**: A project is created, and a `BUILDClaim` contract is deployed.
2.  **Deposit**: The project admin deposits `1000 ether` into the `BUILDClaim` contract.
3.  **Season Configuration**: A season is configured with a total allocation of `1000 ether` split between two users (`user1` with `900 ether` and `user2` with `100 ether`).
4.  **Partial Claim**: `user1` successfully claims their `900 ether` allocation. The `BUILDClaim` contract balance is now `100 ether`.
5.  **Withdrawal Attempt**: The project admin attempts to withdraw the remaining `100 ether` surplus.
6.  **Revert**: The `scheduleWithdraw` call reverts with an `InvalidWithdrawalAmount` error. The PoC asserts this revert, proving that the `_calcMaxAvailableForWithdrawalOrNewSeason` function calculated the available amount to be `0`, thus trapping the remaining `100 ether` in the contract forever.

## Impact

The impact of this vulnerability is **High**. It leads to a permanent loss of funds for projects using the BUILD protocol. Any unclaimed tokens from a season where at least one claim has occurred will be locked in the `BUILDClaim` contract indefinitely. This directly affects the project's treasury and can lead to significant financial losses, undermining the trust and utility of the platform.

## Remediation

To fix this vulnerability, the `BUILDFactory` contract needs a mechanism to track the total amount of tokens claimed across all seasons for a given project. This can be achieved by introducing a new variable, for example `totalClaimed`, within the `TokenAmounts` struct.

The `BUILDClaim` contract would then need to call a new function on the factory to report the amount of each claim.

### Recommended Changes:

To fix this vulnerability, the `BUILDFactory` contract needs a mechanism to track the total amount of tokens claimed across all seasons for a given project. This can be achieved by introducing a new variable, for example `totalClaimed`, within the `TokenAmounts` struct.

The `BUILDClaim` contract would then need to call a new function on the factory to report the amount of each claim.

```diff
--- a/src/interfaces/IBUILDFactory.sol
+++ b/src/interfaces/IBUILDFactory.sol
@@ -103,6 +103,7 @@
         uint256 totalWithdrawn;
         uint256 totalAllocatedToAllSeasons;
         uint256 totalRefunded;
+        uint256 totalClaimed;
     }
 
     /// @notice The parameters for a scheduled withdrawal, if any

--- a/src/BUILDFactory.sol
+++ b/src/BUILDFactory.sol
@@ -603,12 +603,19 @@
     function _calcMaxAvailableForWithdrawalOrNewSeason(
         TokenAmounts memory tokenAmounts
     ) private pure returns (uint256) {
-        // @audit high The calculation for available funds is incorrect. It subtracts `totalAllocatedToAllSeasons` but never accounts for tokens that have been claimed by users from those seasons. This causes the `maxAvailable` amount to be artificially low, permanently locking a portion of the project's funds in the `BUILDClaim` contract, as they can neither be withdrawn nor allocated to new seasons.
         return
             tokenAmounts.totalDeposited +
             tokenAmounts.totalRefunded -
             tokenAmounts.totalWithdrawn -
-            tokenAmounts.totalAllocatedToAllSeasons;
+            (tokenAmounts.totalAllocatedToAllSeasons - tokenAmounts.totalClaimed);
     }
 
     // ================================================================
@@ -616,6 +623,14 @@
     // ================================================================
 
+    function updateTotalClaimed(address token, uint256 amount) external {
+        _requireRegisteredClaim(token);
+        s_tokenAmounts[token].totalClaimed += amount;
+        emit ProjectTotalClaimedUpdated(token, s_tokenAmounts[token].totalClaimed);
+    }
+
     /// @inheritdoc IBUILDFactory
     function scheduleWithdraw(
         address token,

```

Finally, the `claim` function in `BUILDClaim.sol` must be modified to call the new `updateTotalClaimed` function on the factory after a successful claim.

By implementing these changes, the factory's internal accounting will accurately reflect the state of claimed funds, ensuring that the surplus can be correctly calculated and withdrawn by the project admin.
