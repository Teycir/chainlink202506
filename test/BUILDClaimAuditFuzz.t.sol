// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// --- FOUNDRY IMPORTS ---
import {Test} from "forge-std/Test.sol";

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

// --- MAIN TEST CONTRACT ---
contract BUILDClaimAuditFuzz is Test {
    // --- STATE VARIABLES ---
    BUILDFactory public factory;
    BUILDClaim public claim;
    MintableERC20 public token;
    StubRegistry public stubRegistry;

    address public factoryAdmin = makeAddr("factoryAdmin");
    address public projectAdmin = makeAddr("projectAdmin");

    uint32 public constant SEASON_ID = 1;

    // --- SETUP FUNCTION ---
    function setUp() public {
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
            admin: projectAdmin
        });
        factory.addProjects(addParams);
        vm.prank(projectAdmin);
        claim = BUILDClaim(address(factory.deployClaim(address(token))));
        token.mint(projectAdmin, type(uint128).max);
    }

    // --- MERKLE HELPER FUNCTIONS ---
    function _hash(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return
            a < b
                ? keccak256(abi.encodePacked(a, b))
                : keccak256(abi.encodePacked(b, a));
    }

    function _getMerkleRoot(
        bytes32[] memory _leaves
    ) internal pure returns (bytes32) {
        if (_leaves.length == 0) return bytes32(0);
        bytes32[] memory currentLayer = _leaves;
        while (currentLayer.length > 1) {
            uint256 nextLayerSize = (currentLayer.length + 1) / 2;
            bytes32[] memory nextLayer = new bytes32[](nextLayerSize);
            for (uint256 i = 0; i < nextLayerSize; i++) {
                if (2 * i + 1 < currentLayer.length) {
                    nextLayer[i] = _hash(
                        currentLayer[2 * i],
                        currentLayer[2 * i + 1]
                    );
                } else {
                    nextLayer[i] = currentLayer[2 * i];
                }
            }
            currentLayer = nextLayer;
        }
        return currentLayer[0];
    }

    function _getMerkleProof(
        bytes32[] memory _leaves,
        uint256 _leafIndex
    ) internal pure returns (bytes32[] memory) {
        bytes32[256] memory proofTmp;
        uint256 proofSize = 0;
        bytes32[] memory currentLayer = _leaves;
        uint256 currentIndex = _leafIndex;
        while (currentLayer.length > 1) {
            if (currentIndex % 2 == 1) {
                proofTmp[proofSize++] = currentLayer[currentIndex - 1];
            } else if (currentIndex + 1 < currentLayer.length) {
                proofTmp[proofSize++] = currentLayer[currentIndex + 1];
            }
            uint256 nextLayerSize = (currentLayer.length + 1) / 2;
            bytes32[] memory nextLayer = new bytes32[](nextLayerSize);
            for (uint256 i = 0; i < nextLayerSize; i++) {
                if (2 * i + 1 < currentLayer.length) {
                    nextLayer[i] = _hash(
                        currentLayer[2 * i],
                        currentLayer[2 * i + 1]
                    );
                } else {
                    nextLayer[i] = currentLayer[2 * i];
                }
            }
            currentLayer = nextLayer;
            currentIndex /= 2;
        }
        bytes32[] memory proof = new bytes32[](proofSize);
        for (uint256 i = 0; i < proofSize; i++) {
            proof[i] = proofTmp[i];
        }
        return proof;
    }

    // --- FUZZ TESTS FOR BUILDCLAIM ---

    function testFuzz_PreventClaimOverflow(address user, uint256 salt) public {
        vm.assume(user != address(0));
        // FIX: Use a large but manageable amount that the admin has.
        uint256 maxAmount = type(uint120).max;

        vm.startPrank(projectAdmin);
        token.approve(address(claim), maxAmount);
        claim.deposit(maxAmount);
        vm.stopPrank();

        vm.startPrank(factoryAdmin);
        factory.setSeasonUnlockStartTime(
            SEASON_ID,
            block.timestamp + 10 minutes
        );
        bytes32 leaf = keccak256(
            bytes.concat(keccak256(abi.encode(user, maxAmount, false, salt)))
        );
        IBUILDFactory.SetProjectSeasonParams[]
            memory params = new IBUILDFactory.SetProjectSeasonParams[](1);
        params[0] = IBUILDFactory.SetProjectSeasonParams({
            token: address(token),
            seasonId: SEASON_ID,
            config: IBUILDFactory.ProjectSeasonConfig({
                tokenAmount: maxAmount,
                baseTokenClaimBps: 10000,
                unlockDelay: 1 minutes,
                unlockDuration: 1,
                merkleRoot: leaf,
                earlyVestRatioMinBps: 0,
                earlyVestRatioMaxBps: 0,
                isRefunding: false
            })
        });
        factory.setProjectSeasonConfig(params);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 minutes + 2 minutes);
        IBUILDClaim.ClaimParams[]
            memory claimParams = new IBUILDClaim.ClaimParams[](1);
        claimParams[0] = IBUILDClaim.ClaimParams({
            seasonId: SEASON_ID,
            proof: new bytes32[](0),
            maxTokenAmount: maxAmount,
            salt: salt,
            isEarlyClaim: false
        });

        vm.prank(user);
        claim.claim(user, claimParams);
        uint256 balanceAfterFirstClaim = token.balanceOf(user);

        vm.prank(user);
        claim.claim(user, claimParams);
        uint256 balanceAfterSecondClaim = token.balanceOf(user);

        assertEq(
            balanceAfterFirstClaim,
            maxAmount,
            "User did not receive the full max amount"
        );
        assertEq(
            balanceAfterSecondClaim,
            balanceAfterFirstClaim,
            "FAIL: User claimed more than their max allocation!"
        );
    }

    // --- REFACTORED TEST FOR "STACK TOO DEEP" ---

    function testFuzz_PreventDosOnLoyaltyCalculation(
        address user1,
        address user2,
        uint256 salt1,
        uint256 salt2
    ) public {
        vm.assume(user1 != address(0) && user2 != address(0) && user1 != user2);
        (
            bytes32[] memory leaves,
            uint256 allocation1,
            uint256 allocation2
        ) = _setupDosTest(user1, user2, salt1, salt2);
        _executeDosPart1(user1, salt1, allocation1, leaves);
        _executeDosPart2(user2, salt2, allocation2, leaves);
    }

    function _setupDosTest(
        address user1,
        address user2,
        uint256 salt1,
        uint256 salt2
    )
        internal
        returns (
            bytes32[] memory leaves,
            uint256 allocation1,
            uint256 allocation2
        )
    {
        allocation1 = 100 ether;
        allocation2 = 400 ether;
        uint256 totalSeasonAmount = allocation1 + allocation2;

        leaves = new bytes32[](2);
        leaves[0] = keccak256(
            bytes.concat(keccak256(abi.encode(user1, allocation1, true, salt1)))
        );
        leaves[1] = keccak256(
            bytes.concat(
                keccak256(abi.encode(user2, allocation2, false, salt2))
            )
        );
        bytes32 root = _getMerkleRoot(leaves);

        vm.startPrank(projectAdmin);
        token.approve(address(claim), totalSeasonAmount);
        claim.deposit(totalSeasonAmount);
        vm.stopPrank();

        vm.startPrank(factoryAdmin);
        factory.setSeasonUnlockStartTime(
            SEASON_ID,
            block.timestamp + 10 minutes
        );
        IBUILDFactory.SetProjectSeasonParams[]
            memory params = new IBUILDFactory.SetProjectSeasonParams[](1);
        params[0] = IBUILDFactory.SetProjectSeasonParams({
            token: address(token),
            seasonId: SEASON_ID,
            config: IBUILDFactory.ProjectSeasonConfig({
                tokenAmount: totalSeasonAmount,
                baseTokenClaimBps: 1000,
                unlockDelay: 1 minutes,
                unlockDuration: 2 minutes,
                merkleRoot: root,
                earlyVestRatioMinBps: 5000,
                earlyVestRatioMaxBps: 5000,
                isRefunding: false
            })
        });
        factory.setProjectSeasonConfig(params);
        vm.stopPrank();
    }

    function _executeDosPart1(
        address user1,
        uint256 salt1,
        uint256 allocation1,
        bytes32[] memory leaves
    ) internal {
        vm.warp(block.timestamp + 10 minutes + 2 minutes); // halfway through vesting

        IBUILDClaim.ClaimParams[]
            memory claim1Params = new IBUILDClaim.ClaimParams[](1);
        bytes32[] memory proof1 = _getMerkleProof(leaves, 0);
        claim1Params[0] = IBUILDClaim.ClaimParams({
            seasonId: SEASON_ID,
            proof: proof1,
            maxTokenAmount: allocation1,
            salt: salt1,
            isEarlyClaim: true
        });

        vm.prank(user1);
        claim.claim(user1, claim1Params);
    }

    function _executeDosPart2(
        address user2,
        uint256 salt2,
        uint256 allocation2,
        bytes32[] memory leaves
    ) internal {
        vm.warp(block.timestamp + 2 minutes); // End of vesting

        IBUILDClaim.ClaimParams[]
            memory claim2Params = new IBUILDClaim.ClaimParams[](1);
        bytes32[] memory proof2 = _getMerkleProof(leaves, 1);
        claim2Params[0] = IBUILDClaim.ClaimParams({
            seasonId: SEASON_ID,
            proof: proof2,
            maxTokenAmount: allocation2,
            salt: salt2,
            isEarlyClaim: false
        });

        uint256 user2BalanceBefore = token.balanceOf(user2);
        vm.prank(user2);
        claim.claim(user2, claim2Params);
        uint256 user2BalanceAfter = token.balanceOf(user2);

        // FIX: Correctly calculate the expected loyalty bonus
        uint256 user1BonusAmount = (100 ether * 9000) / 10000; // 90 ether
        uint256 user1UnvestedBonus = user1BonusAmount / 2; // 45 ether
        uint256 user1EarlyVestable = (user1UnvestedBonus * 5000) / 10000; // 22.5 ether
        uint256 loyaltyContributed = user1UnvestedBonus - user1EarlyVestable; // 22.5 ether

        uint256 expectedClaim = allocation2 + loyaltyContributed;

        assertEq(
            user2BalanceAfter - user2BalanceBefore,
            expectedClaim,
            "User2 did not receive the correct loyalty bonus"
        );
    }
}
