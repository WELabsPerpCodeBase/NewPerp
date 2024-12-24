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
import "./IIncreasePositionHandler.sol";
import "../vault/VaultLib.sol";
import "./PositionLib.sol";
import "../exception/Errs.sol";

contract IncreasePositionHandler is ReentrancyGuard, IIncreasePositionHandler {

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
        if (_gov != address(0)) {
            gov = _gov;
            emit UpdateGov(_gov);
        }
    }

    function setHandler(address _handler, bool _isActive) external onlyGov {
        isHandler[_handler] = _isActive;
        emit UpdateHandler(_handler, _isActive);
    }

    function increasePosition(PositionLib.IncreasePositionCache memory cache) external override nonReentrant onlyHandler {

        PositionLib.validateTokens(dataBase, cache.poolToken, cache.indexToken, cache.collateralToken);
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
            VaultLib.increaseGuaranteedUsd(dataBase, cache.poolToken, cache.indexToken, cache.sizeDelta + fee - collateralDeltaUsd);

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
            VaultLib.increaseGlobalShortSize(dataBase, cache.poolToken, cache.collateralToken, cache.sizeDelta);
        }

        PositionLib.savePosition(dataBase, position);

        emit IncreasePosition(key, cache.account, cache.poolToken, cache.collateralToken, cache.indexToken, collateralDeltaUsd, cache.sizeDelta, cache.isLong, price, fee);
        emit UpdatePosition(key, position.size, position.poolToken, position.collateral, position.averagePrice, position.entryFundingRate, position.reserveAmount, position.realisedPnl, price);
    }

}