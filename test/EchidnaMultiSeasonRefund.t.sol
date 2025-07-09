// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {BUILDFactory} from "../src/BUILDFactory.sol";
import {IBUILDFactory} from "../src/interfaces/IBUILDFactory.sol";
import {IBUILDClaim} from "../src/interfaces/IBUILDClaim.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IDelegateRegistry} from "@delegatexyz/delegate-registry/v2.0/src/IDelegateRegistry.sol";
import {DelegateRegistry} from "@delegatexyz/delegate-registry/v2.0/src/DelegateRegistry.sol";
import {ERC20DecimalsMock} from "@openzeppelin/contracts/mocks/token/ERC20DecimalsMock.sol";

contract MintableERC20 is ERC20DecimalsMock {
    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals
    ) ERC20(name, symbol) ERC20DecimalsMock(decimals) {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract EchidnaMultiSeasonRefund is Test {
    // --- State Variables ---
    BUILDFactory internal factory;
    MintableERC20 internal token;
    IBUILDClaim internal claim;
    bool private initialized;

    IBUILDFactory.ProjectSeasonConfig internal season1Config;
    IBUILDFactory.ProjectSeasonConfig internal season2Config;

    // --- Constants ---
    address internal constant FACTORY_ADMIN = address(1);
    address internal constant PROJECT_ADMIN = address(11);
    uint256 internal constant SEASON_TOKEN_AMOUNT = 1_000_000 ether;
    uint40 internal constant MAX_UNLOCK_DURATION = 4 * 365 days;
    uint40 internal constant MAX_UNLOCK_DELAY = 4 * 365 days;
    uint32 internal constant SEASON_1_ID = 1;
    uint32 internal constant SEASON_2_ID = 2;

    constructor() {
        // Setup initial season configs
        season1Config = IBUILDFactory.ProjectSeasonConfig({
            tokenAmount: SEASON_TOKEN_AMOUNT / 4,
            baseTokenClaimBps: 5000, // 50%
            unlockDelay: 1 minutes,
            unlockDuration: 30 days,
            merkleRoot: bytes32(0),
            earlyVestRatioMinBps: 0,
            earlyVestRatioMaxBps: 0,
            isRefunding: false
        });

        season2Config = IBUILDFactory.ProjectSeasonConfig({
            tokenAmount: SEASON_TOKEN_AMOUNT / 4,
            baseTokenClaimBps: 5000, // 50%
            unlockDelay: 1 minutes,
            unlockDuration: 30 days,
            merkleRoot: bytes32(0),
            earlyVestRatioMinBps: 0,
            earlyVestRatioMaxBps: 0,
            isRefunding: false
        });
    }

    function initialize() internal {
        if (initialized) return;
        // --- Simplified Setup ---
        vm.prank(FACTORY_ADMIN);
        DelegateRegistry delegateRegistry = new DelegateRegistry();

        vm.prank(FACTORY_ADMIN);
        BUILDFactory.ConstructorParams memory params = BUILDFactory
            .ConstructorParams({
                admin: FACTORY_ADMIN,
                maxUnlockDuration: MAX_UNLOCK_DURATION,
                maxUnlockDelay: MAX_UNLOCK_DELAY,
                delegateRegistry: IDelegateRegistry(delegateRegistry)
            });
        factory = new BUILDFactory(params);

        vm.prank(PROJECT_ADMIN);
        token = new MintableERC20("Test Token", "TST", 18);

        vm.prank(FACTORY_ADMIN);
        IBUILDFactory.AddProjectParams[]
            memory addParams = new IBUILDFactory.AddProjectParams[](1);
        addParams[0] = IBUILDFactory.AddProjectParams({
            token: address(token),
            admin: PROJECT_ADMIN
        });
        factory.addProjects(addParams);

        vm.prank(PROJECT_ADMIN);
        claim = factory.deployClaim(address(token));

        token.mint(PROJECT_ADMIN, SEASON_TOKEN_AMOUNT);

        // Deposit funds
        vm.prank(PROJECT_ADMIN);
        token.approve(address(claim), SEASON_TOKEN_AMOUNT);
        vm.prank(PROJECT_ADMIN);
        claim.deposit(SEASON_TOKEN_AMOUNT);

        // Configure seasons
        vm.prank(FACTORY_ADMIN);
        factory.setSeasonUnlockStartTime(SEASON_1_ID, block.timestamp + 1 days);
        vm.prank(FACTORY_ADMIN);
        factory.setSeasonUnlockStartTime(SEASON_2_ID, block.timestamp + 1 days);

        IBUILDFactory.SetProjectSeasonParams[]
            memory seasonParams = new IBUILDFactory.SetProjectSeasonParams[](2);
        seasonParams[0] = IBUILDFactory.SetProjectSeasonParams({
            token: address(token),
            seasonId: SEASON_1_ID,
            config: season1Config
        });
        seasonParams[1] = IBUILDFactory.SetProjectSeasonParams({
            token: address(token),
            seasonId: SEASON_2_ID,
            config: season2Config
        });

        vm.prank(FACTORY_ADMIN);
        factory.setProjectSeasonConfig(seasonParams);

        initialized = true;
    }

    // Echidna invariant: The factory's accounting must always remain solvent.
    function check_accounting_integrity() public view {
        if (!initialized) return;
        IBUILDFactory.TokenAmounts memory amounts = factory.getTokenAmounts(
            address(token)
        );
        assert(
            amounts.totalDeposited + amounts.totalRefunded >=
                amounts.totalWithdrawn + amounts.totalAllocatedToAllSeasons
        );
    }

    // Novel invariant: Refunding one season should not affect another season's config.
    function check_season_isolation(uint32 refundedSeasonId) public view {
        if (!initialized) return;

        uint32 otherSeasonId;
        IBUILDFactory.ProjectSeasonConfig memory otherSeasonInitialConfig;

        if (refundedSeasonId == SEASON_1_ID) {
            otherSeasonId = SEASON_2_ID;
            otherSeasonInitialConfig = season2Config;
        } else if (refundedSeasonId == SEASON_2_ID) {
            otherSeasonId = SEASON_1_ID;
            otherSeasonInitialConfig = season1Config;
        } else {
            return; // Not a season we are tracking
        }

        (
            IBUILDFactory.ProjectSeasonConfig memory otherSeasonCurrentConfig,
            uint256 seasonUnlockStartTime
        ) = factory.getProjectSeasonConfig(address(token), otherSeasonId);

        // The other season should not be marked as refunding
        assert(!otherSeasonCurrentConfig.isRefunding);
        // And its parameters should be unchanged.
        assert(
            otherSeasonCurrentConfig.tokenAmount ==
                otherSeasonInitialConfig.tokenAmount
        );
        assert(
            otherSeasonCurrentConfig.baseTokenClaimBps ==
                otherSeasonInitialConfig.baseTokenClaimBps
        );
        assert(
            otherSeasonCurrentConfig.unlockDelay ==
                otherSeasonInitialConfig.unlockDelay
        );
        assert(
            otherSeasonCurrentConfig.unlockDuration ==
                otherSeasonInitialConfig.unlockDuration
        );
    }

    // Echidna test function to fuzz the refund logic with multiple seasons.
    function fuzz_multi_season_refund(bool refund_season_1) public {
        initialize();

        uint32 seasonToRefund = refund_season_1 ? SEASON_1_ID : SEASON_2_ID;

        vm.prank(FACTORY_ADMIN);
        try factory.startRefund(address(token), seasonToRefund) {} catch {}

        // After the refund attempt, check the isolation property
        check_season_isolation(seasonToRefund);
    }
}
