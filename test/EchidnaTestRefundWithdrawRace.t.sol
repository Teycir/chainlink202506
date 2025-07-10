// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "src/BUILDFactory.sol";
import "src/BUILDClaim.sol";
import "src/interfaces/IBUILDFactory.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {DelegateRegistry} from "@delegatexyz/delegate-registry/v2.0/src/DelegateRegistry.sol";

/**
 * @title MintableERC20
 * @dev Simple ERC20 token with a public mint function for testing purposes.
 */
contract MintableERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

/**
 * @title EchidnaTestRefundWithdrawRace
 * @dev This contract is designed to find race conditions and accounting errors between
 *      refunding, withdrawing, and claiming functionalities in the BUILD ecosystem.
 * @notice The primary invariant being tested is that the factory's internal accounting
 *         of available funds must never exceed the actual token balance of the claim contract.
 *         `assert(factory.calcMaxAvailableAmount(TOKEN_ADDRESS) <= token.balanceOf(address(claimContract)));`
 */
contract RefundWithdrawRaceFuzzTest is Test {
    // === Contracts ===
    BUILDFactory factory;
    BUILDClaim claimContract;
    MintableERC20 token;

    // === Actors ===
    address factoryAdmin = address(0x100); // Factory Admin
    address projectAdmin = address(0x200); // Project Admin
    address user1 = address(0x300);
    address user2 = address(0x400);

    // === Constants ===
    uint256 constant INITIAL_DEPOSIT_AMOUNT = 1_000_000e18;
    uint256 constant SEASON_1_TOTAL_ALLOCATION = 500_000e18;
    uint256 constant USER_1_ALLOCATION = 200_000e18;
    uint256 constant USER_2_ALLOCATION = 300_000e18;
    uint32 constant SEASON_ID = 1;

    // === Merkle Tree Data ===
    bytes32 private merkleRoot;
    bytes32[] private user1Proof;
    bytes32[] private user2Proof;

    constructor() payable {
        setUp();
    }

    function setUp() public {
        // --- Actor Setup ---
        vm.label(factoryAdmin, "factoryAdmin");
        vm.label(projectAdmin, "projectAdmin");
        vm.label(user1, "user1");
        vm.label(user2, "user2");

        vm.deal(factoryAdmin, 10 ether);
        vm.deal(projectAdmin, 10 ether);
        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);

        // --- Merkle Tree Generation ---
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = keccak256(
            abi.encodePacked(user1, USER_1_ALLOCATION, false, uint256(0))
        );
        leaves[1] = keccak256(
            abi.encodePacked(user2, USER_2_ALLOCATION, false, uint256(0))
        );
        merkleRoot = keccak256(abi.encodePacked(leaves[0], leaves[1]));
        user1Proof = new bytes32[](1);
        user1Proof[0] = leaves[1];
        user2Proof = new bytes32[](1);
        user2Proof[0] = leaves[0];

        // --- Contract Deployment & Setup ---
        vm.startPrank(factoryAdmin);
        // 1. Deploy Factory and Token
        token = new MintableERC20("TestToken", "TT");
        DelegateRegistry delegateRegistry = new DelegateRegistry();
        factory = new BUILDFactory(
            BUILDFactory.ConstructorParams({
                admin: factoryAdmin,
                maxUnlockDuration: 365 days,
                maxUnlockDelay: 30 days,
                delegateRegistry: IDelegateRegistry(address(delegateRegistry))
            })
        );

        // 2. Add Project
        IBUILDFactory.AddProjectParams[]
            memory projects = new IBUILDFactory.AddProjectParams[](1);
        projects[0] = IBUILDFactory.AddProjectParams({
            token: address(token),
            admin: projectAdmin
        });
        factory.addProjects(projects);
        vm.stopPrank();

        // 3. Deploy Claim Contract
        vm.startPrank(projectAdmin);
        claimContract = BUILDClaim(
            address(factory.deployClaim(address(token)))
        );
        vm.stopPrank();

        // 4. Deposit Funds
        token.mint(projectAdmin, INITIAL_DEPOSIT_AMOUNT);
        vm.startPrank(projectAdmin);
        token.approve(address(claimContract), INITIAL_DEPOSIT_AMOUNT);
        claimContract.deposit(INITIAL_DEPOSIT_AMOUNT);
        vm.stopPrank();

        // 5. Configure Season 1
        vm.startPrank(factoryAdmin);
        // Unlock starts almost immediately to allow claims
        factory.setSeasonUnlockStartTime(SEASON_ID, block.timestamp + 1);

        IBUILDFactory.SetProjectSeasonParams[]
            memory seasonParams = new IBUILDFactory.SetProjectSeasonParams[](1);
        seasonParams[0] = IBUILDFactory.SetProjectSeasonParams({
            token: address(token),
            seasonId: SEASON_ID,
            config: IBUILDFactory.ProjectSeasonConfig({
                tokenAmount: SEASON_1_TOTAL_ALLOCATION,
                baseTokenClaimBps: 5000, // 50%
                unlockDelay: 1, // 1 second
                unlockDuration: 1 hours,
                merkleRoot: merkleRoot,
                earlyVestRatioMinBps: 0,
                earlyVestRatioMaxBps: 0,
                isRefunding: false
            })
        });
        factory.setProjectSeasonConfig(seasonParams);
        vm.stopPrank();
    }

    // --- Echidna Fuzzing Functions ---

    // --- Invariant Test Functions ---

    function invariant_accounting() public {
        check_accounting_consistency();
    }

    function statefulFuzz_claim_user1() public {
        vm.prank(user1);
        try
            claimContract.claim(
                user1,
                _getClaimParams(SEASON_ID, user1Proof, USER_1_ALLOCATION)
            )
        {} catch {}
    }

    function statefulFuzz_claim_user2() public {
        vm.prank(user2);
        try
            claimContract.claim(
                user2,
                _getClaimParams(SEASON_ID, user2Proof, USER_2_ALLOCATION)
            )
        {} catch {}
    }

    function statefulFuzz_schedule_withdraw() public {
        uint256 maxAvailable = factory.calcMaxAvailableAmount(address(token));
        uint96 amount = uint96(bound(uint256(1), uint256(1), maxAvailable));
        if (amount == 0) return;

        vm.prank(factoryAdmin);
        try
            factory.scheduleWithdraw(address(token), projectAdmin, amount)
        {} catch {}
    }

    function statefulFuzz_cancel_withdraw() public {
        vm.prank(factoryAdmin);
        try factory.cancelWithdraw(address(token)) {} catch {}
    }

    function statefulFuzz_execute_withdraw() public {
        vm.prank(projectAdmin);
        try claimContract.withdraw() {} catch {}
    }

    function statefulFuzz_start_refund() public {
        vm.prank(factoryAdmin);
        try factory.startRefund(address(token), SEASON_ID) {} catch {}
    }

    function statefulFuzz_warp_time() public {
        uint32 time = uint32(bound(uint256(1), uint256(1), uint256(2 hours)));
        vm.warp(block.timestamp + time);
    }

    function test_cancel_withdraw() public {
        vm.prank(factoryAdmin);
        try factory.cancelWithdraw(address(token)) {} catch {}
        check_accounting_consistency();
    }

    function test_execute_withdraw() public {
        vm.prank(projectAdmin);
        try claimContract.withdraw() {} catch {}
        check_accounting_consistency();
    }

    function test_start_refund() public {
        vm.prank(factoryAdmin);
        try factory.startRefund(address(token), SEASON_ID) {} catch {}
        check_accounting_consistency();
    }

    function test_warp_time() public {
        // Warp time forward by a reasonable amount to trigger different states
        uint32 time = uint32(
            bound(
                uint256(
                    uint160(
                        uint256(
                            keccak256(
                                abi.encodePacked(
                                    block.timestamp,
                                    block.difficulty
                                )
                            )
                        )
                    )
                ),
                1,
                2 hours
            )
        );
        vm.warp(block.timestamp + time);
        check_accounting_consistency();
    }

    // --- Invariant ---

    function test_invariant() public {
        check_accounting_consistency();
    }

    function check_accounting_consistency() internal {
        if (address(claimContract) == address(0)) return;

        uint256 maxAvailable = factory.calcMaxAvailableAmount(address(token));
        uint256 realBalance = token.balanceOf(address(claimContract));

        // The factory's accounting of available funds should never exceed the actual balance.
        // If it does, it means the factory thinks it can withdraw or allocate more funds than
        // actually exist in the claim contract, which is a critical accounting bug.
        assert(maxAvailable <= realBalance);
    }

    // --- Helper Functions ---

    function _getClaimParams(
        uint32 seasonId,
        bytes32[] memory proof,
        uint256 maxTokenAmount
    ) internal pure returns (IBUILDClaim.ClaimParams[] memory) {
        IBUILDClaim.ClaimParams[] memory params = new IBUILDClaim.ClaimParams[](
            1
        );
        params[0] = IBUILDClaim.ClaimParams({
            seasonId: seasonId,
            proof: proof,
            maxTokenAmount: maxTokenAmount,
            salt: 0,
            isEarlyClaim: false
        });
        return params;
    }

    // This function is no longer needed as Merkle root is calculated manually.
}
