# `TestSynthetix`

## Functions:

- `init(contract ILyraGlobals _globals, contract ITestERC20 _quoteAsset) (external)`

- `addBaseAsset(bytes32 ticker, contract ITestERC20 baseAsset, address market) (external)`

- `exchange(bytes32 sourceCurrencyKey, uint256 sourceAmount, bytes32 destinationCurrencyKey) (public)`

- `exchangeOnBehalf(address exchangeForAddress, bytes32 sourceCurrencyKey, uint256 sourceAmount, bytes32 destinationCurrencyKey) (public)`

## Events:

- `Exchange(address exchangeForAddress, bytes32 sourceCurrencyKey, uint256 sourceAmount, bytes32 destinationCurrencyKey)`

### Function `init(contract ILyraGlobals _globals, contract ITestERC20 _quoteAsset) external`

### Function `addBaseAsset(bytes32 ticker, contract ITestERC20 baseAsset, address market) external`

### Function `exchange(bytes32 sourceCurrencyKey, uint256 sourceAmount, bytes32 destinationCurrencyKey) → uint256 amountReceived public`

### Function `exchangeOnBehalf(address exchangeForAddress, bytes32 sourceCurrencyKey, uint256 sourceAmount, bytes32 destinationCurrencyKey) → uint256 amountReceived public`

### Event `Exchange(address exchangeForAddress, bytes32 sourceCurrencyKey, uint256 sourceAmount, bytes32 destinationCurrencyKey)`
