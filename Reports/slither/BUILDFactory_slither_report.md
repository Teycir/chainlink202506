# Slither Analysis Report for BUILDFactory Contract

---

## 1. Dangerous Strict Equality Checks in `BUILDClaim._claim`

- Check at [src/BUILDClaim.sol:370-374](src/BUILDClaim.sol:370):
  ```solidity
  (claimableState.claimable == 0 && !param.isEarlyClaim) ||
  (claimableState.claimable == 0 && claimableState.earlyVestableBonus == 0 && param.isEarlyClaim)
  ```
- Check at [src/BUILDClaim.sol:379](src/BUILDClaim.sol:379):
  ```solidity
  claimableState.claimed == 0
  ```
- [Slither Reference: Dangerous Strict Equalities](https://github.com/crytic/slither/wiki/Detector-Documentation#dangerous-strict-equalities)

---

## 2. Potential Reentrancy Vulnerabilities in `BUILDClaim._claim`

- External calls inside loops (e.g., `i_factory.reduceRefundableAmount`) with subsequent state updates affecting `globalState` and user states.
- [Slither Reference: Reentrancy](https://github.com/crytic/slither/wiki/Detector-Documentation#reentrancy-vulnerabilities-1)

---

## 3. Uninitialized Local Variables in `BUILDClaim`

- In `_getClaimableState`: local variable `claimableState` is not initialized at [src/BUILDClaim.sol:204](src/BUILDClaim.sol:204).
- In `_claim`: local variable `totalClaimableAmount` is not initialized at [src/BUILDClaim.sol:339](src/BUILDClaim.sol:339).
- [Slither Reference: Uninitialized Local Variables](https://github.com/crytic/slither/wiki/Detector-Documentation#uninitialized-local-variables)

---

## 4. External Calls Inside Loops in `BUILDFactory.addProjects`

- `BUILDFactory.addProjects(IBUILDFactory.AddProjectParams[])` ([src/BUILDFactory.sol:94-113](src/BUILDFactory.sol:94)) uses external calls inside a loop to check parameters and token decimals.
- [Slither Reference: Calls Inside a Loop](https://github.com/crytic/slither/wiki/Detector-Documentation/#calls-inside-a-loop)

---

> **Recommendation:**  
> It is recommended to review and address these issues to ensure secure and reliable contract execution.

---

_End of Report_
