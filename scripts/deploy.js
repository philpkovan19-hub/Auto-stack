const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);
  const bal = await ethers.provider.getBalance(deployer.address);
  console.log("Balance :", ethers.formatEther(bal), "BOT");

  const F = await ethers.getContractFactory("AutoStack");
  const c = await F.deploy();
  await c.waitForDeployment();
  const addr = await c.getAddress();
  console.log("AutoStack deployed to:", addr);
  console.log("\n>>> Update CONTRACT_ADDRESS in frontend/index.html with:", addr);
}

main().catch((e) => { console.error(e); process.exit(1); });
