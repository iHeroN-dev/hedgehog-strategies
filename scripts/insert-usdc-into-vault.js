// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// When running the script with `npx hardhat run <script>` you'll find the Hardhat
// Runtime Environment's members available in the global scope.
const { ethers } = require('hardhat');
const hre = require('hardhat');

async function main() {
	console.log(await ethers.provider.getBlockNumber());

	await hre.network.provider.request({
		method: 'hardhat_impersonateAccount',
		params: ['0xA0d991c8d8c0324bcC75f93b648De2c06D7F2Fd1'],
	});

	const signer = await ethers.getSigner('0xA0d991c8d8c0324bcC75f93b648De2c06D7F2Fd1');

	const USDC = await ethers.getContractAt('Usdc', '0x04068DA6C83AFCFA0e13ba15A6696662335D5B75');
	console.log(await signer.getBalance());
	console.log('Balance of my wallet before: %d', await USDC.balanceOf('0xA0d991c8d8c0324bcC75f93b648De2c06D7F2Fd1'));
	const usdc = USDC.connect(signer);
	await usdc.approve('0xDC11f7E700A4c898AE5CAddB1082cFfa76512aDD', 1000 * 10 ** 6);

	const Vault = await ethers.getContractAt('Vault', '0xDC11f7E700A4c898AE5CAddB1082cFfa76512aDD');
	const vault = Vault.connect(signer);
	console.log(await vault.governance());
	console.log('Depositing into the vault...');

	await vault['deposit(uint256)'](1000 * 10 ** 6);

	console.log('Balance of my wallet after: %d', await USDC.balanceOf('0xA0d991c8d8c0324bcC75f93b648De2c06D7F2Fd1'));
	console.log('Number of shares: %d', await vault.balanceOf('0xA0d991c8d8c0324bcC75f93b648De2c06D7F2Fd1'));
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
	.then(() => process.exit(0))
	.catch((error) => {
		console.error(error);
		process.exit(1);
	});
