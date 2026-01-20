const fs = require('fs');
const path = require('path');

const projectRoot = path.resolve(__dirname, '..');
const contractsDir = path.join(projectRoot, 'contracts');
const broadcastFile = path.join(contractsDir, 'broadcast/Deploy.s.sol/31337/run-latest.json');

// Default to the react frontend if not specified
const frontendPathArg = process.argv[2] || '../olla-ui/lsp-react-standard';
const frontendDir = path.resolve(projectRoot, frontendPathArg);
const frontendAbisDir = path.join(frontendDir, 'src/abis');

console.log(`Syncing artifacts to ${frontendAbisDir}...`);

if (!fs.existsSync(broadcastFile)) {
    console.error('Error: Broadcast file not found. Run deployment first.');
    process.exit(1);
}

const broadcast = JSON.parse(fs.readFileSync(broadcastFile, 'utf8'));
const transactions = broadcast.transactions;

const addresses = {};

transactions.forEach(tx => {
    if (tx.transactionType === 'CREATE' && tx.contractName) {
        console.log(`Found deployment: ${tx.contractName} at ${tx.contractAddress}`);
        
        if (tx.contractName === 'ERC1967Proxy') {
            addresses['OllaCore'] = tx.contractAddress;
        } else if (tx.contractName === 'MockAztec') {
            addresses['Asset'] = tx.contractAddress;
        } else {
            addresses[tx.contractName] = tx.contractAddress;
        }
    }
});

if (!fs.existsSync(frontendAbisDir)) {
    fs.mkdirSync(frontendAbisDir, { recursive: true });
}

fs.writeFileSync(path.join(frontendAbisDir, 'addresses.json'), JSON.stringify(addresses, null, 2));

const artifactsToCopy = [
    { name: 'OllaCore', source: 'OllaCore.sol/OllaCore.json' },
    { name: 'StAztec', source: 'StAztec.sol/StAztec.json' },
    { name: 'MockAztec', source: 'MockAztec.sol/MockAztec.json' },
    { name: 'IERC20', source: 'IERC20.sol/IERC20.json' }
];

artifactsToCopy.forEach(artifact => {
    const sourcePath = path.join(contractsDir, 'out', artifact.source);
    if (fs.existsSync(sourcePath)) {
        const content = JSON.parse(fs.readFileSync(sourcePath, 'utf8'));
        const abi = content.abi;
        fs.writeFileSync(path.join(frontendAbisDir, `${artifact.name}.json`), JSON.stringify(abi, null, 2));
        console.log(`Copied ABI: ${artifact.name}`);
    } else {
        console.warn(`Warning: Artifact not found for ${artifact.name}`);
    }
});

console.log('Sync complete.');
