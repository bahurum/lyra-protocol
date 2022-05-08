//SPDX-License-Identifier: ISC
pragma solidity 0.8.9;

// Libraries
import "../../synthetix/DecimalMath.sol";

// Interfaces
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../../OptionMarket.sol";
import "../../OptionToken.sol";
import "../../interfaces/ICurve.sol";
import "../../interfaces/IFeeCounter.sol";

/**
 * @title OptionMarketWrapper
 * @author Lyra
 * @dev Allows users to open/close positions in any market with multiple stablecoins
 */
contract OptionMarketWrapperWithSwaps is Ownable {
  using DecimalMath for uint;

  ///////////////////
  // Internal Data //
  ///////////////////

  struct OptionMarketContracts {
    ERC20 quoteAsset;
    ERC20 baseAsset;
    OptionToken optionToken;
  }

  struct OptionPositionParams {
    OptionMarket optionMarket;
    uint strikeId; // The id of the relevant OptionListing
    uint positionId;
    uint iterations;
    uint setCollateralTo;
    uint currentCollateral;
    OptionType optionType; // Is the trade a long/short & call/put?
    uint amount; // The amount the user has requested to close
    uint minCost; // Min amount for the cost of the trade
    uint maxCost; // Max amount for the cost of the trade
    uint inputAmount; // Amount of stable coins the user can use
    ERC20 inputAsset; // Address of coin user wants to open with
  }

  struct ReturnDetails {
    address market;
    uint positionId;
    address owner;
    uint amount;
    uint totalCost;
    uint totalFee;
    int swapFee;
    address token;
  }

  struct StableAssetView {
    uint8 id;
    address token;
    uint8 decimals;
    string symbol;
    uint balance;
    uint allowance;
  }

  struct MarketAssetView {
    uint8 id;
    OptionMarket market;
    address token;
    uint8 decimals;
    string symbol;
    uint balance;
    uint allowance;
    bool isApprovedForAll;
  }

  ///////////////
  // Variables //
  ///////////////

  ICurve public curveSwap;
  SynthetixAdapter public synthetixAdapter;
  IFeeCounter public tradingRewards;
  uint public minReturnPercent = 9.8e17;
  uint8[] public ercIds;
  mapping(uint8 => ERC20) public idToERC;
  uint8[] public marketIds;
  mapping(uint8 => OptionMarket) public idToMarket;
  mapping(OptionMarket => OptionMarketContracts) public marketContracts;

  // Assume these can't change, so if cached, assume value is correct
  mapping(ERC20 => uint8) internal cachedDecimals;
  mapping(ERC20 => string) internal cachedSymbol;

  constructor() {}

  /**
   * @dev Initialises the contract
   *
   * @param _curveSwap The Curve contract address
   */
  function updateContractParams(
    ICurve _curveSwap,
    SynthetixAdapter _synthetixAdapter,
    IFeeCounter _tradingRewards,
    uint _minReturnPercent
  ) external onlyOwner {
    curveSwap = _curveSwap;
    synthetixAdapter = _synthetixAdapter;
    tradingRewards = _tradingRewards;
    minReturnPercent = _minReturnPercent;
    emit WrapperParamsUpdated(_curveSwap, _synthetixAdapter, _tradingRewards, _minReturnPercent);
  }

  /////////////////////
  // Admin functions //
  /////////////////////

  /**
   * @dev Adds stablecoin with desired index reflected in the curve contract
   *
   * @param token Address of the stablecoin
   * @param id Desired id to set the stablecoin
   */
  function addCurveStable(ERC20 token, uint8 id) external onlyOwner {
    _approveAsset(token, address(curveSwap));
    for (uint i = 0; i < ercIds.length; i++) {
      if (idToERC[ercIds[i]] == token || ercIds[i] == id) {
        revert DuplicateEntry(address(this), id, address(token));
      }
    }
    ercIds.push(id);
    idToERC[id] = token;

    cachedDecimals[token] = _getDecimals(token);
    cachedSymbol[token] = token.symbol();
  }

  function removeCurveStable(uint8 id) external onlyOwner {
    uint index = 0;
    bool found = false;
    for (uint i = 0; i < ercIds.length; i++) {
      if (ercIds[i] == id) {
        index = i;
        found = true;
        break;
      }
    }
    if (!found) {
      revert RemovingInvalidId(address(this), id);
    }
    ercIds[index] = ercIds[ercIds.length - 1];
    ercIds.pop();
    delete idToERC[id];
  }

  function addMarket(
    OptionMarket optionMarket,
    uint8 id,
    OptionMarketContracts memory _marketContracts
  ) external onlyOwner {
    marketContracts[optionMarket] = _marketContracts;

    _approveAsset(marketContracts[optionMarket].quoteAsset, address(optionMarket));
    _approveAsset(marketContracts[optionMarket].baseAsset, address(optionMarket));

    for (uint i = 0; i < marketIds.length; i++) {
      if (idToMarket[marketIds[i]] == optionMarket || marketIds[i] == id) {
        revert DuplicateEntry(address(this), id, address(optionMarket));
      }
    }

    cachedDecimals[_marketContracts.baseAsset] = _getDecimals(_marketContracts.baseAsset);
    cachedSymbol[_marketContracts.baseAsset] = _marketContracts.baseAsset.symbol();

    marketIds.push(id);
    idToMarket[id] = optionMarket;
  }

  function removeMarket(uint8 id) external onlyOwner {
    uint index = 0;
    for (uint i = 0; i < marketIds.length; i++) {
      if (marketIds[i] == id) index = i;
    }
    marketIds[index] = marketIds[ercIds.length - 1];
    marketIds.pop();
    delete marketContracts[idToMarket[id]];
    delete idToMarket[id];
  }

  ////////////////////
  // User functions //
  ////////////////////

  function openPosition(OptionPositionParams memory params) external returns (ReturnDetails memory returnDetails) {
    return _openPosition(params);
  }

  function closePosition(OptionPositionParams memory params) external returns (ReturnDetails memory returnDetails) {
    return _closePosition(params, false);
  }

  function forceClosePosition(OptionPositionParams memory params)
    external
    returns (ReturnDetails memory returnDetails)
  {
    return _closePosition(params, true);
  }

  function setCollateralWrapper(
    uint8 market,
    uint32 positionId,
    uint setCollateralTo
  ) external returns (uint newCollateral) {
    OptionMarket optionMarket = idToMarket[market];
    OptionMarketContracts memory c = marketContracts[optionMarket];
    OptionToken.PositionWithOwner memory currentPosition = c.optionToken.getPositionWithOwner(positionId);

    if (setCollateralTo > currentPosition.collateral) {
      if (currentPosition.optionType == OptionType.SHORT_CALL_BASE) {
        _transferAsset(c.baseAsset, msg.sender, address(this), setCollateralTo);
      } else if (
        currentPosition.optionType == OptionType.SHORT_CALL_QUOTE ||
        currentPosition.optionType == OptionType.SHORT_PUT_QUOTE
      ) {
        _transferAsset(c.quoteAsset, msg.sender, address(this), setCollateralTo);
      }
    }

    if (positionId != 0) {
      c.optionToken.transferFrom(msg.sender, address(this), positionId);
    }

    OptionToken.PositionWithOwner memory positionDetails = c.optionToken.getPositionWithOwner(positionId);

    OptionMarket.TradeInputParameters memory tradeParams = OptionMarket.TradeInputParameters({
      strikeId: positionDetails.strikeId,
      positionId: positionId,
      iterations: 1,
      optionType: positionDetails.optionType,
      amount: 0,
      setCollateralTo: setCollateralTo,
      minTotalCost: 0,
      maxTotalCost: 0
    });

    optionMarket.openPosition(tradeParams);

    // transfer the option token back to user
    c.optionToken.transferFrom(address(this), msg.sender, positionId);

    newCollateral = c.optionToken.getPositionWithOwner(positionId).collateral;
    emit SetCollateralTo(newCollateral);
  }

  //////////////
  // Internal //
  //////////////

  /**
   * @dev Attempts to open positions within bounds, reverts if the returned amount is outside of the accepted bounds.
   *
   * @param params The params required to open a position
   */
  function _openPosition(OptionPositionParams memory params) internal returns (ReturnDetails memory returnDetails) {
    OptionMarketContracts memory c = marketContracts[params.optionMarket];
    bool useOtherStable = address(params.inputAsset) != address(c.quoteAsset);
    int swapFee = 0;

    if (params.positionId != 0) {
      c.optionToken.transferFrom(msg.sender, address(this), params.positionId);
    }

    _transferBaseCollateral(params.optionType, params.currentCollateral, params.setCollateralTo, c.baseAsset);

    if (params.optionType != OptionType.SHORT_CALL_BASE) {
      // You want to take outstanding collateral - minCost from user (should be inputAmount)
      _transferAsset(params.inputAsset, msg.sender, address(this), params.inputAmount);

      if (useOtherStable && params.inputAmount != 0) {
        uint expected;
        if (!_isLong(params.optionType)) {
          uint collateralBalanceAfterTrade = params.currentCollateral + params.minCost;
          if (params.setCollateralTo > collateralBalanceAfterTrade) {
            expected = params.setCollateralTo - collateralBalanceAfterTrade;
          }
        } else {
          expected = params.maxCost;
        }
        if (expected > 0) {
          (, swapFee) = _swapWithCurve(
            address(params.inputAsset),
            address(c.quoteAsset),
            params.inputAmount,
            expected,
            address(this)
          );
        }
      }
    }

    // open position
    OptionMarket.TradeInputParameters memory tradeParameters = _composeTradeParams(params);
    OptionMarket.Result memory result = params.optionMarket.openPosition(tradeParameters);

    // Increments trading rewards contract
    _incrementTradingRewards(msg.sender, tradeParameters.amount, result.totalCost, result.totalFee);

    // transfer the option token to user
    c.optionToken.transferFrom(address(this), msg.sender, result.positionId);

    int addSwapFee = 0;
    (, addSwapFee) = _returnQuote(c.quoteAsset, params.inputAsset);
    swapFee += addSwapFee;

    returnDetails = _getReturnDetails(params, result, swapFee);
    _emitEvent(returnDetails, true, _isLong(params.optionType));
  }

  /**
   * @dev Attempts to close some amount of an open position within bounds, reverts if the returned amount is outside of
   * the accepted bounds.
   *
   * @param params The params required to open a position
   */
  function _closePosition(OptionPositionParams memory params, bool forceClose)
    internal
    returns (ReturnDetails memory returnDetails)
  {
    OptionMarketContracts memory c = marketContracts[params.optionMarket];
    bool useOtherStable = address(params.inputAsset) != address(c.quoteAsset);
    int swapFee = 0;

    c.optionToken.transferFrom(msg.sender, address(this), params.positionId);

    _transferBaseCollateral(params.optionType, params.currentCollateral, params.setCollateralTo, c.baseAsset);

    if (!_isLong(params.optionType)) {
      _transferAsset(params.inputAsset, msg.sender, address(this), params.inputAmount);

      if (useOtherStable) {
        uint expected = params.maxCost;
        if (params.optionType != OptionType.SHORT_CALL_BASE) {
          uint collateralBalanceAfterTrade = params.maxCost > params.currentCollateral
            ? 0
            : params.currentCollateral - params.maxCost;
          if (params.setCollateralTo > collateralBalanceAfterTrade) {
            expected = params.setCollateralTo - collateralBalanceAfterTrade;
          } else if (!_isLong(params.optionType)) {
            expected = 0;
          }
        }
        if (expected > 0) {
          (, swapFee) = _swapWithCurve(
            address(params.inputAsset),
            address(c.quoteAsset),
            params.inputAmount,
            expected,
            address(this)
          );
        }
      }
    }

    OptionMarket.TradeInputParameters memory tradeParameters = _composeTradeParams(params);
    OptionMarket.Result memory result;
    if (forceClose) {
      result = params.optionMarket.forceClosePosition(tradeParameters);
    } else {
      result = params.optionMarket.closePosition(tradeParameters);
    }

    // increments the fee counter for the user.
    _incrementTradingRewards(msg.sender, tradeParameters.amount, result.totalCost, result.totalFee);

    int addSwapFee;
    (, addSwapFee) = _returnQuote(c.quoteAsset, params.inputAsset);
    swapFee += addSwapFee;

    _returnBase(c.baseAsset, c.optionToken, result.positionId);

    returnDetails = _getReturnDetails(params, result, swapFee);
    _emitEvent(returnDetails, false, _isLong(params.optionType));
  }

  function _getReturnDetails(
    OptionPositionParams memory params,
    OptionMarket.Result memory result,
    int swapFee
  ) internal view returns (ReturnDetails memory) {
    return
      ReturnDetails({
        market: address(params.optionMarket),
        positionId: result.positionId,
        owner: msg.sender,
        amount: params.amount,
        totalCost: result.totalCost,
        totalFee: result.totalFee,
        swapFee: swapFee,
        token: address(params.inputAsset)
      });
  }

  //////////
  // Misc //
  //////////

  /**
   * @dev Returns addresses, balances and allowances of all supported tokens for a list of markets
   *
   * @param owner Owner of tokens
   */
  function getBalancesAndAllowances(address owner)
    external
    view
    returns (StableAssetView[] memory, MarketAssetView[] memory)
  {
    StableAssetView[] memory stableBalances = new StableAssetView[](ercIds.length);
    for (uint i = 0; i < ercIds.length; i++) {
      ERC20 token = idToERC[ercIds[i]];
      stableBalances[i] = StableAssetView({
        id: ercIds[i],
        decimals: cachedDecimals[token],
        symbol: cachedSymbol[token],
        token: address(token),
        balance: token.balanceOf(owner),
        allowance: token.allowance(owner, address(this))
      });
    }
    MarketAssetView[] memory marketBalances = new MarketAssetView[](marketIds.length);
    for (uint i = 0; i < marketIds.length; i++) {
      OptionMarket market = idToMarket[marketIds[i]];
      OptionMarketContracts memory c = marketContracts[market];
      marketBalances[i] = MarketAssetView({
        id: marketIds[i],
        market: market,
        token: address(c.baseAsset),
        decimals: cachedDecimals[c.baseAsset],
        symbol: cachedSymbol[c.baseAsset],
        balance: c.baseAsset.balanceOf(owner),
        allowance: c.baseAsset.allowance(owner, address(this)),
        isApprovedForAll: c.optionToken.isApprovedForAll(owner, address(this))
      });
    }
    return (stableBalances, marketBalances);
  }

  /**
   * @dev Returns quote back in the desired stablecoin
   *
   * @param inputAsset Stablecoin to be returned
   */
  function _returnQuote(ERC20 quoteAsset, ERC20 inputAsset) internal returns (uint quoteBalance, int swapFee) {
    quoteBalance = quoteAsset.balanceOf(address(this));
    if (quoteBalance > 0) {
      if (inputAsset != quoteAsset) {
        uint min = (minReturnPercent * 10**inputAsset.decimals()) / 10**quoteAsset.decimals();
        (quoteBalance, swapFee) = _swapWithCurve(
          address(quoteAsset),
          address(inputAsset),
          quoteBalance,
          quoteBalance.multiplyDecimal(min),
          address(this)
        );
      }
      _transferAsset(inputAsset, msg.sender, address(this), quoteBalance);
    }
  }

  /**
   * @dev Returns excess baseAsset back to user
   *
   * @param baseAsset Base asset to be returned
   * @param token OptionToken to check if active
   * @param positionId Is the positionId
   */
  function _returnBase(
    ERC20 baseAsset,
    OptionToken token,
    uint positionId
  ) internal {
    uint baseBalance = baseAsset.balanceOf(address(this));
    if (baseBalance > 0) {
      _transferAsset(baseAsset, msg.sender, address(this), baseBalance);
    }

    if (token.getPositionState(positionId) == PositionState.ACTIVE) {
      token.transferFrom(address(this), msg.sender, positionId);
    }
  }

  function _isLong(OptionType optionType) internal pure returns (bool) {
    return (optionType < OptionType.SHORT_CALL_BASE);
  }

  function _isBaseCollateral(OptionType optionType) internal pure returns (bool) {
    return (optionType == OptionType.SHORT_CALL_BASE);
  }

  /**
   * @dev Attempts to swap the input token with the desired stablecoin.
   *
   * @param _from Index value of coin being sent
   * @param _to Index of coin being received
   * @param _amount Quantity of _from being exchanged
   * @param _expected Minimum quantity of _to received in order for the transaction to succeed
   * @param _receiver The receiving address of the tokens
   */
  function _swapWithCurve(
    address _from,
    address _to,
    uint _amount,
    uint _expected,
    address _receiver
  ) internal returns (uint amountOut, int swapFee) {
    int8 toDec = int8(ERC20(_to).decimals());
    int8 fromDec = int8(ERC20(_from).decimals());
    uint balStart = ERC20(_from).balanceOf(address(this));

    amountOut = curveSwap.exchange_with_best_rate(_from, _to, _amount, _expected, _receiver);

    uint convertedAmtOut = amountOut;
    if (fromDec < toDec) {
      balStart = balStart * 10**(_abs(toDec - fromDec));
    } else if (fromDec > toDec) {
      convertedAmtOut = amountOut * 10**(_abs(toDec - fromDec));
    }

    swapFee = int(balStart) - int(convertedAmtOut);
  }

  function _transferBaseCollateral(
    OptionType optionType,
    uint currentCollateral,
    uint setCollateralTo,
    ERC20 baseAsset
  ) internal {
    if (optionType == OptionType.SHORT_CALL_BASE && setCollateralTo > currentCollateral) {
      _transferAsset(baseAsset, msg.sender, address(this), setCollateralTo - currentCollateral);
    }
  }

  function _transferAsset(
    ERC20 asset,
    address from,
    address to,
    uint amount
  ) internal {
    if (!asset.transferFrom(from, to, amount)) {
      revert AssetTransferFailed(address(this), asset, from, to, amount);
    }
  }

  function _approveAsset(ERC20 asset, address approving) internal {
    // Some contracts require resetting approval to 0 first
    if (!asset.approve(approving, 0)) {
      revert ApprovalFailure(address(this), asset, approving, 0);
    }
    if (!asset.approve(approving, type(uint).max)) {
      revert ApprovalFailure(address(this), asset, approving, type(uint).max);
    }
  }

  function _abs(int val) internal pure returns (uint) {
    return val >= 0 ? uint(val) : uint(-val);
  }

  function _composeTradeParams(OptionPositionParams memory params)
    internal
    pure
    returns (OptionMarket.TradeInputParameters memory tradeParameters)
  {
    return
      OptionMarket.TradeInputParameters({
        strikeId: params.strikeId,
        positionId: params.positionId,
        iterations: params.iterations,
        optionType: params.optionType,
        amount: params.amount,
        setCollateralTo: params.setCollateralTo,
        minTotalCost: params.minCost,
        maxTotalCost: params.maxCost
      });
  }

  function _emitEvent(
    ReturnDetails memory returnDetails,
    bool isOpen,
    bool isLong
  ) internal {
    emit PositionTraded(
      isOpen,
      isLong,
      returnDetails.market,
      returnDetails.positionId,
      returnDetails.owner,
      returnDetails.amount,
      returnDetails.totalCost,
      returnDetails.totalFee,
      returnDetails.swapFee,
      returnDetails.token
    );
  }

  // @dev function increments the trading rewards contract.
  // makes a call to the trading rewards contract
  function _incrementTradingRewards(
    address trader,
    uint amount,
    uint totalCost,
    uint totalFee
  ) internal {
    if (address(tradingRewards) != address(0)) {
      tradingRewards.trackFee(trader, amount, totalCost, totalFee, address(this));
    }
  }

  function _getDecimals(ERC20 token) internal view returns (uint8) {
    uint8 decimals;
    try token.decimals() returns (uint8 dec) {
      decimals = dec;
    } catch {
      decimals = 18;
    }
    return decimals;
  }

  ////////////
  // Events //
  ////////////

  /**
   * @dev Emitted when a position is traded
   */
  event PositionTraded(
    bool isOpen,
    bool isLong,
    address indexed market,
    uint indexed positionId,
    address indexed owner,
    uint amount,
    uint totalCost,
    uint totalFee,
    int swapFee,
    address token
  );

  /**
   * @dev Emitted when the contract parameters are updated
   */
  event WrapperParamsUpdated(
    ICurve curveSwap,
    SynthetixAdapter synthetixAdapter,
    IFeeCounter tradingRewards,
    uint minReturnPercent
  );

  /**
   * @dev Emitted collateral is changed for a position
   */
  event SetCollateralTo(uint newCollateral);

  ////////////
  // Errors //
  ////////////

  error AssetTransferFailed(address thrower, ERC20 asset, address sender, address receiver, uint amount);
  error ApprovalFailure(address thrower, ERC20 asset, address approving, uint approvalAmount);
  error DuplicateEntry(address thrower, uint8 id, address addr);
  error RemovingInvalidId(address thrower, uint8 id);
}
