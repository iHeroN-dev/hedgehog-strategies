// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// When running the script with `npx hardhat run <script>` you'll find the Hardhat
// Runtime Environment's members available in the global scope.
const { BigNumber } = require('ethers');
const { ethers } = require('hardhat');
const hre = require('hardhat');

async function main() {
	await hre.run('compile');
	console.log(await ethers.provider.getBlockNumber());

	await hre.network.provider.request({
		method: 'hardhat_impersonateAccount',
		params: ['0xb8798Daf76106D2546442a1ea04f8aa66b4Afe33'],
	});

	const signer = await ethers.getSigner('0xb8798Daf76106D2546442a1ea04f8aa66b4Afe33');

	console.log(
		'Balance of my wallet: %d',
		await ethers.provider.getBalance('0xA0d991c8d8c0324bcC75f93b648De2c06D7F2Fd1')
	);

	console.log(
		'Balance of wallet to impersonate: %d',
		await ethers.provider.getBalance('0xb8798Daf76106D2546442a1ea04f8aa66b4Afe33')
	);
	const tx = await signer.sendTransaction({
		to: '0xA0d991c8d8c0324bcC75f93b648De2c06D7F2Fd1',
		value: BigNumber.from(100000000000000000000n),
	});
	await hre.network.provider.request({
		method: 'hardhat_stopImpersonatingAccount',
		params: ['0xb8798Daf76106D2546442a1ea04f8aa66b4Afe33'],
	});
	console.log(
		'Balance of my wallet: %d',
		await ethers.provider.getBalance('0xA0d991c8d8c0324bcC75f93b648De2c06D7F2Fd1')
	);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
	.then(() => process.exit(0))
	.catch((error) => {
		console.error(error);
		process.exit(1);
	});
