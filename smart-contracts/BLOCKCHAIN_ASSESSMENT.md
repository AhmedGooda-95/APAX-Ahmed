# APAX Blockchain Assessment

- **Contract:** [`contracts/APXGold.sol`](./contracts/APXGold.sol)
- **Tests:** [`test/APXGold.test.ts`](./test/APXGold.test.ts)

This submission covers the blockchain section of the APAX technical assessment. It focuses on a single metal token, APX Gold, and the contract design, tests, and integration points relevant to that token.

## Contract Design

APXGold uses the ERC-20 interface with additional transfer checks. A transfer is allowed only when both the sender and recipient are approved and neither address is frozen. This keeps the token compatible with standard EVM wallets while enforcing the eligibility rules required by the product.

The contract uses separate roles for administration, minting, compliance updates, and emergency pausing. These roles should be assigned to separate operational accounts where practical. In a production deployment, privileged roles should be controlled by a multisig and managed under documented approval procedures.

Minting represents a verified deposit of gold with the custodian. The contract can restrict who is allowed to mint, but it cannot independently confirm that a physical bar has been deposited. That confirmation must come from the custody and audit process outside the contract.

Transfers are checked in the OpenZeppelin v5 `_update` hook. Minting and burning need separate handling because one side of those operations is the zero address. The emergency pause should prevent token movement while leaving authorized recovery and administration procedures clear.

This is an ERC-20 implementation with custom compliance checks; it is not a full ERC-3643 implementation. A full ERC-3643 deployment offers a broader identity and claims framework, but it also introduces more contracts and integration work. For this assessment, the simpler approach demonstrates the required transfer controls without claiming the additional ERC-3643 components are present.

## Tests

The contract tests should cover the following cases:

- An authorized minter can mint to an approved, unfrozen address.
- Minting to an unapproved address fails.
- An account without the minter role cannot mint.
- Transfers between approved, unfrozen addresses succeed.
- A transfer to or from an unapproved or frozen address fails.
- An account without the compliance role cannot change approval or freeze status.
- Transfers fail while the contract is paused.
- Burning follows the authorized redemption flow and cannot burn more tokens than are available or approved for redemption.

## Frontend and Backend Integration

The frontend can read `balanceOf` and the holder's approval status from the contract using wagmi or ethers. These reads let the interface show balances and explain why a transfer is unavailable. The contract remains responsible for enforcing the rule; frontend checks are only for user experience.

A backend indexer can listen for `Transfer` and other relevant contract events, then store the confirmed events in MongoDB for dashboard history and search. MongoDB is a query-friendly projection of on-chain activity, not the authority for token ownership. The indexer should track processed block numbers, wait for an appropriate number of confirmations, and support replaying events if its stored data needs to be rebuilt.

## Redemption and Burning

A redemption request should not cause an immediate burn. First, the user submits a request and the service verifies the user's eligibility, token amount, delivery details, and the custodian's ability to fulfill it. The tokens can then be locked in an escrow contract or otherwise reserved so they cannot be spent during fulfillment.

After the custodian confirms fulfillment under the agreed process, an authorized account completes the redemption and the approved amount is burned. If fulfillment is cancelled, the locked tokens should be releasable back to the user. The contract cannot prove that physical gold was delivered; that step depends on the custodian's evidence and operational controls. Redemption records and approvals should therefore be auditable.

## Security Considerations

The main risks are misuse or compromise of privileged roles, incorrect KYC or freeze updates, bugs in transfer and redemption logic, and a mismatch between the on-chain supply and custodied reserves. Mitigations include role separation, multisig control of privileged accounts, pausing procedures, focused tests, an independent contract audit before production use, and a documented reconciliation process with the custodian.
