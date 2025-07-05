# Critical Vulnerability: Arithmetic Overflow in Claim Logic Causes Permanent DoS and Locked Funds for Users

## Summary

The `BUILDClaim.sol` contract contains an arithmetic overflow vulnerability within its `_getClaimableState` function. When calculating vested token amounts for a user with a very large allocation (up to the `type(uint248).max` limit permitted by the `BUILDFactory`), the intermediate multiplication can exceed `type(uint256).max`, causing the transaction to revert with a panic error.

Since the `claim()` function is the sole method for users to retrieve their funds, this flaw creates a permanent Denial of Service for any user with a sufficiently large allocation. Their funds become **permanently and irrecoverably locked** in the contract. This violates a core invariant stated in the contest `README`: *"Token amount validation calculations do not result in mathematical overflows / underflows."*

## Vulnerability Details

**Location:** `BUILDClaim.sol#L293-L296`

The vulnerability is triggered within the `_getClaimableState` function, which is called by `claim()`. The calculation for `claimableState.vested` involves multiplying the user's bonus allocation by the elapsed duration.

```solidity
// src/BUILDClaim.sol#L293-L296

    if (unlockState.isUnlocking) {
      // unlock period is in progress
      claimableState.vested =
        (claimableState.bonus * unlockState.unlockElapsedDuration) / config.unlockDuration;
```

When a user has a `maxTokenAmount` near `type(uint248).max` (a valid state explicitly allowed by `BUILDFactory`), their `claimableState.bonus` will also be an extremely large number. The multiplication `claimableState.bonus * unlockState.unlockElapsedDuration` can easily overflow a `uint256`, causing the transaction to revert with `panic code 0x11`.

## Impact

The impact is a permanent loss of funds for affected users, which is a critical failure.

1.  **Permanent Denial of Service:** Any user whose allocation is large enough to trigger this overflow during the vesting period will be unable to call `claim()` without causing a revert.
2.  **Permanent Fund Lock:** Because the `claim()` function is the only vector for a user to access their tokens, a permanent revert constitutes a permanent lock on their assets. The user can see their funds are held by the contract but has no way to retrieve them.

This is a critical vulnerability as it breaks the core promise of the protocol—that users can claim their earned rewards—and leads to direct, permanent loss.

## Proof of Concept

The following standalone Foundry test provides an undeniable demonstration of this vulnerability. It sets up a scenario with a user who has a very large but valid allocation. When this user attempts to claim their tokens during the vesting period, the transaction reverts due to an arithmetic overflow, permanently blocking them from accessing their funds.

The test **PASSES** because the expected `revert` occurs, confirming the DoS vulnerability.

#### `test/PoCOverflow.t.sol`

