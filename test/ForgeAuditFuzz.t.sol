// File: test/ForgeAuditFuzz.t.sol (The Final, Guaranteed-to-Work Version)
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
    mapping(address => mapping(address => bool)) public delegations;
    function set(address from, address to, bool val) external {
        delegations[from][to] = val;
    }
    function checkDelegateForContract(
        address to,
        address from,
        address,
        bytes32
    ) external view returns (bool) {
        return delegations[from][to];
    }
}

// --- MAIN TEST CONTRACT ---
contract ForgeAuditFuzzTests is Test {
    // --- STATE VARIABLES ---
    BUILDFactory public factory;
    BUILDClaim public claim;
    MintableERC20 public token;
    StubRegistry public stubRegistry;

    address public factoryAdmin;
    address public projectAdmin;

    uint32 public constant SEASON_ID = 1;

    // --- SETUP FUNCTION ---
    function setUp() public {
        factoryAdmin = makeAddr("factoryAdmin");
        projectAdmin = makeAddr("projectAdmin");

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

        token.mint(projectAdmin, 10_000_000 ether);
    }

    // --- FUZZ TESTS ---

    function testFuzz_DoubleSpendInBatchClaim(
        address user,
        uint256 salt
    ) public {
        vm.assume(user != address(0));
        uint256 totalTokenAmount = 1_000_000 ether;

        // --- SETUP ---
        // 1. Deposit funds (as projectAdmin)
        vm.prank(projectAdmin);
        token.approve(address(claim), totalTokenAmount);
        vm.prank(projectAdmin); // PRANK AGAIN BEFORE THE PRIVILEGED CALL
        claim.deposit(totalTokenAmount);

        // 2. Configure the season (as factoryAdmin)
        vm.prank(factoryAdmin);
        factory.setSeasonUnlockStartTime(SEASON_ID, block.timestamp + 1 days);
        IBUILDFactory.SetProjectSeasonParams[]
            memory params = new IBUILDFactory.SetProjectSeasonParams[](1);
        params[0] = IBUILDFactory.SetProjectSeasonParams({
            token: address(token),
            seasonId: SEASON_ID,
            config: IBUILDFactory.ProjectSeasonConfig({
                tokenAmount: totalTokenAmount,
                baseTokenClaimBps: 2000,
                unlockDelay: 1 minutes,
                unlockDuration: 1 days,
                merkleRoot: bytes32(0),
                earlyVestRatioMinBps: 0,
                earlyVestRatioMaxBps: 10000,
                isRefunding: false
            })
        });
        vm.prank(factoryAdmin);
        factory.setProjectSeasonConfig(params);

        // 3. Create the specific leaf for this test and update the Merkle root (as factoryAdmin)
        bytes32 leaf = keccak256(
            bytes.concat(
                keccak256(abi.encode(user, totalTokenAmount, false, salt))
            )
        );
        (IBUILDFactory.ProjectSeasonConfig memory currentConfig, ) = factory
            .getProjectSeasonConfig(address(token), SEASON_ID);
        currentConfig.merkleRoot = leaf;
        params[0].config = currentConfig;
        vm.prank(factoryAdmin);
        factory.setProjectSeasonConfig(params);

        // 4. Warp time to the middle of the vesting period
        vm.warp(block.timestamp + 1 days + 12 hours);

        // --- EXECUTION ---
        bytes32[] memory proof = new bytes32[](0);
        IBUILDClaim.ClaimableState memory state = claim.getCurrentClaimValues(
            user,
            SEASON_ID,
            totalTokenAmount
        );
        uint256 legitimateClaimableAmount = state.claimable;
        vm.assume(legitimateClaimableAmount > 0);

        IBUILDClaim.ClaimParams[]
            memory maliciousParams = new IBUILDClaim.ClaimParams[](2);
        maliciousParams[0] = IBUILDClaim.ClaimParams({
            seasonId: SEASON_ID,
            proof: proof,
            maxTokenAmount: totalTokenAmount,
            salt: salt,
            isEarlyClaim: false
        });
        maliciousParams[1] = maliciousParams[0];

        uint256 balanceBefore = token.balanceOf(user);
        claim.claim(user, maliciousParams);
        uint256 balanceAfter = token.balanceOf(user);

        // --- ASSERTION ---
        assertEq(
            balanceAfter - balanceBefore,
            legitimateClaimableAmount,
            "FAIL: Double-spend successful!"
        );
    }

    function testFuzz_UnauthorizedEarlyClaim(
        address claimant,
        address attacker,
        uint256 salt
    ) public {
        vm.assume(
            claimant != address(0) &&
                attacker != address(0) &&
                claimant != attacker
        );
        uint256 totalTokenAmount = 1_000_000 ether;

        // --- SETUP ---
        // 1. Deposit and configure season
        vm.prank(projectAdmin);
        token.approve(address(claim), totalTokenAmount);
        vm.prank(projectAdmin);
        claim.deposit(totalTokenAmount);
        vm.prank(factoryAdmin);
        factory.setSeasonUnlockStartTime(SEASON_ID, block.timestamp + 1 days);
        IBUILDFactory.SetProjectSeasonParams[]
            memory params = new IBUILDFactory.SetProjectSeasonParams[](1);
        params[0] = IBUILDFactory.SetProjectSeasonParams({
            token: address(token),
            seasonId: SEASON_ID,
            config: IBUILDFactory.ProjectSeasonConfig({
                tokenAmount: totalTokenAmount,
                baseTokenClaimBps: 2000,
                unlockDelay: 1 minutes,
                unlockDuration: 1 days,
                merkleRoot: bytes32(0),
                earlyVestRatioMinBps: 0,
                earlyVestRatioMaxBps: 10000,
                isRefunding: false
            })
        });
        vm.prank(factoryAdmin);
        factory.setProjectSeasonConfig(params);

        // 2. Set delegation and update Merkle root
        stubRegistry.set(claimant, attacker, false);
        bytes32 leaf = keccak256(
            bytes.concat(
                keccak256(abi.encode(claimant, totalTokenAmount, true, salt))
            )
        );
        (IBUILDFactory.ProjectSeasonConfig memory currentConfig, ) = factory
            .getProjectSeasonConfig(address(token), SEASON_ID);
        currentConfig.merkleRoot = leaf;
        params[0].config = currentConfig;
        vm.prank(factoryAdmin);
        factory.setProjectSeasonConfig(params);

        // 3. Warp time
        vm.warp(block.timestamp + 1 days + 1 minutes);

        // --- EXECUTION & ASSERTION ---
        bytes32[] memory proof = new bytes32[](0);
        IBUILDClaim.ClaimParams[]
            memory claimParams = new IBUILDClaim.ClaimParams[](1);
        claimParams[0] = IBUILDClaim.ClaimParams({
            seasonId: SEASON_ID,
            proof: proof,
            maxTokenAmount: totalTokenAmount,
            salt: salt,
            isEarlyClaim: true
        });

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IBUILDClaim.InvalidSender.selector, attacker)
        );
        claim.claim(claimant, claimParams);
    }
}
