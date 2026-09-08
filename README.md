# AutoStack

**Recurring DCA (dollar-cost averaging) vault on BOT Chain.**

Users deposit BOT into their idle vault balance and create a schedule that
periodically moves a fixed amount into their *stacked* balance. Because there
is no swap partner deployed alongside this demo, the stacked balance is
denominated in BOT 1:1 with the idle balance — think of it as a simulated
"acquired position" whose purchase price is recorded as the block number at
execution time. In a real deployment, `execute` would swap into a target
asset; the accounting surface stays the same.

## Permissionless execution — the keeper model

Anyone may call `execute(planId)` for a plan that is due. The caller receives
a small reward (default 25 bps of the cycle amount) funded from the platform
fee (default 50 bps). This creates an incentive for third parties — bots,
keepers, or other users watching the dApp's "All Executable Plans" panel —
to keep every schedule ticking without the plan owner needing to be online.

## Quickstart

```bash
npm install
npx hardhat compile
npx hardhat test

cp .env.example .env   # add your key
npm run deploy:testnet # or deploy:mainnet
```

Then paste the deployed address into `CONTRACT_ADDRESS` at the top of
`frontend/index.html` and open the file in a browser (or `vercel deploy`).

## Networks

| Network | chainId | RPC | Explorer |
|---------|---------|-----|----------|
| Testnet | 968 (0x3C8) | https://rpc.bohr.life | https://scan.bohr.life |
| Mainnet | 677 (0x2A5) | https://rpc.botchain.ai | https://scan.botchain.ai |

## Contract surface

- `deposit()` / `withdrawIdle` / `withdrawStacked`
- `createPlan(amountPerCycle, cycleSecs, totalCycles)` — cycleSecs ≥ 1 hour, totalCycles ≤ 1000
- `execute(planId)` — permissionless; pays caller reward
- `pausePlan` / `resumePlan` / `cancelPlan` — owner-only
- Views: `getPlan`, `getPurchases`, `getIdleBalance`, `getStackedBalance`,
  `nextExecutionTime`, `canExecute`, `getPlansByOwner`, `planCount`
- Admin: `pause`, `unpause`, `setPlatformFeeBps`, `setCallerRewardBps`, `withdrawFees`

Guarded by OpenZeppelin `Ownable`, `ReentrancyGuard`, `Pausable`.
