// File: test/PoCOverflow.t.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// --- FOUNDRY IMPORTS ---
import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

// --- PROTOCOL IMPORTS ---
import {BUILDFactory} from "src/BUILDFactory.sol";
import {BUILDClaim} from "src/BUILDClaim.sol";
import {IBUILDFactory} from "src/interfaces/IBUILDFactory.sol";
import {IBUILDClaim} from "src/interfaces/IBUILDClaim.sol";

// --- DEPENDENCY IMPORTS ---
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IDelegateRegistry} from "@delegatexyz/delegate-registry/v2.0/src/IDelegateRegistry.sol";

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
            admin: projectAdmin
        });
        factory.addProjects(addParams);
        vm.prank(projectAdmin);
        claimContract = BUILDClaim(
            address(factory.deployClaim(address(token)))
        );
    }

    function test_PoC_ArithmeticOverflowCausesPermanentDosForUser() public {
        console.log(
            "--- PoC: Arithmetic Overflow in Claim Calculation Leads to Permanent DoS ---"
        );

        // --- 1. SETUP: A user is allocated a very large number of tokens ---
        // This value is within uint256 but will cause issues with internal uint248 calculations.
        uint256 allocation = type(uint248).max;
        token.mint(projectAdmin, allocation);
        vm.startPrank(projectAdmin);
        token.approve(address(claimContract), allocation);
        claimContract.deposit(allocation);
        vm.stopPrank();

        // --- 2. CONFIGURE SEASON ---
        bytes32 leaf = keccak256(
            bytes.concat(keccak256(abi.encode(attacker, allocation, true, 0)))
        );

        vm.startPrank(factoryAdmin);
        uint256 unlockStartsAt = block.timestamp + 1;
        factory.setSeasonUnlockStartTime(SEASON_ID, unlockStartsAt);

        IBUILDFactory.SetProjectSeasonParams memory seasonParams = IBUILDFactory
            .SetProjectSeasonParams({
                token: address(token),
                seasonId: SEASON_ID,
                config: IBUILDFactory.ProjectSeasonConfig({
                    tokenAmount: allocation,
                    baseTokenClaimBps: 1000, // 10% base
                    unlockDelay: 0,
                    unlockDuration: 10 minutes,
                    merkleRoot: leaf,
                    earlyVestRatioMinBps: 5000,
                    earlyVestRatioMaxBps: 5000,
                    isRefunding: false
                })
            });
        IBUILDFactory.SetProjectSeasonParams[]
            memory paramsArray = new IBUILDFactory.SetProjectSeasonParams[](1);
        paramsArray[0] = seasonParams;
        factory.setProjectSeasonConfig(paramsArray);
        vm.stopPrank();

        // --- 3. EXPLOIT: USER ATTEMPTS TO CLAIM ---
        console.log(
            "\n--- Phase 1: User with large allocation attempts an early claim ---"
        );
        vm.warp(unlockStartsAt + 5 minutes); // Halfway through vesting

        IBUILDClaim.ClaimParams[]
            memory claimParams = new IBUILDClaim.ClaimParams[](1);
        claimParams[0] = IBUILDClaim.ClaimParams({
            seasonId: SEASON_ID,
            proof: new bytes32[](0),
            maxTokenAmount: allocation,
            salt: 0,
            isEarlyClaim: true
        });

        vm.prank(attacker);

        // --- 4. EXPLOIT CONFIRMATION ---
        // The call to claim() will revert with an arithmetic overflow. This happens inside
        // _getClaimableState when calculating the vested amounts with very large numbers.
        // Because this is the only function to access funds, the user is permanently
        // blocked from ever receiving their allocation.
        vm.expectRevert(
            bytes("panic: arithmetic underflow or overflow (0x11)")
        );
        claimContract.claim(attacker, claimParams);

        console.log(
            "\nSUCCESS: PoC confirmed. The claim transaction reverted with an arithmetic panic."
        );
        console.log(
            "This permanently locks the user's funds, as any attempt to claim will fail."
        );
    }
}
