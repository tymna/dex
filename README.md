## Architecture

Singleton DEX — one contract, all pools as internal structs. LP tokens via ERC1155 (poolId = tokenId).

## Invariants

### Per-pool

- `x * y >= k` — reserve product holds or grows after every operation
- `totalSupply == 0` if `reserve0 == 0 && reserve1 == 0`
- Output amount < reserve of output token
- No token extraction without token input
- MINIMUM_LIQUIDITY burned on first deposit

### Global

- `token0 < token1` for every pool (address-sorted)
- One pool per token pair — no duplicates
- Contract token balances >= sum of all pool reserves for that token
- Pool state only modified through the DEX contract (no external mutation)
