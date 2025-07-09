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

// --- Self-Contained Mock ERC20 ---
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

contract EchidnaRefundAccounting is Test {
    // --- State Variables ---
    BUILDFactory internal factory;
    MintableERC20 internal token;
    IBUILDClaim internal claim;
    bool private initialized;
    bool private deposited;

    // --- Constants ---
    address internal constant FACTORY_ADMIN = address(1);
    address internal constant PROJECT_ADMIN = address(11);
    uint256 internal constant SEASON_TOKEN_AMOUNT = 1_000_000 ether;
    uint40 internal constant MAX_UNLOCK_DURATION = 4 * 365 days;
    uint40 internal constant MAX_UNLOCK_DELAY = 4 * 365 days;

    constructor() {} // Keep constructor empty

    function initialize() public {
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
        initialized = true;
    }

    // Echidna invariant: The factory's accounting must always remain solvent.
    function check_accounting_integrity_after_refund() public view {
        if (!initialized) return; // Don't check before setup is complete
        IBUILDFactory.TokenAmounts memory amounts = factory.getTokenAmounts(
            address(token)
        );
        assert(
            amounts.totalDeposited + amounts.totalRefunded >=
                amounts.totalWithdrawn + amounts.totalAllocatedToAllSeasons
        );
    }

    // Echidna test function to fuzz the refund logic.
    function fuzz_refund_logic(
        uint64 unlockDuration,
        uint32 baseTokenClaimBps,
        uint32 seasonId
    ) public {
        if (!initialized) {
            initialize();
        }

        if (!deposited) {
            vm.prank(PROJECT_ADMIN);
            token.approve(address(claim), SEASON_TOKEN_AMOUNT);
            vm.prank(PROJECT_ADMIN);
            claim.deposit(SEASON_TOKEN_AMOUNT);
            deposited = true;
        }

        seasonId = uint32(bound(seasonId, 1, 10));
        unlockDuration = uint64(
            bound(
                unlockDuration,
                2,
                factory.getUnlockConfigMaxValues().maxUnlockDuration
            )
        );
        baseTokenClaimBps = uint32(bound(baseTokenClaimBps, 1, 9999));

        vm.prank(FACTORY_ADMIN);
        try
            factory.setSeasonUnlockStartTime(seasonId, block.timestamp + 1 days)
        {} catch {}

        IBUILDFactory.SetProjectSeasonParams[]
            memory seasonParams = new IBUILDFactory.SetProjectSeasonParams[](1);
        seasonParams[0] = IBUILDFactory.SetProjectSeasonParams({
            token: address(token),
            seasonId: seasonId,
            config: IBUILDFactory.ProjectSeasonConfig({
                tokenAmount: SEASON_TOKEN_AMOUNT / 2,
                baseTokenClaimBps: uint16(baseTokenClaimBps),
                unlockDelay: 1 minutes,
                unlockDuration: uint40(unlockDuration),
                merkleRoot: bytes32(0),
                earlyVestRatioMinBps: 0,
                earlyVestRatioMaxBps: 0,
                isRefunding: false
            })
        });

        vm.prank(FACTORY_ADMIN);
        try factory.setProjectSeasonConfig(seasonParams) {} catch {}

        vm.prank(FACTORY_ADMIN);
        try factory.startRefund(address(token), seasonId) {} catch {}
    }
}
