// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IDelegateRegistry} from "@delegatexyz/delegate-registry/v2.0/src/IDelegateRegistry.sol";
import {DelegateRegistry} from "@delegatexyz/delegate-registry/v2.0/src/DelegateRegistry.sol";
import {BUILDFactory} from "src/BUILDFactory.sol";
import {BUILDClaim} from "src/BUILDClaim.sol";
import {IBUILDFactory} from "src/interfaces/IBUILDFactory.sol";
import {IBUILDClaim} from "src/interfaces/IBUILDClaim.sol";

contract MintableERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MTK") {}
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

/**
 * @title EchidnaAdvancedFuzz
 * @dev Implements the recommendations from the Echidna report to find complex accounting bugs.
 */
contract EchidnaAdvancedFuzz is Test {
    // --- Contracts ---
    BUILDFactory internal factory;
    BUILDClaim internal claimContract;
    MintableERC20 internal token;

    // --- Actors ---
    address internal constant ADMIN = address(0x1);
    address internal constant PROJECT_ADMIN = address(0x2);
    address internal constant USER_1 = address(0x3);
    address internal constant USER_2 = address(0x4);

    // --- Constants ---
    uint32 internal constant SEASON_ID = 1;
    uint256 internal constant USER_1_ALLOCATION = 1000e18;
    uint256 internal constant USER_2_ALLOCATION = 2000e18;

    // --- Merkle Tree Data ---
    bytes32 internal merkleRoot;
    bytes32[] internal user1Proof;
    bytes32[] internal user2Proof;

    constructor() {
        // --- Actor Setup ---
        vm.label(ADMIN, "ADMIN");
        vm.label(PROJECT_ADMIN, "PROJECT_ADMIN");
        vm.label(USER_1, "USER_1");
        vm.label(USER_2, "USER_2");

        // --- Merkle Tree Generation ---
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = keccak256(
            abi.encodePacked(USER_1, USER_1_ALLOCATION, false, uint256(0))
        );
        leaves[1] = keccak256(
            abi.encodePacked(USER_2, USER_2_ALLOCATION, true, uint256(0))
        );
        merkleRoot = keccak256(abi.encodePacked(leaves[0], leaves[1]));

        user1Proof = new bytes32[](1);
        user1Proof[0] = leaves[1];

        user2Proof = new bytes32[](1);
        user2Proof[0] = leaves[0];

        // --- Contract Deployment & Setup ---
        token = new MintableERC20();
        vm.prank(ADMIN);
        factory = new BUILDFactory(
            BUILDFactory.ConstructorParams({
                admin: ADMIN,
                maxUnlockDuration: 365 days,
                maxUnlockDelay: 30 days,
                delegateRegistry: IDelegateRegistry(new DelegateRegistry())
            })
        );

        vm.prank(ADMIN);
        IBUILDFactory.AddProjectParams[]
            memory input = new IBUILDFactory.AddProjectParams[](1);
        input[0] = IBUILDFactory.AddProjectParams({
            token: address(token),
            admin: PROJECT_ADMIN
        });
        factory.addProjects(input);

        vm.prank(PROJECT_ADMIN);
        claimContract = BUILDClaim(
            address(factory.deployClaim(address(token)))
        );

        uint256 totalDeposit = USER_1_ALLOCATION + USER_2_ALLOCATION;
        token.mint(PROJECT_ADMIN, totalDeposit);
        vm.startPrank(PROJECT_ADMIN);
        token.approve(address(claimContract), totalDeposit);
        claimContract.deposit(totalDeposit);
        vm.stopPrank();

        vm.startPrank(ADMIN);
        uint256 unlockStartsAt = block.timestamp + 1 days;
        factory.setSeasonUnlockStartTime(SEASON_ID, unlockStartsAt);

        IBUILDFactory.SetProjectSeasonParams[]
            memory params = new IBUILDFactory.SetProjectSeasonParams[](1);
        params[0] = IBUILDFactory.SetProjectSeasonParams({
            token: address(token),
            seasonId: SEASON_ID,
            config: IBUILDFactory.ProjectSeasonConfig({
                tokenAmount: totalDeposit,
                baseTokenClaimBps: 5000,
                unlockDelay: 0,
                unlockDuration: 30 days,
                merkleRoot: merkleRoot,
                earlyVestRatioMinBps: 1000,
                earlyVestRatioMaxBps: 5000,
                isRefunding: false
            })
        });
        factory.setProjectSeasonConfig(params);
        vm.stopPrank();
    }

    function statefulFuzz_earlyClaim_user2() public {
        vm.prank(USER_2);
        try
            claimContract.claim(
                USER_2,
                _getClaimParams(user2Proof, USER_2_ALLOCATION, true)
            )
        {} catch {}
    }

    function statefulFuzz_claim_user1() public {
        vm.prank(USER_1);
        try
            claimContract.claim(
                USER_1,
                _getClaimParams(user1Proof, USER_1_ALLOCATION, false)
            )
        {} catch {}
    }

    function statefulFuzz_schedule_withdraw() public {
        uint256 maxAvailable = factory.calcMaxAvailableAmount(address(token));
        uint256 randomAmount = bound(
            uint256(
                keccak256(
                    abi.encodePacked(msg.sender, block.timestamp, "withdraw")
                )
            ),
            1,
            maxAvailable
        );
        uint96 amount = uint96(randomAmount);
        if (amount == 0) return;

        vm.prank(ADMIN);
        try
            factory.scheduleWithdraw(address(token), PROJECT_ADMIN, amount)
        {} catch {}
    }

    function statefulFuzz_execute_withdraw() public {
        vm.prank(PROJECT_ADMIN);
        try claimContract.withdraw() {} catch {}
    }

    function statefulFuzz_start_refund() public {
        vm.prank(ADMIN);
        try factory.startRefund(address(token), SEASON_ID) {} catch {}
    }

    function statefulFuzz_warp_time() public {
        uint256 randomTimestamp = bound(
            uint256(keccak256(abi.encodePacked(msg.sender, block.timestamp))),
            block.timestamp,
            block.timestamp + 60 days
        );
        vm.warp(randomTimestamp);
    }

    function invariant_accounting_is_sound() public {
        uint256 maxAvailable = factory.calcMaxAvailableAmount(address(token));
        uint256 realBalance = token.balanceOf(address(claimContract));
        assert(maxAvailable <= realBalance);
    }

    function _getClaimParams(
        bytes32[] memory proof,
        uint256 maxTokenAmount,
        bool isEarly
    ) internal pure returns (IBUILDClaim.ClaimParams[] memory) {
        IBUILDClaim.ClaimParams[] memory params = new IBUILDClaim.ClaimParams[](
            1
        );
        params[0] = IBUILDClaim.ClaimParams({
            seasonId: SEASON_ID,
            proof: proof,
            maxTokenAmount: maxTokenAmount,
            salt: 0,
            isEarlyClaim: isEarly
        });
        return params;
    }
}
