const hre = require("hardhat");

module.exports.deploy = deployVault;
async function deployVault() {
    const [deployer] = await ethers.getSigners();
    
    const Vault = await hre.ethers.getContractFactory("Vault");
    const vault = await Vault.deploy();
  
    await vault.deployed();
  
    console.log("Vault deployed to:", vault.address);
    vault.func
  }


deployVault()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });