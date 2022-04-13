// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// When running the script with `npx hardhat run <script>` you'll find the Hardhat
// Runtime Environment's members available in the global scope.
const { ethers } = require('hardhat');
const hre = require('hardhat');

async function main() {
	await hre.run('compile');
	console.log(await ethers.provider.getBlockNumber());

	await hre.network.provider.request({
		method: 'hardhat_impersonateAccount',
		params: ['0x6618244141c824210dbc8ec9a95C9221c576470f'],
	});

	const signer = await ethers.getSigner('0x6618244141c824210dbc8ec9a95C9221c576470f');

	const USDC = await ethers.getContractAt('Usdc', '0x04068DA6C83AFCFA0e13ba15A6696662335D5B75');
	console.log(await signer.getBalance());
	console.log('Balance of my wallet: %d', await USDC.balanceOf('0xA0d991c8d8c0324bcC75f93b648De2c06D7F2Fd1'));
	console.log('Balance of his wallet: %d', await USDC.balanceOf('0x6618244141c824210dbc8ec9a95C9221c576470f'));
	const usdc = USDC.connect(signer);
	await usdc.transfer('0xA0d991c8d8c0324bcC75f93b648De2c06D7F2Fd1', 1000 * 10 ** 6);

	await hre.network.provider.request({
		method: 'hardhat_stopImpersonatingAccount',
		params: ['0x6618244141c824210dbc8ec9a95C9221c576470f'],
	});
	console.log('Balance of my wallet: %d', await USDC.balanceOf('0xA0d991c8d8c0324bcC75f93b648De2c06D7F2Fd1'));
	console.log('Balance of his wallet: %d', await USDC.balanceOf('0x6618244141c824210dbc8ec9a95C9221c576470f'));
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
	.then(() => process.exit(0))
	.catch((error) => {
		console.error(error);
		process.exit(1);
	});
