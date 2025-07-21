# Audit Report: Pause Mechanism Bypass in `BUILDClaim.withdraw`

- **ID:** POC-PAUSE-BYPASS
- **Severity:** High
- **Type:** Access Control
- **Status:** Unresolved

## Summary

The `BUILDClaim.withdraw()` function can be executed even when the associated project claim contract is paused. This bypasses the intended emergency stop mechanism, allowing a project admin to withdraw funds during a pause, which could be detrimental if the pause was initiated to prevent malicious activity or to handle a critical issue.

## Vulnerability Details

The `BUILDClaim` contract includes a `whenClaimNotPaused` modifier that checks with the `BUILDFactory` contract to see if the claim functionality for a specific project token is paused. This modifier is correctly applied to the `deposit()` and `claim()` functions, preventing these actions during a pause.

However, the `withdraw()` function in `BUILDClaim.sol` is missing this modifier. As a result, even if a `PAUSER_ROLE` holder pauses the contract via `BUILDFactory.pauseClaimContract()`, the `PROJECT_ADMIN` can still successfully call `withdraw()` and retrieve funds from the contract.

### Affected Contracts

- `src/BUILDClaim.sol`
- `src/BUILDFactory.sol`

## Proof of Concept (PoC)

The following test case demonstrates the vulnerability. A withdrawal is scheduled, the contract is paused, and then the withdrawal is executed successfully, which should have been reverted.

```solidity
// test/PoCPauseBypass.t.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IBUILDFactory} from "src/interfaces/IBUILDFactory.sol";
import {BaseTest} from "./BaseTest.t.sol";

contract PoCPauseBypass is BaseTest {
    address public pauser = makeAddr("pauser");

    function test_PoC_WithdrawalSucceedsWhenPaused()
        public
        whenProjectAddedAndClaimDeployed
    {
        // --- 1. Setup funds and schedule a valid withdrawal ---
        uint256 withdrawalAmount = 200 ether;

        // Use `deal` to give the project admin the exact amount of tokens needed for the test.
        deal(address(s_token), PROJECT_ADMIN, withdrawalAmount);

        _changePrank(PROJECT_ADMIN);
        s_token.approve(address(s_claim), withdrawalAmount);
        s_claim.deposit(withdrawalAmount);

        _changePrank(ADMIN);
        s_factory.scheduleWithdraw(
            address(s_token),
            PROJECT_ADMIN,
            withdrawalAmount
        );

        // --- 2. Pause the contract ---
        _changePrank(ADMIN);
        s_factory.grantRole(s_factory.PAUSER_ROLE(), pauser);
        _changePrank(pauser);
        s_factory.pauseClaimContract(address(s_token));

        // --- 3. Execute the withdrawal ---
        // This call should revert because the contract is paused, but it will succeed,
        // proving the vulnerability. A passing test here is a proof of concept.
        _changePrank(PROJECT_ADMIN);
        s_claim.withdraw();
    }
}
```

## Impact

The primary impact is the failure of a critical safety feature. The pause mechanism is designed to be a last line of defense to freeze contract activity in case of an exploit, bug, or other emergency. If a project admin's keys are compromised, an attacker could drain the project's funds via `withdraw()` even if a security-conscious pauser has already frozen the contract. This undermines the trust in the system's safety protocols and could lead to a complete loss of withdrawable funds.

## Recommendation

Apply the `whenClaimNotPaused` modifier to the `withdraw()` function in `BUILDClaim.sol`. This will ensure that withdrawals are subject to the same pause mechanism as deposits and claims, creating a consistent and secure emergency stop functionality.

### Diff

```diff
--- a/src/BUILDClaim.sol
+++ b/src/BUILDClaim.sol
@@ -120,7 +120,7 @@
     // ================================================================
 
     /// @inheritdoc IBUILDClaim
-    function withdraw() external override nonReentrant onlyProjectAdmin {
+    function withdraw() external override nonReentrant onlyProjectAdmin whenClaimNotPaused {
         (
             IBUILDFactory.Withdrawal memory withdrawal,
             uint256 totalWithdrawn
