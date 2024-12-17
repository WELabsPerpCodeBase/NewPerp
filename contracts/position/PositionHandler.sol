// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DataBase} from "../repo/DataBase.sol";
import "../utils/Keys.sol";
import "../repo/Dao.sol";
import "../pool/IPoolToken.sol";
import "../oracle/PriceLib.sol";
import "./IPositionHandler.sol";
import "../vault/VaultLib.sol";
import "./PositionLib.sol";
import "../exception/Errs.sol";

contract PositionHandler is ReentrancyGuard, IPositionHandler {

    DataBase public immutable dataBase;
    address public override gov;
    mapping (address => bool) public override isHandler;

    event IncreasePosition(
        bytes32 key,
        address account,
        address poolToken,
        address collateralToken,
        address indexToken,
        uint256 collateralDeltaUsd,
        uint256 sizeDelta,
        bool isLong,
        uint256 price,
        uint256 fee
    );
    event UpdatePnl(bytes32 key, bool hasProfit, uint256 delta);
    event DecreasePosition(
        bytes32 key,
        address account,
        address poolToken,
        address collateralToken,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        uint256 price,
        uint256 fee
    );
    event UpdatePosition(
        bytes32 key,
        uint256 size,
        address poolToken,
        uint256 collateral,
        uint256 averagePrice,
        uint256 entryFundingRate,
        uint256 reserveAmount,
        int256 realisedPnl,
        uint256 markPrice
    );
    event ClosePosition(
        bytes32 key,
        uint256 size,
        address poolToken,
        uint256 collateral,
        uint256 averagePrice,
        uint256 entryFundingRate,
        uint256 reserveAmount,
        int256 realisedPnl
    );
    event LiquidatePosition(
        bytes32 key,
        address account,
        address poolToken,
        address collateralToken,
        address indexToken,
        bool isLong,
        uint256 size,
        uint256 collateral,
        uint256 reserveAmount,
        int256 realisedPnl,
        uint256 markPrice
    );

    event UpdateGov(address gov);
    event UpdateHandler(address handler, bool isActive);

    error Unauthorized(address);

    modifier onlyGov() {
        if (msg.sender != gov) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyHandler() {
        if (!isHandler[msg.sender]) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    constructor(DataBase _dataBase) {
        dataBase = _dataBase;
        gov = msg.sender;
    }

    function setGov(address _gov) external onlyGov {
        gov = _gov;
        emit UpdateGov(_gov);
    }

    function setHandler(address _handler, bool _isActive) external onlyGov {
        isHandler[_handler] = _isActive;
        emit UpdateHandler(_handler, _isActive);
    }

    function increasePosition(PositionLib.IncreasePositionCache memory cache) external override nonReentrant onlyHandler {
        VaultLib.updateCumulativeFundingRate(dataBase, cache.poolToken, cache.collateralToken, cache.indexToken);

        bytes32 key = PositionLib.getPositionKey(cache.account, cache.poolToken, cache.collateralToken, cache.indexToken, cache.isLong);
        PositionLib.Position memory position = PositionLib.getPosition(dataBase, key);
        if (position.account == address(0)) {
            position.account = cache.account;
            position.poolToken = cache.poolToken;
            position.collateralToken = cache.collateralToken;
            position.indexToken = cache.indexToken;
            position.isLong = cache.isLong;
        }

        uint256 price = cache.isLong ? PriceLib.pricesMax(dataBase, cache.indexToken) : PriceLib.pricesMin(dataBase, cache.indexToken);

        if (position.size == 0) {
            position.averagePrice = price;
        }

        if (position.size > 0 && cache.sizeDelta > 0) {
            position.averagePrice = PositionLib.getNextAveragePrice(dataBase, cache.indexToken, position.size, position.averagePrice, position.isLong, price, cache.sizeDelta, position.lastIncreasedTime);
        }

        PositionLib.MarginFeeParams memory marginFeeParams = PositionLib.MarginFeeParams({
            account: position.account,
            poolToken: position.poolToken,
            indexToken: position.indexToken,
            collateralToken: position.collateralToken,
            size: position.size,
            sizeDelta: cache.sizeDelta,
            entryFundingRate: position.entryFundingRate,
            isLong: position.isLong
        });
        uint256 fee = VaultLib.collectMarginFees(dataBase, marginFeeParams);

        uint256 collateralDelta = VaultLib.transferIn(dataBase, address(this), cache.collateralToken);
        uint256 collateralDeltaUsd = PriceLib.tokenToUsdMin(dataBase, cache.collateralToken, Dao.tokenDecimals(dataBase, cache.collateralToken), collateralDelta);
        VaultLib.transferOut(dataBase, address(this), cache.collateralToken, collateralDelta, cache.poolToken);

        position.collateral = position.collateral + collateralDeltaUsd;
        if (position.collateral < fee) {
            revert Errs.InsufficientCollateralForFees(position.collateral, fee);
        }

        position.collateral = position.collateral - fee;
        position.entryFundingRate = PositionLib.getEntryFundingRate(dataBase, cache.poolToken, cache.collateralToken, cache.indexToken, cache.isLong);
        position.size = position.size + cache.sizeDelta;
        position.lastIncreasedTime = block.timestamp;
        if (position.size <= 0) {
            revert Errs.InvalidPositionDotSize();
        }

        uint256 reserveDelta = PriceLib.usdToTokenMax(dataBase, cache.collateralToken, cache.sizeDelta);
        position.reserveAmount = position.reserveAmount + reserveDelta;
        VaultLib.increaseReservedAmount(dataBase, cache.poolToken, cache.collateralToken, reserveDelta);

        if (cache.isLong) {
            VaultLib.increaseGuaranteedUsd(dataBase, cache.poolToken, cache.collateralToken, cache.sizeDelta + fee);
            VaultLib.decreaseGuaranteedUsd(dataBase, cache.poolToken, cache.collateralToken, collateralDeltaUsd);

            VaultLib.increasePoolAmount(dataBase, cache.poolToken, cache.collateralToken, collateralDelta);

            uint256 feeAmount = PriceLib.usdToTokenMin(dataBase, cache.collateralToken, fee);
            VaultLib.decreasePoolAmount(dataBase, cache.poolToken, cache.collateralToken, feeAmount);
        } else {
            if (Dao.globalShortSize(dataBase, cache.poolToken, cache.indexToken) == 0) {
                Dao.setGlobalShortAveragePrice(dataBase, cache.poolToken, cache.indexToken, price);
            } else {
                uint256 nextAveragePrice = VaultLib.getNextGlobalShortAveragePrice(dataBase, cache.poolToken, cache.indexToken, price, cache.sizeDelta);
                Dao.setGlobalShortAveragePrice(dataBase, cache.poolToken, cache.indexToken, nextAveragePrice);
            }

            VaultLib.increaseGlobalShortSize(dataBase, cache.poolToken, cache.indexToken, cache.sizeDelta);
        }

        PositionLib.savePosition(dataBase, position);

        emit IncreasePosition(key, cache.account, cache.poolToken, cache.collateralToken, cache.indexToken, collateralDeltaUsd, cache.sizeDelta, cache.isLong, price, fee);
        emit UpdatePosition(key, position.size, position.poolToken, position.collateral, position.averagePrice, position.entryFundingRate, position.reserveAmount, position.realisedPnl, price);
    }

    function decreasePosition(PositionLib.DecreasePositionCache memory cache) external override nonReentrant onlyHandler returns (uint256) {
        return _decreasePosition(cache);
    }

    function liquidatePosition(PositionLib.LiquidatePositionCache memory cache) external override nonReentrant onlyHandler {

        VaultLib.updateCumulativeFundingRate(dataBase, cache.poolToken, cache.collateralToken, cache.indexToken);

        bytes32 key = PositionLib.getPositionKey(cache.account, cache.poolToken, cache.collateralToken, cache.indexToken, cache.isLong);

        PositionLib.Position memory position = PositionLib.getPosition(dataBase, key);
        if (position.size <= 0) {
            revert Errs.EmptyPosition();
        }

        (uint256 liquidationState, uint256 marginFees) = PositionLib.validateLiquidation(dataBase, position, false);
        if (liquidationState == 0) {
            revert Errs.CannotBeLiquidated();
        }
        if (liquidationState == 2) {
            PositionLib.DecreasePositionCache memory decCache = PositionLib.DecreasePositionCache({
                account: cache.account,
                poolToken: cache.poolToken,
                indexToken: cache.indexToken,
                collateralToken: cache.collateralToken,
                collateralDelta: 0,
                sizeDelta: position.size,
                isLong: cache.isLong,
                receiver: cache.account
            });

            _decreasePosition(decCache);
            return;
        }

        uint256 feeTokens = PriceLib.usdToTokenMin(dataBase, cache.collateralToken, marginFees);
        VaultLib.collectMarginFees(dataBase, cache.poolToken, cache.collateralToken, feeTokens, marginFees);

        VaultLib.decreaseReservedAmount(dataBase, cache.poolToken, cache.collateralToken, position.reserveAmount);

        if (cache.isLong) {
            VaultLib.decreaseGuaranteedUsd(dataBase, cache.poolToken, cache.collateralToken, position.size - position.collateral);
            VaultLib.decreaseGuaranteedUsd(dataBase, cache.poolToken, cache.indexToken, position.size - position.collateral);
            VaultLib.decreasePoolAmount(dataBase, cache.poolToken, cache.collateralToken, feeTokens);
        }

        uint256 markPrice = PriceLib.pricesLow(dataBase, cache.indexToken, cache.isLong);
        emit LiquidatePosition(key, cache.account, cache.poolToken, cache.collateralToken, cache.indexToken, cache.isLong, position.size, position.collateral, position.reserveAmount, position.realisedPnl, markPrice);

        if (!cache.isLong && marginFees < position.collateral) {
            uint256 remainingCollateral = position.collateral - marginFees;
            VaultLib.increasePoolAmount(dataBase, cache.poolToken, cache.collateralToken, PriceLib.usdToTokenMin(dataBase, cache.collateralToken, remainingCollateral));
        }

        if (!cache.isLong) {
            VaultLib.decreaseGlobalShortSize(dataBase, cache.poolToken, cache.indexToken, position.size);
        }

        PositionLib.removePosition(dataBase, cache.account, cache.poolToken, key);

        uint256 liquidationFeeUsd = Dao.liquidationFeeUsd(dataBase, cache.poolToken);
        uint256 liquidationFeeAmount = PriceLib.usdToTokenMin(dataBase, cache.collateralToken, liquidationFeeUsd);
        VaultLib.decreasePoolAmount(dataBase, cache.poolToken, cache.collateralToken, liquidationFeeAmount);

        VaultLib.poolTransferOut(dataBase, cache.poolToken, cache.collateralToken, liquidationFeeAmount, cache.feeReceiver);
    }

    function _decreasePosition(PositionLib.DecreasePositionCache memory cache) private returns (uint256) {
        VaultLib.updateCumulativeFundingRate(dataBase, cache.poolToken, cache.collateralToken, cache.indexToken);

        bytes32 key = PositionLib.getPositionKey(cache.account, cache.poolToken, cache.collateralToken, cache.indexToken, cache.isLong);
        PositionLib.Position memory position = PositionLib.getPosition(dataBase, key);
        if (position.size <= 0) {
            revert Errs.EmptyPosition();
        }
        if (position.size < cache.sizeDelta) {
            revert Errs.PositionSizeExceeded();
        }
        if (position.collateral < cache.collateralDelta) {
            revert Errs.PositionCollateralExceeded();
        }

        uint256 collateral = position.collateral;
        {
            uint256 reserveDelta = position.reserveAmount * cache.sizeDelta / position.size;
            position.reserveAmount = position.reserveAmount - reserveDelta;
            VaultLib.decreaseReservedAmount(dataBase, cache.poolToken, cache.collateralToken, reserveDelta);
        }

        (uint256 usdOut, uint256 usdOutAfterFee) = _reduceCollateral(cache, position);
        position.collateral = PositionLib.getFieldCollateralUsd(dataBase, key);
        position.realisedPnl = PositionLib.getFieldRealisedPnl(dataBase, key);

        if (position.size != cache.sizeDelta) {
            position.entryFundingRate = PositionLib.getEntryFundingRate(dataBase, cache.poolToken, cache.collateralToken, cache.indexToken, cache.isLong);
            position.size = position.size - cache.sizeDelta;

            if (cache.isLong) {
                VaultLib.increaseGuaranteedUsd(dataBase, cache.poolToken, cache.collateralToken, collateral - position.collateral);
                VaultLib.decreaseGuaranteedUsd(dataBase, cache.poolToken, cache.collateralToken, cache.sizeDelta);
                VaultLib.increaseGuaranteedUsd(dataBase, cache.poolToken, cache.indexToken, collateral - position.collateral);
                VaultLib.decreaseGuaranteedUsd(dataBase, cache.poolToken, cache.indexToken, cache.sizeDelta);

            }

            PositionLib.savePosition(dataBase, position);
            uint256 price = cache.isLong ? PriceLib.pricesMin(dataBase, cache.indexToken) : PriceLib.pricesMax(dataBase, cache.indexToken);
            emit DecreasePosition(key, cache.account, cache.poolToken, cache.collateralToken, cache.indexToken, cache.collateralDelta, cache.sizeDelta, cache.isLong, price, usdOut-usdOutAfterFee);
            emit UpdatePosition(key, position.size, position.poolToken, position.collateral, position.averagePrice, position.entryFundingRate, position.reserveAmount, position.realisedPnl, price);
        } else {
            if (cache.isLong) {
                VaultLib.increaseGuaranteedUsd(dataBase, cache.poolToken, cache.collateralToken, collateral);
                VaultLib.decreaseGuaranteedUsd(dataBase, cache.poolToken, cache.collateralToken, cache.sizeDelta);
                VaultLib.increaseGuaranteedUsd(dataBase, cache.poolToken, cache.indexToken, collateral);
                VaultLib.decreaseGuaranteedUsd(dataBase, cache.poolToken, cache.indexToken, cache.sizeDelta);
            }

            uint256 price = cache.isLong ? PriceLib.pricesMin(dataBase, cache.indexToken) : PriceLib.pricesMax(dataBase, cache.indexToken);
            emit DecreasePosition(key, cache.account, cache.poolToken, cache.collateralToken, cache.indexToken, cache.collateralDelta, cache.sizeDelta, cache.isLong, price, usdOut-usdOutAfterFee);
            emit ClosePosition(key, position.size, position.poolToken, position.collateral, position.averagePrice, position.entryFundingRate, position.reserveAmount, position.realisedPnl);

            PositionLib.removePosition(dataBase, cache.account, cache.poolToken, key);
        }

        if (!cache.isLong) {
            VaultLib.decreaseGlobalShortSize(dataBase, cache.poolToken, cache.indexToken, cache.sizeDelta);
        }

        if (usdOut > 0) {
            if (cache.isLong) {
                VaultLib.decreasePoolAmount(dataBase, cache.poolToken, cache.collateralToken, PriceLib.usdToTokenMin(dataBase, cache.collateralToken, usdOut));
            }
            uint256 amountOutAfterFees = PriceLib.usdToTokenMin(dataBase, cache.collateralToken, usdOutAfterFee);
            VaultLib.poolTransferOut(dataBase, cache.poolToken, cache.collateralToken, amountOutAfterFees, cache.receiver);
            return amountOutAfterFees;
        }

        return 0;
    }

    function _reduceCollateral(PositionLib.DecreasePositionCache memory cache, PositionLib.Position memory position) private returns (uint256, uint256) {
        bytes32 key = PositionLib.getPositionKey(cache.account, cache.poolToken, cache.collateralToken, cache.indexToken, cache.isLong);

        PositionLib.MarginFeeParams memory marginFeeParams = PositionLib.MarginFeeParams({
            account: position.account,
            poolToken: position.poolToken,
            indexToken: position.indexToken,
            collateralToken: position.collateralToken,
            size: position.size,
            sizeDelta: cache.sizeDelta,
            entryFundingRate: position.entryFundingRate,
            isLong: position.isLong
        });

        uint256 fee = VaultLib.collectMarginFees(dataBase, marginFeeParams);
        bool hasProfit;
        uint256 adjustedDelta;

        {
            (bool _hasProfit, uint256 delta) = PositionLib.getDelta(dataBase, position.indexToken, position.size, position.averagePrice, position.isLong, position.lastIncreasedTime);
            hasProfit = _hasProfit;
            adjustedDelta = cache.sizeDelta * delta / position.size;
        }

        uint256 usdOut;
        if (hasProfit && adjustedDelta > 0) {
            usdOut = adjustedDelta;
            position.realisedPnl = position.realisedPnl + int256(adjustedDelta);

            if (!cache.isLong) {
                uint256 tokenAmount = PriceLib.usdToTokenMin(dataBase, cache.collateralToken, adjustedDelta);
                VaultLib.decreasePoolAmount(dataBase, cache.poolToken, cache.collateralToken, tokenAmount);
            }
        }

        if (!hasProfit && adjustedDelta > 0) {
            position.collateral = position.collateral - adjustedDelta;

            if (!cache.isLong) {
                uint256 tokenAmount = PriceLib.usdToTokenMin(dataBase, cache.collateralToken, adjustedDelta);
                VaultLib.increasePoolAmount(dataBase, cache.poolToken, cache.collateralToken, tokenAmount);
            }

            position.realisedPnl = position.realisedPnl - int256(adjustedDelta);
        }

        if (cache.collateralDelta > 0) {
            usdOut = usdOut + cache.collateralDelta;
            position.collateral = position.collateral - cache.collateralDelta;
        }

        if (position.size == cache.sizeDelta) {
            usdOut = usdOut + position.collateral;
            position.collateral = 0;
        }

        uint256 usdOutAfterFee = usdOut;
        if (usdOut > fee) {
            usdOutAfterFee = usdOut - fee;
        } else {
            position.collateral = position.collateral - fee;
            if (cache.isLong) {
                uint256 feeTokens = PriceLib.usdToTokenMin(dataBase, cache.collateralToken, fee);
                VaultLib.decreasePoolAmount(dataBase, cache.poolToken, cache.collateralToken, feeTokens);
            }
        }

        PositionLib.setFieldCollateralUsd(dataBase, key, position.collateral);
        PositionLib.setFieldRealisedPnl(dataBase, key, position.realisedPnl);

        emit UpdatePnl(key, hasProfit, adjustedDelta);

        return (usdOut, usdOutAfterFee);
    }

}