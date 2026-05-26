const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying with:", deployer.address);

  // ── Fee ───────────────────────────────────────────────────────────────────
  // Static fallback used before the TWAP completes its first 30-min window.
  const fee = ethers.parseEther("0.01");

  // ── TWAP pair (optional) ──────────────────────────────────────────────────
  // Set these to enable dynamic $1 USD fee pricing via a Uniswap V2 WETH/USD pair.
  // Leave pair as address(0) to use only the static fallback fee above.
  const pair        = ethers.ZeroAddress;  // e.g. "0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc"
  const weth        = ethers.ZeroAddress;  // e.g. "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
  const usd         = ethers.ZeroAddress;  // e.g. "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48" (USDC)
  const usdDecimals = 6;                   // 6 for USDC/USDT, 18 for DAI

  const Locker = await ethers.getContractFactory("OneCoinLocker");
  const locker = await Locker.deploy(fee, pair, weth, usd, usdDecimals);
  await locker.waitForDeployment();

  console.log("1CoinLocker deployed to:", await locker.getAddress());
  console.log("Fallback fee:      ", ethers.formatEther(fee), "native token");
  console.log("TWAP pair:         ", pair === ethers.ZeroAddress ? "(none — static fee only)" : pair);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