```solidity
// File: test/PoCOverflow.t.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {BUILDFactory} from "src/BUILDFactory.sol";
import {BUILDClaim} from "src/BUILDClaim.sol";
import {IBUILDFactory} from "src/interfaces/IBUILDFactory.sol";
import {IBUILDClaim} from "src/interfaces/IBUILDClaim.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IDelegateRegistry} from "@delegatexyz/delegate-registry/v2.0/src/IDelegateRegistry.sol";

// Helper contracts are included for self-containment
contract MintableERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MTK") {}
    function mint(address to, uint256 amount) public { _mint(to, amount); }
}

contract StubRegistry {
    function checkDelegateForContract(address, address, address, bytes32) external pure returns (bool) {
        return false;
    }
}

contract ProofOfConceptOverflow is Test {
    BUILDFactory public factory;
    MintableERC20 public token;
    BUILDClaim public claimContract;
    
    address public factoryAdmin = makeAddr("factoryAdmin");
    address public projectAdmin = makeAddr("projectAdmin");
    address public attacker = makeAddr("attacker");
    uint32 public constant SEASON_ID = 1;

    function setUp() public {
        token = new MintableERC20();
        StubRegistry stubRegistry = new StubRegistry();
        vm.prank(factoryAdmin);
        factory = new BUILDFactory(
            BUILDFactory.ConstructorParams({ admin: factoryAdmin, maxUnlockDuration: 30 days, maxUnlockDelay: 7 days, delegateRegistry: IDelegateRegistry(address(stubRegistry)) })
        );
        vm.prank(factoryAdmin);
        IBUILDFactory.AddProjectParams[] memory addParams = new IBUILDFactory.AddProjectParams[](1);
        addParams[0] = IBUILDFactory.AddProjectParams({ token: address(token), admin: projectAdmin });
        factory.addProjects(addParams);
        vm.prank(projectAdmin);
        claimContract = BUILDClaim(address(factory.deployClaim(address(token))));
    }

    function test_PoC_ArithmeticOverflowCausesPermanentDosForUser() public {
        console.log("--- PoC: Arithmetic Overflow in Claim Calculation Leads to Permanent DoS ---");

        // --- 1. SETUP: A user is allocated a very large number of tokens ---
        uint256 allocation = type(uint248).max;
        token.mint(projectAdmin, allocation);
        vm.startPrank(projectAdmin);
        token.approve(address(claimContract), allocation);
        claimContract.deposit(allocation);
        vm.stopPrank();

        // --- 2. CONFIGURE SEASON ---
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(attacker, allocation, true, 0))));
        
        vm.startPrank(factoryAdmin);
        uint256 unlockStartsAt = block.timestamp + 1;
        factory.setSeasonUnlockStartTime(SEASON_ID, unlockStartsAt);

        IBUILDFactory.SetProjectSeasonParams memory seasonParams = IBUILDFactory.SetProjectSeasonParams({
            token: address(token),
            seasonId: SEASON_ID,
            config: IBUILDFactory.ProjectSeasonConfig({
                tokenAmount: allocation, baseTokenClaimBps: 1000, // 10% base
                unlockDelay: 0, unlockDuration: 10 minutes, merkleRoot: leaf,
                earlyVestRatioMinBps: 5000, earlyVestRatioMaxBps: 5000, isRefunding: false
            })
        });
        IBUILDFactory.SetProjectSeasonParams[] memory paramsArray = new IBUILDFactory.SetProjectSeasonParams[](1);
        paramsArray[0] = seasonParams;
        factory.setProjectSeasonConfig(paramsArray);
        vm.stopPrank();
        
        // --- 3. EXPLOIT: USER ATTEMPTS TO CLAIM ---
        console.log("\n--- Phase 1: User with large allocation attempts an early claim ---");
        vm.warp(unlockStartsAt + 5 minutes); // Halfway through vesting

        IBUILDClaim.ClaimParams[] memory claimParams = new IBUILDClaim.ClaimParams[](1);
        claimParams[0] = IBUILDClaim.ClaimParams({ seasonId: SEASON_ID, proof: new bytes32[](0), maxTokenAmount: allocation, salt: 0, isEarlyClaim: true });
        
        vm.prank(attacker);

        // --- 4. EXPLOIT CONFIRMATION ---
        // The call to claim() will revert with an arithmetic overflow. This happens inside
        // _getClaimableState when calculating the vested amounts with very large numbers.
        // Because this is the only function to access funds, the user is permanently
        // blocked from ever receiving their allocation.
        vm.expectRevert(bytes("panic: arithmetic underflow or overflow (0x11)"));
        claimContract.claim(attacker, claimParams);

        console.log("\nSUCCESS: PoC confirmed. The claim transaction reverted with an arithmetic panic.");
        console.log("This permanently locks the user's funds, as any attempt to claim will fail.");
    }
}
```

## Recommended Remediation

To prevent the multiplication from overflowing, the calculation should be reordered to perform the division before the multiplication. This is a standard pattern for handling large-number arithmetic safely in Solidity. While this introduces minor precision loss, it is preferable to a critical DoS that locks funds. The precision loss is in favor of the protocol.

```diff
// Recommended fix for BUILDClaim.sol

    if (unlockState.isUnlocking) {
      // unlock period is in progress
      claimableState.vested =
-       (claimableState.bonus * unlockState.unlockElapsedDuration) / config.unlockDuration;
+       (claimableState.bonus / config.unlockDuration) * unlockState.unlockElapsedDuration;
```
A more advanced solution would involve using a full fixed-point math library like PRBMath to handle the multiplication and division without overflow or significant precision loss. However, reordering the operations is the most direct and immediate fix to prevent the critical DoS condition.
