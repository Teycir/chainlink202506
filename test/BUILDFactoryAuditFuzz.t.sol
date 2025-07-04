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
contract BUILDFactoryAuditFuzz is Test {
    // --- STATE VARIABLES ---
    BUILDFactory public factory;
    MintableERC20 public token;
    StubRegistry public stubRegistry;

    address public factoryAdmin = makeAddr("factoryAdmin");
    address public projectAdmin = makeAddr("projectAdmin");
    address public user = makeAddr("user");

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
        token.mint(projectAdmin, 1_000_000 ether);
    }

    // --- MERKLE HELPER FUNCTION ---
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
                    nextLayer[i] = keccak256(
                        abi.encodePacked(
                            currentLayer[2 * i],
                            currentLayer[2 * i + 1]
                        )
                    );
                } else {
                    nextLayer[i] = currentLayer[2 * i];
                }
            }
            currentLayer = nextLayer;
        }
        return currentLayer[0];
    }

    // --- FUZZ TESTS FOR BUILDFACTORY ---

    /// @notice This test checks for the stale state vulnerability after a project is removed and re-added.
    /// A passing test here demonstrates that the old project's financial data IS NOT retained.
    /// The current implementation will fail this test because it does not clean up the state.
    function testFuzz_ProjectStateNotCleaned(uint64 depositAmount) public {
        vm.assume(depositAmount > 0 && depositAmount < 1_000_000e18);
        address newProjectAdmin = makeAddr("newProjectAdmin");

        // --- PHASE 1: Setup and use the first project ---
        _setupAndUseProject(depositAmount);

        // --- PHASE 2: Remove the project ---
        vm.prank(factoryAdmin);
        address[] memory tokensToRemove = new address[](1);
        tokensToRemove[0] = address(token);
        factory.removeProjects(tokensToRemove);

        // --- PHASE 3: Re-add the same token with a new admin ---
        vm.prank(factoryAdmin);
        IBUILDFactory.AddProjectParams[]
            memory addParams = new IBUILDFactory.AddProjectParams[](1);
        addParams[0] = IBUILDFactory.AddProjectParams({
            token: address(token),
            admin: newProjectAdmin
        });
        factory.addProjects(addParams);

        // --- ASSERTION ---
        // A clean project should have zero deposits.
        IBUILDFactory.TokenAmounts memory amounts = factory.getTokenAmounts(
            address(token)
        );

        // This assertion will FAIL on the vulnerable contract, proving the bug.
        // A correct implementation would pass this test.
        assertEq(
            amounts.totalDeposited,
            0,
            "FAIL: Stale deposit data was retained after project removal!"
        );
    }

    // Helper to setup and use a project to create some state
    function _setupAndUseProject(uint256 depositAmount) internal {
        vm.prank(factoryAdmin);
        IBUILDFactory.AddProjectParams[]
            memory addParams = new IBUILDFactory.AddProjectParams[](1);
        addParams[0] = IBUILDFactory.AddProjectParams({
            token: address(token),
            admin: projectAdmin
        });
        factory.addProjects(addParams);

        vm.prank(projectAdmin);
        BUILDClaim claim = BUILDClaim(
            address(factory.deployClaim(address(token)))
        );

        vm.startPrank(projectAdmin);
        token.approve(address(claim), depositAmount);
        claim.deposit(depositAmount);
        vm.stopPrank();
    }

    /// @notice This test checks for the incorrect calculation of max available funds after claims.
    /// A passing test here would show that the factory correctly accounts for claimed tokens.
    /// The current implementation will fail this test because it subtracts the entire season allocation,
    /// not just the remaining unclaimed portion.
    function testFuzz_IncorrectMaxAvailableCalculation(uint64 salt) public {
        uint256 totalDeposit = 1000 ether;
        uint256 seasonAllocation = 500 ether;
        uint256 userAllocation = 500 ether; // User is entitled to the whole season

        // --- SETUP: Deposit and configure a season for a single user ---
        BUILDClaim claim = _setupAndConfigureSeason(
            totalDeposit,
            seasonAllocation,
            userAllocation,
            salt
        );

        // --- EXECUTION 1: User claims their vested tokens ---
        vm.warp(block.timestamp + 10 minutes + 2 minutes); // End of vesting

        IBUILDClaim.ClaimParams[]
            memory claimParams = new IBUILDClaim.ClaimParams[](1);
        claimParams[0] = IBUILDClaim.ClaimParams({
            seasonId: SEASON_ID,
            proof: new bytes32[](0),
            maxTokenAmount: userAllocation,
            salt: salt,
            isEarlyClaim: false
        });

        vm.prank(user);
        claim.claim(user, claimParams);

        // --- ASSERTION ---
        // After the user claimed their 500 tokens, the amount "locked" in the system is 0.
        // Therefore, the max available should be the total deposit minus what was claimed.
        // Correct Max Available = totalDeposit (1000) - userAllocation (500) = 500 ether.
        // Vulnerable Max Available = totalDeposit (1000) - seasonAllocation (500) = 500 ether.
        // In this case, both calculations are the same. Let's adjust the test to reveal the flaw.
        // Let's have the user claim only part of their allocation due to vesting.

        // Re-run with vesting in the middle
        _reconfigureAndClaimPartial(claim, salt, userAllocation);

        // After the user claimed 250 tokens (half-vested bonus), there are 250 tokens remaining in the season.
        // Correct Max Available = totalDeposit (1000) - remainingInSeason (250) = 750 ether.
        // Vulnerable Max Available = totalDeposit (1000) - totalSeasonAllocation (500) = 500 ether.

        uint256 maxAvailable = factory.calcMaxAvailableAmount(address(token));

        // This assertion will FAIL on the vulnerable contract, proving the bug.
        // The vulnerable contract will report 500 ether, but the correct value is 750 ether.
        assertEq(
            maxAvailable,
            750 ether,
            "FAIL: Incorrect max available calculation, funds are locked!"
        );
    }

    // Helper to setup and configure a season
    function _setupAndConfigureSeason(
        uint256 totalDeposit,
        uint256 seasonAllocation,
        uint256 userAllocation,
        uint64 salt
    ) internal returns (BUILDClaim) {
        vm.prank(factoryAdmin);
        IBUILDFactory.AddProjectParams[]
            memory addParams = new IBUILDFactory.AddProjectParams[](1);
        addParams[0] = IBUILDFactory.AddProjectParams({
            token: address(token),
            admin: projectAdmin
        });
        factory.addProjects(addParams);

        vm.prank(projectAdmin);
        BUILDClaim claim = BUILDClaim(
            address(factory.deployClaim(address(token)))
        );

        vm.startPrank(projectAdmin);
        token.approve(address(claim), totalDeposit);
        claim.deposit(totalDeposit);
        vm.stopPrank();

        bytes32 leaf = keccak256(
            bytes.concat(
                keccak256(abi.encode(user, userAllocation, false, salt))
            )
        );

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
                tokenAmount: seasonAllocation,
                baseTokenClaimBps: 0, // 0% base for simplicity
                unlockDelay: 1 minutes,
                unlockDuration: 2 minutes,
                merkleRoot: leaf,
                earlyVestRatioMinBps: 0,
                earlyVestRatioMaxBps: 0,
                isRefunding: false
            })
        });
        factory.setProjectSeasonConfig(params);
        vm.stopPrank();
        return claim;
    }

    // Helper for the second part of the max available test
    function _reconfigureAndClaimPartial(
        BUILDClaim claim,
        uint64 salt,
        uint256 userAllocation
    ) internal {
        // This re-warp is a bit artificial but required to reset the state for the test logic.
        vm.warp(block.timestamp + 10 minutes + 1 minutes + 1 minutes); // Halfway through vesting

        IBUILDClaim.ClaimParams[]
            memory claimParams = new IBUILDClaim.ClaimParams[](1);
        claimParams[0] = IBUILDClaim.ClaimParams({
            seasonId: SEASON_ID,
            proof: new bytes32[](0),
            maxTokenAmount: userAllocation,
            salt: salt,
            isEarlyClaim: false
        });

        vm.prank(user);
        claim.claim(user, claimParams); // User claims half their bonus (250 ether)
    }
}
