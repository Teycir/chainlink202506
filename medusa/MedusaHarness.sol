// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/* ─── core protocol ───────────────────────────────────────────────────────── */
import {BUILDFactory}   from "../src/BUILDFactory.sol";
import {BUILDClaim}     from "../src/BUILDClaim.sol";
import {IBUILDFactory}  from "../src/interfaces/IBUILDFactory.sol";
import {IBUILDClaim}    from "../src/interfaces/IBUILDClaim.sol";

/* ─── helpers ─────────────────────────────────────────────────────────────── */
import {ERC20Token}        from "../src/mocks/ERC20Token.sol";
import {IDelegateRegistry} from
  "@delegatexyz/delegate-registry/v2.0/src/IDelegateRegistry.sol";
import {FixedPointMathLib} from "@solmate/FixedPointMathLib.sol";

/* ╔══════════════════════════════════════════════════════════════════════╗ *
 * ║                     Minimal delegate-registry stub                   ║ *
 * ╚══════════════════════════════════════════════════════════════════════╝ */
contract StubRegistry is IDelegateRegistry {
  mapping(address => mapping(address => bool)) internal ok;
  function set(address from, address to, bool value) external { ok[from][to] = value; }
  function checkDelegateForContract(
      address to, address from, address, bytes32
  ) external view override returns (bool) { return ok[from][to]; }
}

/* ╔══════════════════════════════════════════════════════════════════════╗ *
 * ║                            Medusa Harness                            ║ *
 * ╚══════════════════════════════════════════════════════════════════════╝ */
