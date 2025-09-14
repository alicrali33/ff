# Ammplify contest details

- Join [Sherlock Discord](https://discord.gg/MABEWyASkp)
- Submit findings using the **Issues** page in your private contest repo (label issues as **Medium** or **High**)
- [Read for more details](https://docs.sherlock.xyz/audits/watsons)

# Q&A

### Q: On what chains are the smart contracts going to be deployed?
Monad
Berachain
Arbitrum
Base
Polygon
BnB
___

### Q: If you are integrating tokens, are you allowing only whitelisted tokens to work with the codebase or any complying with the standard? Are they assumed to have certain properties, e.g. be non-reentrant? Are there any types of [weird tokens](https://github.com/d-xo/weird-erc20) you want to integrate?
We handle any non-weird tokens that fit the ERC20 standard.
The protocol does not have a whitelist, but if a weird token is used with it and operations fail that is okay. It is on the user to not interact with pools that have weird tokens. (We will warn against weird tokens on the front end).
However, we are not expected to have issues with:
- Reentrant Calls
- Missing Return Values
- Flash Mintable Tokens
- Pausable Tokens (we would just revert)
- Approval Race Protections
- Revert on Approval To Zero Address
- Revert on Zero Value Approvals
- Revert on Zero Value Transfers
- Multiple Token Addresses
- transferFrom with src == msg.sender
- Non string metadata
- Revert on Transfer to the Zero Address
- Code Injection Via Token Name
- Unusual Permit Function
- Transfer of less than amount
- ERC-20 Representation of Native Currency 

The traits listed above are in scope and the contracts are expected to work correctly with them. Users will be able to create pools with tokens with other weird traits, but if they malfunction, it’s considered an acceptable risk.
___

### Q: Are there any limitations on values set by admins (or other roles) in the codebase, including restrictions on array lengths?
The owner is trusted and those with Taker and Veto permissions are trusted.
There are no restrictions on the admin values set.
The Takers are expected to always provide sufficient collateral to cover all the fees they owe.
___

### Q: Are there any limitations on values set by admins (or other roles) in protocols you integrate with, including restrictions on array lengths?
We should be safe to integrated with any reasonable Uniswap pool. If users attempt to use Ammplify on a malformed Uniswap pool that is considered user error.
___

### Q: Is the codebase expected to comply with any specific EIPs?
There are no EIPs adhered to by Ammplify, but its NFT manager does comply with 721.
___

### Q: Are there any off-chain mechanisms involved in the protocol (e.g., keeper bots, arbitrage bots, etc.)? We assume these mechanisms will not misbehave, delay, or go offline unless otherwise specified.
No.
___

### Q: What properties/invariants do you want to hold even if breaking them has a low/unknown impact?
No.
___

### Q: Please discuss any design choices you made.
The fee distribution for taker borrow costs is not split exactly, and it's possible to manipulate it by depositing liquidity in certain ways. This is why we apply a penalty to positions that deploy liquidity for too brief a time. However, it is expected that the manipulation is not too extreme. No single position can be charged 10%+ more than their true fee calculation rate or more than the average pool rate, whichever is larger.
___

### Q: Please provide links to previous audits (if any) and all the known issues or acceptable risks.
Gas costs that are over the usual block gas limit are not considered an issue because Monad's limit is 150M. Even if there are problems with exceeding the gas limit on other chains, it's considered a known and acceptable risk.

___

### Q: Please list any relevant protocol resources.
docs.ammplify.xyz
___

### Q: Additional audit information.
Issues that lead to getting incorrect return values (i.e. deviates from the withdrawal value of the asset by more than 0.01%) from the `queryAssetBalance` function (even if the appropriate input is used), which will lead to issues when executing other functions, may be considered valid with Medium severity at max.


# Audit scope

[Ammplify @ 1efcfd572d799c0976be1bce7bae127175ad1819](https://github.com/itos-finance/Ammplify/tree/1efcfd572d799c0976be1bce7bae127175ad1819)
- [Ammplify/src/Asset.sol](Ammplify/src/Asset.sol)
- [Ammplify/src/facets/Admin.sol](Ammplify/src/facets/Admin.sol)
- [Ammplify/src/facets/Maker.sol](Ammplify/src/facets/Maker.sol)
- [Ammplify/src/facets/Pool.sol](Ammplify/src/facets/Pool.sol)
- [Ammplify/src/facets/Taker.sol](Ammplify/src/facets/Taker.sol)
- [Ammplify/src/facets/View.sol](Ammplify/src/facets/View.sol)
- [Ammplify/src/Fee.sol](Ammplify/src/Fee.sol)
- [Ammplify/src/integrations/NFTManager.sol](Ammplify/src/integrations/NFTManager.sol)
- [Ammplify/src/integrations/UniV3Decomposer.sol](Ammplify/src/integrations/UniV3Decomposer.sol)
- [Ammplify/src/Pool.sol](Ammplify/src/Pool.sol)
- [Ammplify/src/Store.sol](Ammplify/src/Store.sol)
- [Ammplify/src/tree/BitMath.sol](Ammplify/src/tree/BitMath.sol)
- [Ammplify/src/tree/Key.sol](Ammplify/src/tree/Key.sol)
- [Ammplify/src/tree/Route.sol](Ammplify/src/tree/Route.sol)
- [Ammplify/src/tree/Tick.sol](Ammplify/src/tree/Tick.sol)
- [Ammplify/src/tree/ViewRoute.sol](Ammplify/src/tree/ViewRoute.sol)
- [Ammplify/src/vaults/Vault.sol](Ammplify/src/vaults/Vault.sol)
- [Ammplify/src/walkers/Data.sol](Ammplify/src/walkers/Data.sol)
- [Ammplify/src/walkers/Fee.sol](Ammplify/src/walkers/Fee.sol)
- [Ammplify/src/walkers/Lib.sol](Ammplify/src/walkers/Lib.sol)
- [Ammplify/src/walkers/Liq.sol](Ammplify/src/walkers/Liq.sol)
- [Ammplify/src/walkers/Node.sol](Ammplify/src/walkers/Node.sol)
- [Ammplify/src/walkers/Pool.sol](Ammplify/src/walkers/Pool.sol)
- [Ammplify/src/walkers/View.sol](Ammplify/src/walkers/View.sol)


