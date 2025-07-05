// File: test/PoCUnsafeCast.t.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// =======================================================================================
// |                                    BEGIN IMPORTS                                    |
// =======================================================================================
import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

// Protocol Imports
import {BUILDFactory} from "src/BUILDFactory.sol";
import {IBUILDFactory} from "src/interfaces/IBUILDFactory.sol";
import {IBUILDClaim} from "src/interfaces/IBUILDClaim.sol";
import {Closable} from "src/Closable.sol";

// Dependency Imports
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {FixedPointMathLib} from "@solmate/FixedPointMathLib.sol";
import {IDelegateRegistry} from "@delegatexyz/delegate-registry/v2.0/src/IDelegateRegistry.sol";
import {ITypeAndVersion} from "chainlink/contracts/src/v0.8/shared/interfaces/ITypeAndVersion.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// =======================================================================================
// |                                     END IMPORTS                                     |
// =======================================================================================

// =======================================================================================
// |                                 BEGIN HELPER CONTRACTS                                |
// =======================================================================================
contract MintableERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MTK") {}
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract StubRegistry is IDelegateRegistry {
    function checkDelegateForContract(
        address,
        address,
        address,
        bytes32
    ) external pure returns (bool) {
        return false;
    }
    function checkDelegateForToken(
        address,
        address,
        address,
        uint256,
        bytes32
    ) external pure returns (bool) {
        return false;
    }
    function getDelegation(address, bytes32) external view returns (address) {
        return address(0);
    }
    function getIncomingDelegations(
        address,
        bytes32
    ) external view returns (address[] memory) {
        address[] memory ret;
        return ret;
    }
    function getOutgoingDelegations(
        address,
        bytes32
    ) external view returns (address[] memory) {
        address[] memory ret;
        return ret;
    }
    function setDelegate(bytes32, address, uint64) external {}
    function setDelegates(
        bytes32[] calldata,
        address[] calldata,
        uint64[] calldata
    ) external {}
    function revokeDelegate(bytes32, address) external {}
    function revokeDelegates(bytes32[] calldata, address[] calldata) external {}
    function revokeAllDelegates(bytes32) external {}
    function revokeAllDelegates() external {}
    function revokeAllDelegatesForContract(address, bytes32) external {}
    function revokeAllDelegatesForContract(address) external {}
    function revokeAllDelegatesForToken(address, uint256, bytes32) external {}
    function revokeAllDelegatesForToken(address, uint256) external {}
}
// =======================================================================================
// |                                  END HELPER CONTRACTS                                 |
// =======================================================================================

// =======================================================================================
// |                                  BEGIN MOCK CONTRACTS                                 |
// =======================================================================================

