const { assert } = require("chai");

require("@nomiclabs/hardhat-waffle");
require("@nomiclabs/hardhat-vyper");
require("@nomiclabs/hardhat-ethers");

// This is a sample Hardhat task. To learn how to create your own go to
// https://hardhat.org/guides/create-task.html
task("accounts", "Prints the list of accounts", async (taskArgs, hre) => {
  const accounts = await hre.ethers.getSigners();

  for (const account of accounts) {
    console.log(account.address);
  }
});

task("newVault", "Deploys and initializes a new vault")
  .addParam("tokenAddress", "the token that our users will put into the vault")
  .addParam("vaultName", "the vault name")
  .addParam("vaultSymbol", "shorthand name for the vault")
  .setAction(async (taskArgs, hre) => {
    const [deployer] = await ethers.getSigners();

    const Vault = await hre.ethers.getContractFactory("Vault");
    const vault = await Vault.deploy();
  
    await vault.deployed();
  
    console.log("Vault deployed to:", vault.address);
    const contractWithSigner = vault.connect(deployer);

    
    const network = await ethers.getDefaultProvider().getNetwork();
    console.log("Network name=", network.name);
    console.log("Network chain id=", network.chainId);
    

    //If we are not on a mainnet, also deploy a USDC clone contract
    let mimatic;
    if(network.name == "homestead") {
      const MiMatic = await hre.ethers.getContractFactory("AnyswapV5ERC20");
      mimatic = await MiMatic.deploy("MiMatic", "MAI", 18, ethers.constants.AddressZero, ethers.constants.AddressZero);
      await mimatic.deployed();
      tokenAddress = mimatic.address
      console.log(await mimatic.decimals());
      console.log("Deployed mimatic");
    }

    // https://github.com/ethers-io/ethers.js/issues/1160
    const tx = await contractWithSigner['initialize(address,address,address,string,string)'](
      mimatic.address,
      deployer.getAddress(),
      deployer.getAddress(),
      taskArgs.vaultName,
      taskArgs.vaultSymbol
    );
    console.log(vault.governance());
    console.log("Vault deployed and initialized");
});
 
task("updateVaultSettings", "Change settings of a vault, used once to setup the vault. Must be called with governance private key")
  .addParam("vaultAddress", "The address of the deployed vault")
  .addOptionalParam("managementFee", "The management fee of the vault, in Basis Points", 0, types.int)
  .addOptionalParam("performanceFee", "The performance fee of each strategy, in Basis Points", 100, types.int)
  .addOptionalParam("depositLimit", "The deposit limit, per user", 1000000000000, types.int)
  .addOptionalParam("management", "The address of the manager of the vault", "0x0", types.address)
  .setAction(async (taskArgs, hre) => {
    const [deployer] = await ethers.getSigners();

    const Vault = await ethers.getContractAt("Vault", taskArgs.vaultAddress);
    const vault = Vault.connect(deployer)
    //const governanceAddress = await vault['governance()']();

    assert.equal(await vault.governance(), await deployer.getAddress());

    console.log("Setting the management fee to %d", taskArgs.managementFee);
    await vault.setManagementFee(taskArgs.managementFee);
    console.log("Setting the performance fee to %d", taskArgs.performanceFee);
    await vault.setPerformanceFee(taskArgs.performanceFee);
    console.log("Setting the deposit limit to %d", taskArgs.depositLimit);
    await vault.setDepositLimit(taskArgs.depositLimit);

    if(taskArgs.management == "0x0") {
      taskArgs.management = await deployer.getAddress();
    }
    console.log("Setting the management to %s", taskArgs.management);
    await vault.setManagement(taskArgs.management);


});
/**
 * @type import('hardhat/config').HardhatUserConfig
 */
module.exports = {
  solidity: {
    compilers: [{ version: "0.6.12" }, { version: "0.8.4" }, { version: "0.8.2" }],
  },
  vyper: {
    compilers: [{ version: "0.2.1" }, { version: "0.3.1" }],
  },
};
