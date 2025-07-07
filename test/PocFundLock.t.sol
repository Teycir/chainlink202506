// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {BUILDFactory} from "src/BUILDFactory.sol";
import {IBUILDFactory} from "src/interfaces/IBUILDFactory.sol";
import {IBUILDClaim} from "src/interfaces/IBUILDClaim.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IDelegateRegistry} from "@delegatexyz/delegate-registry/v2.0/src/IDelegateRegistry.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract MintableERC20Token is ERC20 {
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

contract PocFundLock is Test {
    BUILDFactory factory;
    MintableERC20Token token;
    IBUILDClaim claimContract;
    StubRegistry registry;

    address factoryAdmin = makeAddr("factoryAdmin");
    address projectAdmin = makeAddr("projectAdmin");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");

    uint256 constant DEPOSIT_AMOUNT = 1000 ether;
    uint256 constant USER1_ALLOCATION = 900 ether;
    uint256 constant USER2_ALLOCATION = 100 ether;
    uint256 constant SEASON_ID = 1;

    function setUp() public {
        token = new MintableERC20Token();
        registry = new StubRegistry();

        vm.startPrank(factoryAdmin);
        factory = new BUILDFactory(
            BUILDFactory.ConstructorParams({
                admin: factoryAdmin,
                maxUnlockDuration: 365 days,
                maxUnlockDelay: 365 days,
                delegateRegistry: registry
            })
        );
        vm.stopPrank();

        vm.startPrank(factoryAdmin);
        IBUILDFactory.AddProjectParams[] memory projects = new IBUILDFactory.AddProjectParams[](1);
        projects[0] = IBUILDFactory.AddProjectParams({
            token: address(token),
            admin: projectAdmin
        });
        factory.addProjects(projects);
        vm.stopPrank();

        vm.startPrank(projectAdmin);
        claimContract = factory.deployClaim(address(token));
        vm.stopPrank();
    }

    function test_PoC_PermanentFundLock() public {
        // Deposit Funds
        token.mint(projectAdmin, DEPOSIT_AMOUNT);
        vm.startPrank(projectAdmin);
        token.approve(address(claimContract), DEPOSIT_AMOUNT);
        claimContract.deposit(DEPOSIT_AMOUNT);
        vm.stopPrank();

        console.log("Claim contract balance after deposit:", token.balanceOf(address(claimContract)));
        assertEq(token.balanceOf(address(claimContract)), DEPOSIT_AMOUNT);

        // Configure the Season
        bytes32 leaf1 = keccak256(bytes.concat(keccak256(abi.encode(user1, USER1_ALLOCATION, false, 0))));
        bytes32 leaf2 = keccak256(bytes.concat(keccak256(abi.encode(user2, USER2_ALLOCATION, false, 0))));
        
        bytes32 merkleRoot;
        if (leaf1 < leaf2) {
            merkleRoot = keccak256(abi.encodePacked(leaf1, leaf2));
        } else {
            merkleRoot = keccak256(abi.encodePacked(leaf2, leaf1));
        }

        vm.startPrank(factoryAdmin);
        factory.setSeasonUnlockStartTime(uint32(SEASON_ID), uint64(block.timestamp + 1));
        
        IBUILDFactory.SetProjectSeasonParams[] memory seasonParams = new IBUILDFactory.SetProjectSeasonParams[](1);
        seasonParams[0] = IBUILDFactory.SetProjectSeasonParams({
            seasonId: uint32(SEASON_ID),
            token: address(token),
            config: IBUILDFactory.ProjectSeasonConfig({
                tokenAmount: DEPOSIT_AMOUNT,
                merkleRoot: merkleRoot,
                unlockDelay: 0,
                unlockDuration: 1,
                earlyVestRatioMinBps: 0,
                earlyVestRatioMaxBps: 0,
                baseTokenClaimBps: 10000,
                isRefunding: false
            })
        });
        factory.setProjectSeasonConfig(seasonParams);
        vm.stopPrank();

        // Simulate a Partial Claim
        vm.warp(block.timestamp + 2 days);

        bytes32[] memory proof1 = new bytes32[](1);
        proof1[0] = leaf2;

        vm.startPrank(user1);
        IBUILDClaim.ClaimParams[] memory claimParams = new IBUILDClaim.ClaimParams[](1);
        claimParams[0] = IBUILDClaim.ClaimParams({
            seasonId: uint32(SEASON_ID),
            isEarlyClaim: false,
            proof: proof1,
            maxTokenAmount: USER1_ALLOCATION,
            salt: 0
        });
        claimContract.claim(user1, claimParams);
        vm.stopPrank();

        console.log("Claim contract balance after partial claim:", token.balanceOf(address(claimContract)));
        assertEq(token.balanceOf(address(claimContract)), USER2_ALLOCATION);

        // Trigger the Vulnerability
        console.log("Attempting to withdraw surplus funds...");

        vm.expectRevert(
            abi.encodeWithSelector(
                IBUILDFactory.InvalidWithdrawalAmount.selector,
                USER2_ALLOCATION, // amount
                0 // maxAvailable
            )
        );
        vm.startPrank(factoryAdmin);
        factory.scheduleWithdraw(address(token), projectAdmin, USER2_ALLOCATION);
        vm.stopPrank();

        console.log("Test passed: Withdrawal correctly reverted, proving funds are locked.");
    }
}