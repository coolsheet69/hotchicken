const hre = require("hardhat");

async function main() {
  console.log("🐔🔥 Deploying Hot Chicken v3...\n");

  const ESHARE_ADDRESS = "0xb7C10146bA1b618956a38605AB6496523d450871";

  const [deployer] = await hre.ethers.getSigners();
  console.log("Deployer:", deployer.address);
  
  const balance = await hre.ethers.provider.getBalance(deployer.address);
  console.log("Balance:", hre.ethers.formatEther(balance), "ETH\n");

  console.log("Deploying...");
  const HotChicken = await hre.ethers.getContractFactory("HotChicken");
  const hotChicken = await HotChicken.deploy(ESHARE_ADDRESS);
  
  await hotChicken.waitForDeployment();
  const address = await hotChicken.getAddress();
  
  console.log("\n✅ HotChicken deployed to:", address);
  console.log("\n🔍 Verify with:");
  console.log(`npx hardhat verify --network base ${address} "${ESHARE_ADDRESS}"`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });