# AmpAgent Context for Chainlink Rewards Audit

## Project Overview
This is a Chainlink Rewards audit codebase containing smart contracts for a community engagement and rewards program. The system allows projects in the Chainlink Build program to deploy on-chain claim mechanisms for token rewards to ecosystem participants.

## Key Information
- **Language**: Solidity 0.8.26
- **Framework**: Foundry
- **Deployment**: Ethereum only
- **Token Standard**: ERC-20 (canonical implementations only)
- **Audit Period**: June 16, 2025 - July 16, 2025
- **Prize Pool**: $200,000 USDC

## Architecture Overview
The system consists of two main contracts:
1. **BUILDFactory**: Manages project deployments and configurations
2. **BUILDClaim**: Handles individual project reward claiming and vesting

## In-Scope Files (626 SLoC)
- [`src/BUILDClaim.sol`](./src/BUILDClaim.sol) - 262 SLoC: Facilitates vest claim operations
- [`src/BUILDFactory.sol`](./src/BUILDFactory.sol) - 364 SLoC: Maintains deployments and configurations

## Out-of-Scope Files
- `lib/**` - Dependencies
- `scripts/**` - Deployment scripts
- `src/Closable.sol` - Base contract
- `src/ManagedAccessControl.sol` - Access control base
- `src/interfaces/**` - Interface definitions
- `src/mocks/**` - Mock contracts
- `test/**` - Test files

## Key Dependencies
- OpenZeppelin: AccessControl, SafeERC20, Pausable, ReentrancyGuard, MerkleProof
- Solmate: FixedPointMathLib
- Chainlink: ITypeAndVersion
- Delegate Registry: IDelegateRegistry

## Common Commands

### Build & Test
```bash
# Install dependencies
pnpm i

# Run all tests
pnpm test:solidity

# Run specific test patterns
forge test -vvv --match-contract Scenarios
forge test --match-test submissionValidity

# Gas snapshots
pnpm gas
pnpm test:gas

# Coverage reports
pnpm coverage
# OR manual: FOUNDRY_PROFILE=coverage forge coverage --report lcov
```

### Linting & Formatting
```bash
# Format code
pnpm format

# Solhint linting
pnpm test:solhint

# Generate ABIs
pnpm generateABIs
```

### Development
```bash
# Clean build artifacts
pnpm clean

# Build contracts
forge build

# Run specific profiles
FOUNDRY_PROFILE=gas forge snapshot -vvv
FOUNDRY_PROFILE=coverage forge coverage --report lcov
```

## Project Structure
```
src/
├── BUILDClaim.sol           # Main claiming contract
├── BUILDFactory.sol         # Factory and management
├── Closable.sol             # Base closable functionality
├── ManagedAccessControl.sol # Access control base
├── interfaces/              # Contract interfaces
└── mocks/                   # Mock contracts

test/
├── BaseTest.t.sol           # Comprehensive test setup
├── PoC.t.sol                # Proof of Concept template
├── BUILDClaim/              # BUILDClaim tests
├── BUILDFactory/            # BUILDFactory tests
├── gas/                     # Gas optimization tests
├── invariants/              # Invariant tests
└── utils/                   # Test utilities

scripts/
├── BaseScript.s.sol         # Base deployment script
├── EnvManager.s.sol         # Environment management
├── generateABIFiles.js      # ABI generation
├── build-claim/             # Claim deployment scripts
├── build-factory/           # Factory deployment scripts
└── scenarios/               # Scenario scripts
```

## Key Features & Mechanics
1. **Multi-Season Vesting**: Tokens vest over multiple seasons with configurable unlock periods
2. **Early Vesting**: Users can forfeit portions of unvested tokens for early access
3. **Merkle Proofs**: Claims are validated through Merkle tree proofs
4. **Delegation**: Users can delegate claim operations to other addresses
5. **Admin Controls**: Emergency pause, project removal, withdrawal scheduling

## Trust Assumptions
- BUILDFactory configured with zero `adminRoleTransferDelay` (deliberate)
- All assigned roles are trustworthy
- Projects and tokens are vetted before inclusion
- Merkle proofs gated by off-chain validations

## Security Focus Areas
- **Access Control**: Role-based permissions and restrictions
- **Claiming Logic**: Allocation, vesting, and early vest calculations
- **Mathematical Operations**: Overflow/underflow prevention
- **Reentrancy**: Protection against reentrancy attacks
- **Pausability**: Emergency pause mechanisms

## Test Setup for PoCs
Use the comprehensive `BaseTest` contract modifiers:
```solidity
function test_submissionValidity() 
  external
  whenASeasonConfigIsSetForTheSeason
  whenProjectAddedAndClaimDeployed
  whenTokensAreDepositedForTheProject
  whenASeasonConfigIsSetForTheProject
  whenTheUnlockIsInHalfWayForSeason1
{
  // PoC code here
}
```

## Key Invariants
- Users can only claim unlocked tokens
- No more than maximum amount can be claimed
- Claimable amount never exceeds token balance
- Mathematical operations don't overflow/underflow
- Contracts cannot be permanently bricked

## Configuration
- **Solc Version**: 0.8.26
- **EVM Version**: paris
- **Optimizer**: Enabled (200 runs)
- **Max Block Gas**: 1,000,000,000,000 (merkle_verification profile)
- **Line Length**: 100 characters
- **Tab Width**: 2 spaces

## Notes
- All findings remain private to Chainlink team
- PoC required for High/Medium submissions
- Use specific test command: `forge test --match-test submissionValidity`
- Focus on smart contract logic, not off-chain mechanisms
