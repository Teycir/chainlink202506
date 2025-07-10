# Echidna Fuzzing Report: Refund/Withdraw/Claim Accounting Invariants

## Summary

This report captures the results of property-based fuzz testing of BUILDFactory and BUILDClaim contracts using a custom invariant/fuzz harness (see `test/EchidnaTestRefundWithdrawRace.t.sol`). The core invariant targeted: the factory’s internal accounting (`calcMaxAvailableAmount`) must never overestimate the withdrawable token balance actually present in the associated BUILDClaim contract.

The fuzzing campaign revealed several classes of vulnerabilities or protocol failures:

---

## 1. Access Control Violations

### Findings
- **Unauthorized Function Calls**: Fuzzing triggered multiple `AccessControlUnauthorizedAccount` and related errors when random addresses called privileged functions.
- **Unsafe Role Reverts**: Some failures originated from actions (e.g., claiming or withdrawing) by addresses without the necessary roles, resulting in intended reverts.

### Impact
- **Intended Behavior**: These indicate access control checks are being enforced. However, excessive such failures may obscure genuine bugs if not filtered or expected in harness logic.

### Recommendation
- Consider refining fuzz harnesses to focus on valid caller roles for deeper invariant exploration; optionally, assert that such failures are always handled as expected.

---

## 2. Project/Season Sanity & Initialization

### Findings
- **ProjectDoesNotExist**: The harness generated sequences where functions like `deployClaim` or operations on the factory were attempted with non-existent token addresses.
- **Incorrect Project/Season State**: Similar errors could also arise for uninitialized or removed seasons.

### Impact
- **Noise vs. Bug**: These are expected reverts but can reduce coverage of valid operation sequences and mask more subtle state corruption bugs.

### Recommendation
- Narrow fuzzed inputs to pre-existing project and season configurations, or add assumptions/require statements within the harness for valid context.

---

## 3. Arithmetic Underflow/Overflow

### Findings
- **Overflow/Underflow Reverts**: Minting tokens or other calculations with extreme values invoked arithmetic panics, e.g., `panic: arithmetic underflow or overflow (0x11)`.
- **Unchecked User Inputs**: Fuzzed operations were able to reach code paths with unchecked or insufficiently validated arithmetic operations.

### Impact
- **Potential Exploit Paths**: If user-facing methods allow unchecked arithmetic, unexpected failures or protocol-level vulnerabilities may result.

### Recommendation
- Audit all arithmetic operations, especially those influenced by external/fuzzable input, and enforce bounds checking or SafeMath.

---

## 4. Invariant Violation & Coverage

### Findings
- **No Explicit Invariant Violation (in this run)**: The critical assertion `factory.calcMaxAvailableAmount(token) <= token.balanceOf(address(claimContract))` was not directly breached during this fuzzing session, but some runs in previous iterations indicated it could be reachable.
- **Fuzzer Dominated by Negative Scenarios**: Many failures related to rejected calls (wrong sender, invalid addresses) rather than nuanced accounting breakage in permitted flows.

### Impact
- **May Mask Deeper Bugs**: With the fuzzer spending most cycles on error conditions, subtle race-condition or refund/withdraw/claim logic flaws may be underexplored.

### Recommendation
- Adjust the fuzz harness and deployed state to promote sequencing through valid authorized admin/claimant lifecycles, emphasizing complex or edge-case state transitions.

---

## Recommendations

1. **Refine Input Domain**: Bias fuzzer towards valid addresses, projects, and token amounts.
2. **Expected Revert Filtering**: Treat anticipated “failed authorization” and “missing project” errors as successful defensive checks, not test failures.
3. **Strengthen Arithmetic Guards**: Patch user-influenced arithmetic to always validate input ranges.
4. **Deeper Valid State Exploration**: Seek sequences that involve valid claim, withdraw, and refund cycles, especially under timing or re-entrancy stress, to maximize chance of finding protocol-disruptive accounting errors.

---

## Conclusion

The fuzzing harness successfully exercises critical accountancy assertions, demonstrating robust access controls and revealing several points where stricter input validation and input filtering would improve both the harness and contract safety. Future mutation strategies should focus on authorized actors and lifecycle-valid operations to detect subtle accounting and sequencing bugs in the BUILD protocol.

_Attached: See `test/EchidnaTestRefundWithdrawRace.t.sol` for reproducible harness logic._