contract MedusaHarness {
  using FixedPointMathLib for uint256;

  /* ───────── public state ───────── */
  BUILDFactory public factory;
  BUILDClaim   public claim;
  ERC20Token   public token;
  StubRegistry public registry;

  /* time chaos shadow var */
  uint256 public pseudoTime;

  address public constant ADMIN   = address(this);
  uint256 public constant SEASON0 = 0;

  /* ───────── constructor ───────── */
  constructor() {
    registry = new StubRegistry();

    factory = new BUILDFactory(
      BUILDFactory.ConstructorParams({
        admin:             ADMIN,
        maxUnlockDuration: 30 days,
        maxUnlockDelay:     7 days,
        delegateRegistry:  registry
      })
    );

    token = new ERC20Token("Mock", "MOCK", 18);
    token.mint(address(this), 1e30);

    IBUILDFactory.AddProjectParams[] memory add = new IBUILDFactory.AddProjectParams[](1);
    add[0] = IBUILDFactory.AddProjectParams({token: address(token), admin: ADMIN});
    factory.addProjects(add);

    claim = BUILDClaim(address(factory.deployClaim(address(token))));
    token.approve(address(claim), type(uint256).max);

    factory.setSeasonUnlockStartTime(SEASON0, block.timestamp + 1 minutes);

    IBUILDFactory.ProjectSeasonConfig memory cfg;
    cfg.tokenAmount          = 1e24;
    cfg.baseTokenClaimBps    = 2_000;
    cfg.unlockDelay          = 1 minutes;
    cfg.unlockDuration       = 1 days;
    cfg.earlyVestRatioMinBps = 0;
    cfg.earlyVestRatioMaxBps = 10_000;
    cfg.merkleRoot           = bytes32(0);

    IBUILDFactory.SetProjectSeasonParams[] memory set =
      new IBUILDFactory.SetProjectSeasonParams[](1);
    set[0] = IBUILDFactory.SetProjectSeasonParams({
      token: address(token),
      seasonId: SEASON0,
      config: cfg
    });
    factory.setProjectSeasonConfig(set);

    claim.deposit(cfg.tokenAmount);
  }

  /* ══════════════  MUTATORS EXPOSED TO MEDUSA  ═══════════════════════════ */

  /* ----- season admin --------------------------------------------------- */
  function fuzzSetSeasonUnlock(uint256 ts) external {
    uint256 season = SEASON0 + 1;
    if (ts <= block.timestamp) ts = block.timestamp + 1 hours;
    try factory.setSeasonUnlockStartTime(season, ts) {} catch {}
  }

  function fuzzSetSeasonConfig(
      uint256 season,
      uint40 unlockDelay,
      uint40 unlockDuration,
      uint16 baseBps,
      uint16 minEV,
      uint16 maxEV,
      uint256 amount
  ) external {
    IBUILDFactory.ProjectSeasonConfig memory cfg;
    cfg.tokenAmount          = (amount % 1e24) + 1;
    cfg.baseTokenClaimBps    = baseBps % 10_001;
    cfg.unlockDelay          = unlockDelay % (7 days);
    cfg.unlockDuration       = (unlockDuration % (30 days)) + 1;
    cfg.earlyVestRatioMinBps = minEV % 10_001;
    cfg.earlyVestRatioMaxBps = cfg.earlyVestRatioMinBps
                             + (maxEV % (10_001 - cfg.earlyVestRatioMinBps));
    cfg.merkleRoot           = bytes32(0);

    IBUILDFactory.SetProjectSeasonParams[] memory set =
      new IBUILDFactory.SetProjectSeasonParams[](1);
    set[0] = IBUILDFactory.SetProjectSeasonParams({
      token: address(token),
      seasonId: season,
      config: cfg
    });
    try factory.setProjectSeasonConfig(set) {} catch {}
  }

  /* ----- deposits / refunds / pause ------------------------------------ */
  function fuzzDeposit(uint256 amount) external {
    amount = (amount % 1e24) + 1;
    token.mint(address(this), amount);
    try claim.deposit(amount) {} catch {}
  }
  function fuzzStartRefund(uint256 season) external {
    try factory.startRefund(address(token), season) {} catch {}
  }
  function fuzzPause()  external { try factory.pauseClaimContract(address(token)) {} catch {} }
  function fuzzUnpause()external { try factory.unpauseClaimContract(address(token)) {} catch {} }

  /* ----- withdrawals ---------------------------------------------------- */
  function fuzzScheduleWithdraw(uint256 amt) external {
    amt = amt % 1e25;
    try factory.scheduleWithdraw(address(token), ADMIN, amt) {} catch {}
  }
  function fuzzExecuteWithdraw() external { try claim.withdraw() {} catch {} }

  /* ----- delegation toggle --------------------------------------------- */
  function fuzzToggleDelegation(address from, address to, bool val) external {
    if (from != address(0) && to != address(0)) registry.set(from, to, val);
  }

  /* ----- time chaos ----------------------------------------------------- */
  function fuzzWarp(uint32 delta) external {
    pseudoTime = block.timestamp + (uint256(delta) % (31 days));
  }

  /* ----- user claims ---------------------------------------------------- */
  function fuzzClaimNormal(address u,uint256 s,uint256 amt,uint256 salt) external {
    _claim(u, s, amt, false, salt);
  }
  function fuzzClaimEarly(address u,uint256 s,uint256 amt,uint256 salt) external {
    _claim(u, s, amt, true,  salt);
  }

  function _claim(address u,uint256 season,uint256 amt,bool early,uint256 salt) internal {
    if (u == address(0)) u = address(0xBEEF);
    amt = (amt % 1e24) + 1;

    (IBUILDFactory.ProjectSeasonConfig memory cfg,) =
        factory.getProjectSeasonConfig(address(token), season);
    if (cfg.tokenAmount == 0) return;

    cfg.merkleRoot = keccak256(bytes.concat(
      keccak256(abi.encode(u, amt, early, salt))
    ));

    IBUILDFactory.SetProjectSeasonParams[] memory set =
      new IBUILDFactory.SetProjectSeasonParams[](1);
    set[0] = IBUILDFactory.SetProjectSeasonParams({
      token: address(token),
      seasonId: season,
      config: cfg
    });
    try factory.setProjectSeasonConfig(set) {} catch {}

    IBUILDClaim.ClaimParams[] memory cp = new IBUILDClaim.ClaimParams[](1);
    cp[0] = IBUILDClaim.ClaimParams({
      seasonId: season,
      proof: new bytes32[](0),
      maxTokenAmount: amt,
      salt: salt,
      isEarlyClaim: early
    });
    try claim.claim(u, cp) {} catch {}
  }

  /* ══════════════  GLOBAL INVARIANTS  ═══════════════════════════════════ */

  function checkInvariants() external view {
    IBUILDFactory.TokenAmounts memory t = factory.getTokenAmounts(address(token));

    /* bookkeeping */
    assert(t.totalWithdrawn <= t.totalDeposited + t.totalRefunded);
    assert(factory.calcMaxAvailableAmount(address(token))
            <= token.balanceOf(address(claim)));

    /* loyalty denominator never zero */
    for (uint256 s; s <= SEASON0 + 1;) {
      (IBUILDFactory.ProjectSeasonConfig memory cfg,) =
          factory.getProjectSeasonConfig(address(token), s);
      if (cfg.tokenAmount != 0) {
        BUILDClaim.GlobalState memory gs = claim.getGlobalState(s);
        assert(cfg.tokenAmount - gs.totalLoyaltyIneligible != 0);
      }
      unchecked { ++s; }
    }
  }
}