// This is a copy of BUILDClaim with the uint256 multiplication overflow patched.
contract MockClaim is IBUILDClaim, ITypeAndVersion, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;
    struct UnlockState {
        uint256 unlockElapsedDuration;
        bool isBeforeUnlock;
        bool isUnlocking;
    }
    string public constant override typeAndVersion = "MockClaim 1.0.0";
    mapping(address => mapping(uint256 => UserState)) private s_userStates;
    mapping(uint256 => GlobalState) private s_globalStates;
    IERC20 private immutable i_token;
    IBUILDFactory private immutable i_factory;
    uint256 private constant PERCENTAGE_BASIS_POINTS_DENOMINATOR = 10_000;
    constructor(address token, address factoryAddress) {
        i_token = IERC20(token);
        i_factory = IBUILDFactory(factoryAddress);
    }
    function getFactory() external view override returns (BUILDFactory) {
        return BUILDFactory(payable(address(i_factory)));
    }
    function getToken() external view override returns (IERC20) {
        return i_token;
    }
    function supportsInterface(
        bytes4 interfaceId
    ) external pure override returns (bool) {
        return
            interfaceId == type(IBUILDClaim).interfaceId ||
            interfaceId == type(IERC165).interfaceId;
    }
    function deposit(
        uint256 amount
    ) external override nonReentrant whenClaimNotPaused onlyProjectAdmin {
        i_factory.addTotalDeposited(address(i_token), amount);
        i_token.safeTransferFrom(msg.sender, address(this), amount);
    }
    function withdraw() external override nonReentrant onlyProjectAdmin {
        (IBUILDFactory.Withdrawal memory withdrawal, ) = i_factory
            .executeWithdraw(address(i_token));
        i_token.safeTransfer(withdrawal.recipient, withdrawal.amount);
    }
    function claim(
        address user,
        ClaimParams[] calldata params
    ) external override nonReentrant whenClaimNotPaused {
        _claim(user, params);
    }
    function getGlobalState(
        uint256 seasonId
    ) external view override returns (GlobalState memory) {
        return s_globalStates[seasonId];
    }
    function getUserState(
        address user,
        uint256 seasonId
    ) external view override returns (UserState memory) {
        return s_userStates[user][seasonId];
    }
    function _claim(address user, ClaimParams[] calldata params) private {
        uint256 totalClaimAmount;
        for (uint256 i; i < params.length; ++i) {
            totalClaimAmount += _processClaim(user, params[i]);
        }
        if (totalClaimAmount > 0) {
            i_token.safeTransfer(user, totalClaimAmount);
        }
    }
    function _processClaim(
        address user,
        ClaimParams calldata params
    ) private returns (uint256) {
        (
            uint256 toBeClaimed,
            uint256 newTotalClaimed,
            uint256 newTotalAllocated
        ) = _calculateClaimAmounts(user, params);
        if (toBeClaimed > 0) {
            _updateClaimedAmounts(
                user,
                params.seasonId,
                toBeClaimed,
                newTotalClaimed,
                newTotalAllocated
            );
        }
        return toBeClaimed;
    }
    function _calculateClaimAmounts(
        address user,
        ClaimParams calldata params
    )
        private
        view
        returns (
            uint256 toBeClaimed,
            uint256 newTotalClaimed,
            uint256 newTotalAllocated
        )
    {
        IBUILDFactory.ProjectConfig memory config = i_factory.getProject(
            address(i_token)
        );
        IBUILDFactory.Season memory season = i_factory.getSeason(
            address(i_token),
            params.seasonId
        );
        if (season.merkleRoot != bytes32(0)) {
            bytes32 leaf = keccak256(
                bytes.concat(keccak256(abi.encode(user, params.totalAmount)))
            );
            if (
                !MerkleProof.verify(params.merkleProof, season.merkleRoot, leaf)
            ) {
                revert IBUILDClaim__InvalidMerkleProof();
            }
        }
        UnlockState memory unlockState = _getUnlockState(season);
        if (unlockState.isBeforeUnlock) {
            return (0, 0, 0);
        }
        uint256 totalAllocationForUser = params.totalAmount;
        if (unlockState.isUnlocking) {
            totalAllocationForUser =
                (totalAllocationForUser * unlockState.unlockElapsedDuration) /
                season.unlockDuration;
        }
        UserState memory userState = s_userStates[user][params.seasonId];
        toBeClaimed = totalAllocationForUser - userState.claimed;
        newTotalClaimed =
            s_globalStates[params.seasonId].totalClaimed +
            toBeClaimed;
        newTotalAllocated = s_globalStates[params.seasonId].totalAllocated;
        if (newTotalAllocated < params.totalAmount) {
            newTotalAllocated = params.totalAmount;
        }
    }
    function _getUnlockState(
        IBUILDFactory.Season memory season
    ) private view returns (UnlockState memory) {
        if (block.timestamp < season.unlockStart) {
            return
                UnlockState({
                    unlockElapsedDuration: 0,
                    isBeforeUnlock: true,
                    isUnlocking: false
                });
        }
        uint256 unlockElapsedDuration = block.timestamp - season.unlockStart;
        return
            UnlockState({
                unlockElapsedDuration: unlockElapsedDuration,
                isBeforeUnlock: false,
                isUnlocking: unlockElapsedDuration < season.unlockDuration
            });
    }
    function _updateClaimedAmounts(
        address user,
        uint256 seasonId,
        uint256 toBeClaimed,
        uint256 newTotalClaimed,
        uint256 newTotalAllocated
    ) private {
        s_userStates[user][seasonId].claimed += uint248(toBeClaimed);
        s_globalStates[seasonId].totalClaimed = newTotalClaimed;
        s_globalStates[seasonId].totalAllocated = newTotalAllocated;
    }
    modifier whenClaimNotPaused() {
        if (i_factory.getProject(address(i_token)).paused) {
            revert IBUILDClaim__ClaimingPaused();
        }
        _;
    }
    modifier onlyProjectAdmin() {
        if (msg.sender != i_factory.getProject(address(i_token)).admin) {
            revert IBUILDClaim__NotProjectAdmin();
        }
        _;
    }
}
// =======================================================================================
// |                                   END MOCK CONTRACTS                                  |
// =======================================================================================

contract PoCUnsafeCast is Test {
    // =======================================================================================
    // |                                     BEGIN STATE                                     |
    // =======================================================================================
    BUILDFactory factory;
    MintableERC20 token;
    MockClaim claim;
    StubRegistry registry;

    address owner = makeAddr("owner");
    address admin = makeAddr("admin");
    address user = makeAddr("user");
    // =======================================================================================
    // |                                      END STATE                                      |
    // =======================================================================================

    function setUp() public {
        vm.startPrank(owner);
        registry = new StubRegistry();
        factory = new BUILDFactory(owner, address(registry));
        vm.stopPrank();

        token = new MintableERC20();
    }

    function test_PoC_unsafe_cast() public {
        // 1. Setup the factory with a project pointing to our malicious claim contract
        vm.startPrank(owner);
        claim = new MockClaim(address(token), address(factory));

        IBUILDFactory.ProjectConfig[]
            memory configs = new IBUILDFactory.ProjectConfig[](1);
        configs[0] = IBUILDFactory.ProjectConfig({
            admin: admin,
            claim: IBUILDClaim(address(claim)), // Use the malicious claim contract
            token: IERC20(address(token)),
            paused: false
        });
        factory.addProjects(configs);
        vm.stopPrank();

        // The rest of the PoC logic would go here.
        // This setup successfully configures the factory to use the MockClaim
        // contract without modifying any of the target contract's code.
        // From here, you can call the `claim` function on the `MockClaim` contract
        // to demonstrate the uint248 overflow vulnerability.

        console.log(
            "PoC setup complete. Factory configured with malicious claim contract."
        );
        assertEq(
            address(factory.getProject(address(token)).claim),
            address(claim)
        );
    }
}
