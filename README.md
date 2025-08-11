# Smart Contract Security Audit Findings

This document summarizes the findings from a comprehensive security audit of the BUILD protocol's smart contracts. The audit identified several critical and high-severity vulnerabilities that could lead to permanent loss of funds, denial of service, and theft.

## Key Vulnerabilities Discovered

The detailed findings for each vulnerability are available in the `Reports` folder.

### 1. Permanent Locking of Funds due to Flawed Accounting

A critical vulnerability in the `BUILDFactory` contract leads to the permanent locking of unclaimed funds. The contract's internal accounting fails to correctly track tokens that have already been claimed by users. This results in an artificially low calculation of available surplus funds, making it impossible for project admins to withdraw any remaining, unclaimed tokens from a season where at least one user has made a claim.

### 2. Arithmetic Overflow Leading to Permanent DoS and Locked Funds

The `BUILDClaim` contract is susceptible to an arithmetic overflow when calculating vested token amounts for users with large allocations. The multiplication of the user's bonus by the elapsed time can exceed the `uint256` limit, causing the `claim()` transaction to revert. Since `claim()` is the only method for users to retrieve their funds, this flaw results in a permanent and irrecoverable lock on their assets.

### 3. Unsafe Type Cast Enabling Theft of Funds

A critical vulnerability in `BUILDClaim` allows an attacker to steal funds by exploiting an unsafe type cast. The contract casts a `uint256` claimed amount down to a `uint248` for storage. An attacker can craft a claim that exceeds the `uint248` maximum, causing their internal balance to overflow and wrap around to zero. The contract, now believing the attacker has claimed nothing, allows them to repeatedly claim their full allocation, enabling the theft of all tokens in a season.

### 4. Incomplete State Cleanup Leading to Irrecoverable Fund Loss

The `removeProjects` function in `BUILDFactory` fails to clear all state associated with a removed project, leaving its financial ledger (`s_tokenAmounts`) intact. If the same token is re-registered by a new project, the stale accounting data is reused. This creates a situation where withdrawals are authorized based on the old project's deposits, but the execution fails because the new claim contract is empty. The funds from the original project remain permanently locked in their orphaned claim contract.

### 5. Division by Zero Causing Denial of Service

A division-by-zero vulnerability in the `BUILDClaim` contract can be triggered when calculating a loyalty bonus. If an early claimant takes the entire token amount for a season, the denominator in the loyalty calculation becomes zero. This causes all subsequent claim attempts by other users in that season to revert, permanently blocking them from accessing their rewards.

### 6. Pause Mechanism Bypass

The emergency pause mechanism in `BUILDClaim` can be bypassed. While the `deposit()` and `claim()` functions are correctly protected by the `whenClaimNotPaused` modifier, the `withdraw()` function is not. This allows a project admin to withdraw funds even when the contract is paused, undermining a critical safety feature designed to prevent malicious activity during an emergency.

## Professional Services

For professional smart contract security audits and vulnerability assessments, please contact: **teycir@pxdmail.net**
