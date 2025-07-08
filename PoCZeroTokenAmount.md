// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {BUILDFactory} from "src/BUILDFactory.sol";
import {IBUILDFactory} from "src/interfaces/IBUILDFactory.sol";
import {IBUILDClaim} from "src/interfaces/IBUILDClaim.sol";
import {IDelegateRegistry} from "@delegatexyz/delegate-registry/v2.0/src/IDelegateRegistry.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

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

contract PoCZeroTokenAmount is Test {
    BUILDFactory public factory;
    MintableERC20 public token;
    StubRegistry public stubRegistry;
    IBUILDClaim public claimContract;

    address public factoryAdmin = makeAddr("factoryAdmin");
    address public projectAdmin = makeAddr("projectAdmin");
    uint32 public constant SEASON_ID = 1;

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
        claimContract = factory.deployClaim(address(token));

        token.mint(projectAdmin, 1e18);
        vm.prank(projectAdmin);
        token.approve(address(claimContract), 1e18);
        vm.prank(projectAdmin);
        claimContract.deposit(1e18);
    }

    function testFuzz_CannotSetZeroTokenAmount(bytes32 merkleRoot) public {
        vm.prank(factoryAdmin);
        factory.setSeasonUnlockStartTime(SEASON_ID, block.timestamp + 1 days);

        // @notice Test to ensure that a project season cannot be configured with a token amount of zero.
        // First, set a valid config
        IBUILDFactory.SetProjectSeasonParams[]
            memory validParams = new IBUILDFactory.SetProjectSeasonParams[](1);
        validParams[0] = IBUILDFactory.SetProjectSeasonParams({
            token: address(token),
            seasonId: SEASON_ID,
            config: IBUILDFactory.ProjectSeasonConfig({
                tokenAmount: 1,
                baseTokenClaimBps: 10000,
                unlockDelay: 1 minutes,
                unlockDuration: 1,
                merkleRoot: merkleRoot,
                earlyVestRatioMinBps: 0,
                earlyVestRatioMaxBps: 0,
                isRefunding: false
            })
        });
        vm.prank(factoryAdmin);
        factory.setProjectSeasonConfig(validParams);

        // Now, attempt to set a zero token amount
        IBUILDFactory.SetProjectSeasonParams[]
            memory invalidParams = new IBUILDFactory.SetProjectSeasonParams[](
                1
            );
        invalidParams[0] = IBUILDFactory.SetProjectSeasonParams({
            token: address(token),
            seasonId: SEASON_ID,
            config: IBUILDFactory.ProjectSeasonConfig({
                tokenAmount: 0,
                baseTokenClaimBps: 10000,
                unlockDelay: 1 minutes,
                unlockDuration: 1,
                merkleRoot: merkleRoot,
                earlyVestRatioMinBps: 0,
                earlyVestRatioMaxBps: 0,
                isRefunding: false
            })
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                IBUILDFactory.InvalidTokenAmount.selector,
                SEASON_ID
            )
        );
        vm.prank(factoryAdmin);
        factory.setProjectSeasonConfig(invalidParams);
    }

    function testFuzz_CannotSetPastUnlockStartTime(
        uint64 pastTimestamp
    ) public {
        vm.assume(pastTimestamp < block.timestamp);
        vm.prank(factoryAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBUILDFactory.InvalidUnlockStartsAt.selector,
                SEASON_ID,
                pastTimestamp
            )
        );
        factory.setSeasonUnlockStartTime(SEASON_ID, pastTimestamp);
    }
}