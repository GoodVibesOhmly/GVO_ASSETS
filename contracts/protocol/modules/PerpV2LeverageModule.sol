/*
    Copyright 2021 Set Labs Inc.

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.

    SPDX-License-Identifier: Apache License, Version 2.0
*/

pragma solidity 0.6.10;
pragma experimental "ABIEncoderV2";

import "@openzeppelin/contracts/math/SignedSafeMath.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import { PerpV2 } from "../integration/lib/PerpV2.sol";
import { UniswapV3Math } from "../integration/lib/UniswapV3Math.sol";
import { IAccountBalance } from "../../interfaces/external/perp-v2/IAccountBalance.sol";
import { IClearingHouse } from "../../interfaces/external/perp-v2/IClearingHouse.sol";
import { IClearingHouseConfig } from "../../interfaces/external/perp-v2/IClearingHouseConfig.sol";
import { IExchange } from "../../interfaces/external/perp-v2/IExchange.sol";
import { IIndexPrice } from "../../interfaces/external/perp-v2/IIndexPrice.sol";
import { IVault } from "../../interfaces/external/perp-v2/IVault.sol";
import { IQuoter } from "../../interfaces/external/perp-v2/IQuoter.sol";
import { IMarketRegistry } from "../../interfaces/external/perp-v2/IMarketRegistry.sol";
import { IController } from "../../interfaces/IController.sol";
import { IDebtIssuanceModule } from "../../interfaces/IDebtIssuanceModule.sol";
import { IModuleIssuanceHookV2 } from "../../interfaces/IModuleIssuanceHookV2.sol";
import { ISetToken } from "../../interfaces/ISetToken.sol";
import { ModuleBase } from "../lib/ModuleBase.sol";
import { SetTokenAccessible } from "../lib/SetTokenAccessible.sol";
import { PreciseUnitMath } from "../../lib/PreciseUnitMath.sol";
import { AddressArrayUtils } from "../../lib/AddressArrayUtils.sol";
import { UnitConversionUtils } from "../../lib/UnitConversionUtils.sol";

/**
 * @title PerpV2LeverageModule
 * @author Set Protocol
 * @notice Smart contract that enables leveraged trading using the PerpV2 protocol. Each SetToken can only manage a single Perp account
 * represented as a positive equity external position whose value is the net Perp account value denominated in the collateral token
 * deposited into the Perp Protocol. This module only allows Perp positions to be collateralized by one asset, USDC, set on deployment of
 * this contract (see collateralToken) however it can take positions simultaneously in multiple base assets.
 *
 * Upon issuance and redemption positions are not EXACTLY replicated like for other position types since a trade is necessary to enter/exit
 * the position on behalf of the issuer/redeemer. Any cost of entering/exiting the position (slippage) is carried by the issuer/redeemer.
 * Any pending funding costs or PnL is carried by the current token holders. To be used safely this module MUST issue using the
 * SlippageIssuanceModule or else issue and redeem transaction could be sandwich attacked.
 *
 * NOTE: The external position unit is only updated on an as-needed basis during issuance/redemption. It does not reflect the current
 * value of the Set's perpetual position. The current value can be calculated from getPositionNotionalInfo.
 */
contract PerpV2LeverageModule is ModuleBase, ReentrancyGuard, Ownable, SetTokenAccessible, IModuleIssuanceHookV2 {
    using PerpV2 for ISetToken;
    using PreciseUnitMath for int256;
    using SignedSafeMath for int256;
    using UnitConversionUtils for int256;
    using UniswapV3Math for uint160;
    using UniswapV3Math for uint256;
    using UnitConversionUtils for uint256;
    using AddressArrayUtils for address[];

    /* ============ Structs ============ */

    struct ActionInfo {
        ISetToken setToken;
        address baseToken;              // Virtual token minted by the Perp protocol
        bool isBuy;                     // When true, `baseToken` is being bought, when false, sold
        uint256 baseTokenAmount;        // Base token quantity in 10**18 decimals
        uint256 oppositeAmountBound;    // vUSDC pay or receive quantity bound (see `_createActionInfoNotional` for details)
    }

    struct PositionNotionalInfo {
        address baseToken;              // Virtual token minted by the Perp protocol
        int256 baseBalance;             // Base position notional quantity in 10**18 decimals. When negative, position is short
        int256 quoteBalance;            // vUSDC "debt" notional quantity minted to open position. When positive, position is short
    }

    struct PositionUnitInfo {
        address baseToken;              // Virtual token minted by the Perp protocol
        int256 baseUnit;                // Base position unit. When negative, position is short
        int256 quoteUnit;               // vUSDC "debt" position unit. When positive, position is short
    }

    // Note: when `pendingFundingPayments` is positive it will be credited to account on settlement,
    // when negative it's a debt owed that will be repaid on settlement. (PerpProtocol.Exchange returns the value
    // with the opposite meaning, e.g positively signed payments are owed by account to system).
    struct AccountInfo {
        int256 collateralBalance;       // Quantity of collateral deposited in Perp vault in 10**18 decimals
        int256 owedRealizedPnl;         // USDC quantity of profit and loss in 10**18 decimals not yet settled to vault
        int256 pendingFundingPayments;  // USDC quantity of pending funding payments in 10**18 decimals
        int256 netQuoteBalance;         // USDC quantity of net quote balance for all open positions in Perp account
    }

    /* ============ Events ============ */

    /**
     * @dev Emitted on trade
     * @param _setToken         Instance of SetToken
     * @param _baseToken        Virtual token minted by the Perp protocol
     * @param _deltaBase        Change in baseToken position size resulting from trade
     * @param _deltaQuote       Change in vUSDC position size resulting from trade
     * @param _protocolFee      Quantity in collateral decimals sent to fee recipient during lever trade
     * @param _isBuy            True when baseToken is being bought, false when being sold
     */
    event PerpTraded(
        ISetToken indexed _setToken,
        address indexed _baseToken,
        uint256 indexed _deltaBase,
        uint256 _deltaQuote,
        uint256 _protocolFee,
        bool _isBuy
    );

    /**
     * @dev Emitted on deposit (not issue or redeem)
     * @param _setToken             Instance of SetToken
     * @param _collateralToken      Token being deposited as collateral (USDC)
     * @param _amountDeposited      Amount of collateral being deposited into Perp
     */
    event CollateralDeposited(
        ISetToken indexed _setToken,
        IERC20 indexed _collateralToken,
        uint256 indexed _amountDeposited
    );

    /**
     * @dev Emitted on withdraw (not issue or redeem)
     * @param _setToken             Instance of SetToken
     * @param _collateralToken      Token being withdrawn as collateral (USDC)
     * @param _amountWithdrawn      Amount of collateral being withdrawn from Perp
     */
    event CollateralWithdrawn(
        ISetToken indexed _setToken,
        IERC20 indexed _collateralToken,
        uint256 indexed _amountWithdrawn
    );

    /* ============ Constants ============ */

    // String identifying the DebtIssuanceModule in the IntegrationRegistry. Note: Governance must add DefaultIssuanceModule as
    // the string as the integration name
    string constant internal DEFAULT_ISSUANCE_MODULE_NAME = "DefaultIssuanceModule";

    // 0 index stores protocol fee % on the controller, charged in the _executeTrade function
    uint256 constant internal PROTOCOL_TRADE_FEE_INDEX = 0;

    /* ============ State Variables ============ */

    // Token (USDC) used as a vault deposit, Perp currently only supports USDC as it's settlement and collateral token
    IERC20 public immutable collateralToken;

    // Decimals of collateral token. We set this in the constructor for later reading
    uint8 internal immutable collateralDecimals;

    // PerpV2 contract which provides getters for base, quote, and owedRealizedPnl balances
    IAccountBalance public immutable perpAccountBalance;

    // PerpV2 contract which provides a trading API
    IClearingHouse public immutable perpClearingHouse;

    // PerpV2 contract which manages trading logic. Provides getters for UniswapV3 pools and pending funding balances
    IExchange public immutable perpExchange;

    // PerpV2 contract which handles deposits and withdrawals. Provides getter for collateral balances
    IVault public immutable perpVault;

    // PerpV2 contract which makes it possible to simulate a trade before it occurs
    IQuoter public immutable perpQuoter;

    // PerpV2 contract which provides a getter for baseToken UniswapV3 pools
    IMarketRegistry public immutable perpMarketRegistry;

    // Mapping of SetTokens to an array of virtual token addresses the Set has open positions for.
    // Array is updated when new positions are opened or old positions are zeroed out.
    mapping(ISetToken => address[]) internal positions;

    /* ============ Constructor ============ */

    /**
     * @dev Sets external PerpV2 Protocol contract addresses. Sets `collateralToken` and `collateralDecimals`
     * to the Perp vault's settlement token (USDC) and its decimals, respectively.
     *
     * @param _controller               Address of controller contract
     * @param _perpVault                Address of Perp Vault contract
     * @param _perpQuoter               Address of Perp Quoter contract
     * @param _perpMarketRegistry       Address of Perp MarketRegistry contract
     */
    constructor(
        IController _controller,
        IVault _perpVault,
        IQuoter _perpQuoter,
        IMarketRegistry _perpMarketRegistry
    )
        public
        ModuleBase(_controller)
        SetTokenAccessible(_controller)
    {
        // Use temp variables to initialize immutables
        address tempCollateralToken = _perpVault.getSettlementToken();
        collateralToken = IERC20(tempCollateralToken);
        collateralDecimals = ERC20(tempCollateralToken).decimals();

        perpAccountBalance = IAccountBalance(_perpVault.getAccountBalance());
        perpClearingHouse = IClearingHouse(_perpVault.getClearingHouse());
        perpExchange = IExchange(_perpVault.getExchange());
        perpVault = _perpVault;
        perpQuoter = _perpQuoter;
        perpMarketRegistry = _perpMarketRegistry;
    }

    /* ============ External Functions ============ */

    /**
     * @dev MANAGER ONLY: Initializes this module to the SetToken. Either the SetToken needs to be on the
     * allowed list or anySetAllowed needs to be true.
     *
     * @param _setToken             Instance of the SetToken to initialize
     */
    function initialize(
        ISetToken _setToken
    )
        external
        onlySetManager(_setToken, msg.sender)
        onlyValidAndPendingSet(_setToken)
        onlyAllowedSet(_setToken)
    {
        // Initialize module before trying register
        _setToken.initializeModule();

        // Get debt issuance module registered to this module and require that it is initialized
        require(_setToken.isInitializedModule(
            getAndValidateAdapter(DEFAULT_ISSUANCE_MODULE_NAME)),
            "Issuance not initialized"
        );

        // Try if register exists on any of the modules including the debt issuance module
        address[] memory modules = _setToken.getModules();
        for(uint256 i = 0; i < modules.length; i++) {
            try IDebtIssuanceModule(modules[i]).registerToIssuanceModule(_setToken) {
                // This module registered itself on `modules[i]` issuance module.
            } catch {
                // Try will fail if `modules[i]` is not an instance of IDebtIssuanceModule and does not
                // implement the `registerToIssuanceModule` function, or if the `registerToIssuanceModule`
                // function call reverted. Irrespective of the reason for failure, continue to the next module.
            }
        }
    }

    /**
     * @dev MANAGER ONLY: Allows manager to buy or sell perps to change exposure to the underlying baseToken.
     * Providing a positive value for `_baseQuantityUnits` buys vToken on UniswapV3 via Perp's ClearingHouse,
     * Providing a negative value sells the token. `_quoteBoundQuantityUnits` defines a min-receive-like slippage
     * bound for the amount of vUSDC quote asset the trade will either pay or receive as a result of the action.
     *
     * NOTE: This method doesn't update the externalPositionUnit because it is a function of UniswapV3 virtual
     * token market prices and needs to be generated on the fly to be meaningful.
     *
     * As a user when levering, e.g increasing the magnitude of your position, you'd trade as below
     * | ----------------------------------------------------------------------------------------------- |
     * | Type  |  Action | Goal                      | `quoteBoundQuantity`        | `baseQuantityUnits` |
     * | ----- |-------- | ------------------------- | --------------------------- | ------------------- |
     * | Long  | Buy     | pay least amt. of vQuote  | upper bound of input quote  | positive            |
     * | Short | Sell    | get most amt. of vQuote   | lower bound of output quote | negative            |
     * | ----------------------------------------------------------------------------------------------- |
     *
     * As a user when delevering, e.g decreasing the magnitude of your position, you'd trade as below
     * | ----------------------------------------------------------------------------------------------- |
     * | Type  |  Action | Goal                      | `quoteBoundQuantity`        | `baseQuantityUnits` |
     * | ----- |-------- | ------------------------- | --------------------------- | ------------------- |
     * | Long  | Sell    | get most amt. of vQuote   | upper bound of input quote  | negative            |
     * | Short | Buy     | pay least amt. of vQuote  | lower bound of output quote | positive            |
     * | ----------------------------------------------------------------------------------------------- |
     *
     * @param _setToken                     Instance of the SetToken
     * @param _baseToken                    Address virtual token being traded
     * @param _baseQuantityUnits            Quantity of virtual token to trade in position units
     * @param _quoteBoundQuantityUnits      Max/min of vQuote asset to pay/receive when buying or selling
     */
    function trade(
        ISetToken _setToken,
        address _baseToken,
        int256 _baseQuantityUnits,
        uint256 _quoteBoundQuantityUnits
    )
        external
        nonReentrant
        onlyManagerAndValidSet(_setToken)
    {
        ActionInfo memory actionInfo = _createAndValidateActionInfo(
            _setToken,
            _baseToken,
            _baseQuantityUnits,
            _quoteBoundQuantityUnits
        );

        (uint256 deltaBase, uint256 deltaQuote) = _executeTrade(actionInfo);

        uint256 protocolFee = _accrueProtocolFee(_setToken, deltaQuote);

        _updatePositionList(_setToken, _baseToken);

        emit PerpTraded(
            _setToken,
            _baseToken,
            deltaBase,
            deltaQuote,
            protocolFee,
            actionInfo.isBuy
        );
    }

    /**
     * @dev MANAGER ONLY: Deposits default position collateral token into the PerpV2 Vault, increasing
     * the size of the Perp account external position. This method is useful for establishing initial
     * collateralization ratios, e.g the flow when setting up a 2X external position would be to deposit
     * 100 units of USDC and execute a lever trade for ~200 vUSDC worth of vToken with the difference
     * between these made up as automatically "issued" margin debt in the PerpV2 system.
     *
     * @param  _setToken                    Instance of the SetToken
     * @param  _collateralQuantityUnits     Quantity of collateral to deposit in position units
     */
    function deposit(
      ISetToken _setToken,
      uint256 _collateralQuantityUnits
    )
      public
      nonReentrant
      onlyManagerAndValidSet(_setToken)
    {
        require(_collateralQuantityUnits > 0, "Deposit amount is 0");

        uint256 notionalDepositedQuantity = _depositAndUpdatePositions(_setToken, _collateralQuantityUnits);

        emit CollateralDeposited(_setToken, collateralToken, notionalDepositedQuantity);
    }

    /**
     * @dev MANAGER ONLY: Withdraws collateral token from the PerpV2 Vault to a default position on
     * the SetToken. This method is useful when adjusting the overall composition of a Set which has
     * a Perp account external position as one of several components.
     *
     * NOTE: Within PerpV2, `withdraw` settles `owedRealizedPnl` and any pending funding payments
     * to the Perp vault prior to transfer.
     *
     * @param  _setToken                    Instance of the SetToken
     * @param  _collateralQuantityUnits     Quantity of collateral to withdraw in position units
     */
    function withdraw(
      ISetToken _setToken,
      uint256 _collateralQuantityUnits
    )
      public
      nonReentrant
      onlyManagerAndValidSet(_setToken)
    {
        require(_collateralQuantityUnits > 0, "Withdraw amount is 0");

        uint256 notionalWithdrawnQuantity = _withdrawAndUpdatePositions(_setToken, _collateralQuantityUnits);

        emit CollateralWithdrawn(_setToken, collateralToken, notionalWithdrawnQuantity);
    }

    /**
     * @dev MANAGER ONLY: Removes this module from the SetToken, via call by the SetToken. Deletes
     * position mappings associated with SetToken.
     *
     * NOTE: Function will revert if there is greater than a position unit amount of USDC of account value.
     */
    function removeModule() external override onlyValidAndInitializedSet(ISetToken(msg.sender)) {
        ISetToken setToken = ISetToken(msg.sender);

        // Check that there is less than 1 position unit of USDC of account value (to tolerate PRECISE_UNIT math rounding errors).
        // Account value is checked here because liquidation may result in a positive vault balance while net value is below zero.
        int256 accountValueUnit = perpClearingHouse.getAccountValue(address(setToken)).preciseDiv(setToken.totalSupply().toInt256());
        require(
            accountValueUnit.fromPreciseUnitToDecimals(collateralDecimals) <= 1,
            "Account balance exists"
        );

        // `positions[setToken]` mapping stores an array of addresses. The base token addresses are removed from the array when the
        // corresponding base token positions are zeroed out. Since no positions exist when removing the module, the stored array should
        // already be empty, and the mapping can be deleted directly.
        delete positions[setToken]; 

        // Try if unregister exists on any of the modules
        address[] memory modules = setToken.getModules();
        for(uint256 i = 0; i < modules.length; i++) {
            try IDebtIssuanceModule(modules[i]).unregisterFromIssuanceModule(setToken) {} catch {}
        }
    }

    /**
     * @dev MANAGER ONLY: Add registration of this module on the debt issuance module for the SetToken.
     *
     * Note: if the debt issuance module is not added to SetToken before this module is initialized, then
     * this function needs to be called if the debt issuance module is later added and initialized to prevent state
     * inconsistencies
     *
     * @param _setToken             Instance of the SetToken
     * @param _debtIssuanceModule   Debt issuance module address to register
     */
    function registerToModule(ISetToken _setToken, IDebtIssuanceModule _debtIssuanceModule) external onlyManagerAndValidSet(_setToken) {
        require(_setToken.isInitializedModule(address(_debtIssuanceModule)), "Issuance not initialized");

        _debtIssuanceModule.registerToIssuanceModule(_setToken);
    }

    /**
     * @dev MODULE ONLY: Hook called prior to issuance. Only callable by valid module. Should only be called ONCE
     * during issue. Trades into current positions and sets the collateralToken's externalPositionUnit so that
     * issuance module can transfer in the right amount of collateral accounting for accrued fees/pnl and slippage
     * incurred during issuance. Any pending funding payments and accrued owedRealizedPnl are attributed to current
     * Set holders.
     *
     * @param _setToken             Instance of the SetToken
     * @param _setTokenQuantity     Quantity of Set to issue
     */
    function moduleIssueHook(
        ISetToken _setToken,
        uint256 _setTokenQuantity
    )
        external
        override
        onlyModule(_setToken)
    {
        if (_setToken.totalSupply() == 0) return;
        if (!_setToken.hasExternalPosition(address(collateralToken))) return;

        int256 newExternalPositionUnit = _executePositionTrades(_setToken, _setTokenQuantity, true, false);

        // Set collateralToken externalPositionUnit such that DIM can use it for transfer calculation
        _setToken.editExternalPositionUnit(
            address(collateralToken),
            address(this),
            newExternalPositionUnit
        );
    }

    /**
     * @dev MODULE ONLY: Hook called prior to redemption in the issuance module. Trades out of existing
     * positions to make redemption capital withdrawable from PerpV2 vault. Sets the `externalPositionUnit`
     * equal to the realizable value of account in position units (as measured by the trade outcomes for
     * this redemption). Any `owedRealizedPnl` and pending funding payments are socialized in this step so
     * that redeemer pays/receives their share of them. Should only be called ONCE during redeem.
     *
     * @param _setToken             Instance of the SetToken
     * @param _setTokenQuantity     Quantity of SetToken to redeem
     */
    function moduleRedeemHook(
        ISetToken _setToken,
        uint256 _setTokenQuantity
    )
        external
        override
        onlyModule(_setToken)
    {
        if (_setToken.totalSupply() == 0) return;
        if (!_setToken.hasExternalPosition(address(collateralToken))) return;

        int256 newExternalPositionUnit = _executePositionTrades(_setToken, _setTokenQuantity, false, false);

        // Set USDC externalPositionUnit such that DIM can use it for transfer calculation
        _setToken.editExternalPositionUnit(
            address(collateralToken),
            address(this),
            newExternalPositionUnit
        );
    }

    /**
     * @dev MODULE ONLY: Hook called prior to looping through each component on issuance. Deposits
     * collateral into Perp protocol from SetToken default position.
     * @param _setToken             Instance of the SetToken
     * @param _setTokenQuantity     Quantity of SetToken to issue
     * @param _component            Address of deposit collateral component
     * @param _isEquity             True if componentHook called from issuance module for equity flow, false otherwise
     */
    function componentIssueHook(
        ISetToken _setToken,
        uint256 _setTokenQuantity,
        IERC20 _component,
        bool _isEquity
    )
        external
        override
        onlyModule(_setToken)
    {
        if (_isEquity) {
            int256 externalPositionUnit = _setToken.getExternalPositionRealUnit(address(_component), address(this));

            // Use preciseMulCeil here to ensure correct collateralization if there are rounding errors.
            uint256 usdcTransferInNotionalQuantity = _setTokenQuantity.preciseMulCeil(externalPositionUnit.toUint256());

            _deposit(_setToken, usdcTransferInNotionalQuantity);
        }
    }

    /**
     * @dev MODULE ONLY: Hook called prior to looping through each component on redemption. Withdraws
     * collateral from Perp protocol to SetToken default position *without* updating the default position unit.
     * Called by issuance module's `resolveEquityPositions` method which immediately transfers the collateral
     * component from SetToken to redeemer after this hook executes.
     *
     * @param _setToken             Instance of the SetToken
     * @param _setTokenQuantity     Quantity of SetToken to redeem
     * @param _component            Address of deposit collateral component
     * @param _isEquity             True if componentHook called from issuance module for equity flow, false otherwise
     */
    function componentRedeemHook(
        ISetToken _setToken,
        uint256 _setTokenQuantity,
        IERC20 _component,
        bool _isEquity
    )
        external
        override
        onlyModule(_setToken)
    {
        if (_isEquity) {
            int256 externalPositionUnit = _setToken.getExternalPositionRealUnit(address(_component), address(this));
            uint256 usdcTransferOutNotionalQuantity = _setTokenQuantity.preciseMul(externalPositionUnit.toUint256());

            _withdraw(_setToken, usdcTransferOutNotionalQuantity);
        }
    }

    /* ============ External Getter Functions ============ */

    /**
     * @dev Gets the positive equity collateral externalPositionUnit that would be calculated for
     * issuing a quantity of SetToken, representing the amount of collateral that would need to
     * be transferred in per SetToken. Values in the returned arrays map to the same index in the
     * SetToken's components array
     *
     * @param _setToken             Instance of SetToken
     * @param _setTokenQuantity     Number of sets to issue
     *
     * @return equityAdjustments array containing a single element and an empty debtAdjustments array
     */
    function getIssuanceAdjustments(
        ISetToken _setToken,
        uint256 _setTokenQuantity
    )
        external
        override
        returns (int256[] memory, int256[] memory)
    {
        address[] memory components = _setToken.getComponents();

        if (positions[_setToken].length > 0) {
            int256 newExternalPositionUnit = _executePositionTrades(_setToken, _setTokenQuantity, true, true);
            return _formatAdjustments(_setToken, components, newExternalPositionUnit);
        } else {
            return _formatAdjustments(_setToken, components, 0);
        }
    }

    /**
     * @dev Gets the positive equity collateral externalPositionUnit that would be calculated for
     * redeeming a quantity of SetToken representing the amount of collateral returned per SetToken.
     * Values in the returned arrays map to the same index in the SetToken's components array.
     *
     * @param _setToken             Instance of SetToken
     * @param _setTokenQuantity     Number of sets to issue
     *
     * @return equityAdjustments array containing a single element and an empty debtAdjustments array
     */
    function getRedemptionAdjustments(
        ISetToken _setToken,
        uint256 _setTokenQuantity
    )
        external
        override
        returns (int256[] memory, int256[] memory _)
    {
        address[] memory components = _setToken.getComponents();

        if (positions[_setToken].length > 0) {
            int256 newExternalPositionUnit = _executePositionTrades(_setToken, _setTokenQuantity, false, true);
            return _formatAdjustments(_setToken, components, newExternalPositionUnit);
        } else {
            return _formatAdjustments(_setToken, components, 0);
        }
    }

    /**
     * @dev Returns a PositionUnitNotionalInfo array representing all positions open for the SetToken.
     *
     * @param _setToken         Instance of SetToken
     *
     * @return PositionUnitInfo array, in which each element has properties:
     *
     *         + baseToken: address,
     *         + baseBalance:  baseToken balance as notional quantity (10**18)
     *         + quoteBalance: USDC quote asset balance as notional quantity (10**18)
     */
    function getPositionNotionalInfo(ISetToken _setToken) public view returns (PositionNotionalInfo[] memory) {
        address[] memory positionList = positions[_setToken];
        uint256 positionLength = positionList.length;
        PositionNotionalInfo[] memory positionInfo = new PositionNotionalInfo[](positionLength);

        for(uint i = 0; i < positionLength; i++){
            address baseToken = positionList[i];
            positionInfo[i] = PositionNotionalInfo({
                baseToken: baseToken,
                baseBalance: perpAccountBalance.getBase(
                    address(_setToken),
                    baseToken
                ),
                quoteBalance: perpAccountBalance.getQuote(
                    address(_setToken),
                    baseToken
                )
            });
        }

        return positionInfo;
    }

    /**
     * @dev Returns a PositionUnitInfo array representing all positions open for the SetToken.
     *
     * @param _setToken         Instance of SetToken
     *
     * @return PositionUnitInfo array, in which each element has properties:
     *
     *         + baseToken: address,
     *         + baseUnit:  baseToken balance as position unit (10**18)
     *         + quoteUnit: USDC quote asset balance as position unit (10**18)
     */
    function getPositionUnitInfo(ISetToken _setToken) external view returns (PositionUnitInfo[] memory) {
        int256 totalSupply = _setToken.totalSupply().toInt256();
        PositionNotionalInfo[] memory positionNotionalInfo = getPositionNotionalInfo(_setToken);
        uint256 positionLength = positionNotionalInfo.length;
        PositionUnitInfo[] memory positionUnitInfo = new PositionUnitInfo[](positionLength);

        for(uint i = 0; i < positionLength; i++){
            PositionNotionalInfo memory currentPosition = positionNotionalInfo[i];
            positionUnitInfo[i] = PositionUnitInfo({
                baseToken: currentPosition.baseToken,
                baseUnit: currentPosition.baseBalance.preciseDiv(totalSupply),
                quoteUnit: currentPosition.quoteBalance.preciseDiv(totalSupply)
            });
        }

        return positionUnitInfo;
    }


    /**
     * @dev Gets Perp account info for SetToken. Returns an AccountInfo struct containing account wide
     * (rather than position specific) balance info
     *
     * @param  _setToken            Instance of the SetToken
     *
     * @return accountInfo          struct with properties for:
     *
     *         + collateral balance (10**18, regardless of underlying collateral decimals)
     *         + owed realized Pnl` (10**18)
     *         + pending funding payments (10**18)
     *         + net quote balance (10**18)
     */
    function getAccountInfo(ISetToken _setToken) public view returns (AccountInfo memory accountInfo) {
        (int256 owedRealizedPnl,, ) =  perpAccountBalance.getPnlAndPendingFee(address(_setToken));

        // NOTE: pendingFundingPayments are represented as in the Perp system as "funding owed"
        // e.g a positive number is a debt which gets subtracted from owedRealizedPnl on settlement.
        // We are flipping its sign here to reflect its settlement value.
        accountInfo = AccountInfo({
            collateralBalance: _getCollateralBalance(_setToken),
            owedRealizedPnl: owedRealizedPnl,
            pendingFundingPayments: perpExchange.getAllPendingFundingPayment(address(_setToken)).neg(),
            netQuoteBalance: _getNetQuoteBalance(_setToken)
        });
    }

    /* ============ Internal Functions ============ */

    /**
     * @dev MODULE ONLY: Hook called prior to issuance or redemption. Only callable by valid module.
     * This method implements the core logic to replicate positions during issuance and redemption. Syncs
     * the `positions` list before starting (because positions may have liquidated). Cycles through
     * each position, trading `basePositionUnit * issueOrRedeemQuantity` and calculates the amount of
     * USDC to transfer in/out for exchange, ensuring that issuer/redeemer pays slippage and that any
     * pending payments like funding or owedRealizedPnl are socialized among existing Set holders
     * appropriately. The hook which invokes this method sets the SetToken's externalPositionUnit using
     * the positionUnit value returned here. Subsequent transfers in/out are managed by the issuance module
     * which reads this value.
     *
     * The general formula for determining `accountValue` per Set is:
     *
     * `accountValue = collateral                                <---
     *               + owedRealizedPnl                               }   totalCollateralValue
     *               + pendingFundingPayment                     <---
     *               + netQuoteBalance                           neg. when long, pos. when short
     *               +/- sum( |deltaQuoteResultingFromTrade| )   add when long, subtract when short
     *
     * (See docs for `_calculatePartialAccountValuePositionUnit` below for more detail about the
     * account value components).
     *
     * NOTE: On issuance, this hook is run *BEFORE* USDC is transferred in and deposited to the Perp
     * vault to pay for the issuer's Sets. This trading temporarily spikes the Perp account's
     * margin ratio (capped at ~9X) and limits the amount of Set that can issued at once to
     * a multiple of the current Perp account value (will vary depending on Set's leverage ratio).
     *
     * @param _setToken             Instance of the SetToken
     * @param _setTokenQuantity     Quantity of Set to issue
     * @param _isIssue              If true, invocation is for issuance, redemption otherwise
     * @param _isSimulation         If true, trading is only simulated (to return issuance adjustments)
     * @return int256               Amount of collateral to transfer in/out in position units
     */
    function _executePositionTrades(
        ISetToken _setToken,
        uint256 _setTokenQuantity,
        bool _isIssue,
        bool _isSimulation
    )
        internal
        returns (int256)
    {
        _syncPositionList(_setToken);
        int256 setTokenQuantityInt = _setTokenQuantity.toInt256();

        // Note: `issued` naming convention used here for brevity. This logic is also run on redemption
        // and variable may refer to the value which will be redeemed.
        int256 accountValueIssued = _calculatePartialAccountValuePositionUnit(_setToken).preciseMul(setTokenQuantityInt);

        PositionNotionalInfo[] memory positionInfo = getPositionNotionalInfo(_setToken);
        uint256 positionLength = positionInfo.length;
        int256 totalSupply = _setToken.totalSupply().toInt256();

        for(uint i = 0; i < positionLength; i++) {
            int256 baseTradeNotionalQuantity = positionInfo[i].baseBalance.preciseDiv(totalSupply).preciseMul(setTokenQuantityInt);

            // When redeeming, we flip the sign of baseTradeNotionalQuantity because we are reducing the size of the position,
            // e.g selling base when long, buying base when short
            ActionInfo memory actionInfo = _createActionInfoNotional(
                _setToken,
                positionInfo[i].baseToken,
                _isIssue ? baseTradeNotionalQuantity : baseTradeNotionalQuantity.neg(),
                0
            );

            // Execute or simulate trade.
            // `deltaQuote` is always a positive number
            (, uint256 deltaQuote) = _isSimulation ? _simulateTrade(actionInfo) : _executeTrade(actionInfo);

            // slippage is borne by the issuer
            accountValueIssued = baseTradeNotionalQuantity >= 0 ? accountValueIssued.add(deltaQuote.toInt256()) :
                accountValueIssued.sub(deltaQuote.toInt256());
        }

        // After trading, verify that accountValueIssued is not negative. In some post-liquidation states the
        // account could be bankrupt and we represent that as zero.
        if (accountValueIssued <= 0) {
            return 0;
        }

        // Return value in collateral decimals (e.g USDC = 6)
        // Use preciseDivCeil when issuing to ensure we don't under-collateralize due to rounding error
        return (_isIssue)
            ? accountValueIssued.preciseDivCeil(setTokenQuantityInt).fromPreciseUnitToDecimals(collateralDecimals)
            : accountValueIssued.preciseDiv(setTokenQuantityInt).fromPreciseUnitToDecimals(collateralDecimals);
    }

    /**
     * Calculates the "partial account value" position unit. This is the sum of the vault collateral balance,
     * the net quote balance for all positions, and any pending funding or owed realized Pnl balances,
     * as a position unit. It forms the base to which traded position values are added during issuance or redemption,
     * and to which existing position values are added when calculating the externalPositionUnit.
     *
     * @param _setToken             Instance of the SetToken
     * @return accountValue         Partial account value in position units
     */
    function _calculatePartialAccountValuePositionUnit(ISetToken _setToken) internal view returns (int256 accountValue) {
        AccountInfo memory accountInfo = getAccountInfo(_setToken);

        accountValue = accountInfo.collateralBalance
            .add(accountInfo.owedRealizedPnl)
            .add(accountInfo.pendingFundingPayments)
            .add(accountInfo.netQuoteBalance)
            .preciseDiv(_setToken.totalSupply().toInt256());
    }

    /**
     * @dev Invoke deposit from SetToken using PerpV2 library. Creates a collateral deposit in Perp vault
     * Updates the collateral token default position unit. This function is called directly by
     * the componentIssue hook, skipping external position unit setting because that method is assumed
     * to be the end of a call sequence (e.g manager will not need to read the updated value)
     *
     * @param _setToken                     Instance of SetToken
     * @param _collateralNotionalQuantity   Notional collateral quantity to deposit
     */
    function _deposit(ISetToken _setToken, uint256 _collateralNotionalQuantity) internal {
        _setToken.invokeApprove(
            address(collateralToken),
            address(perpVault),
            _collateralNotionalQuantity
        );

        _setToken.invokeDeposit(perpVault, collateralToken, _collateralNotionalQuantity);
    }

    /**
     * Approves and deposits collateral units into Perp vault and additionally sets collateral token externalPositionUnit
     * so Manager contracts have a value they can base calculations for further trading on within the same transaction.
     *
     * NOTE: This flow is only used when invoking the external `deposit` function - it converts collateral
     * quantity units into a notional quantity.
     *
     * @param _setToken                     Instance of SetToken
     * @param _collateralQuantityUnits      Collateral quantity in position units to deposit
     * @return uint256                      Notional quantity deposited
     */
    function _depositAndUpdatePositions(
        ISetToken _setToken,
        uint256 _collateralQuantityUnits
    )
        internal
        returns (uint256)
    {
        uint256 initialCollateralPositionBalance = collateralToken.balanceOf(address(_setToken));
        uint256 collateralNotionalQuantity = _collateralQuantityUnits.preciseMul(_setToken.totalSupply());

        _deposit(_setToken, collateralNotionalQuantity);

        _setToken.calculateAndEditDefaultPosition(
            address(collateralToken),
            _setToken.totalSupply(),
            initialCollateralPositionBalance
        );

        _setToken.editExternalPosition(
            address(collateralToken),
            address(this),
            _calculateExternalPositionUnit(_setToken),
            ""
        );

        return collateralNotionalQuantity;
    }

    /**
     * @dev Invoke withdraw from SetToken using PerpV2 library. Withdraws collateral token from Perp vault
     * into a default position. This function is called directly by _accrueFee and _moduleRedeemHook,
     * skipping position unit state updates because the funds withdrawn to SetToken are immediately
     * forwarded to `feeRecipient` and SetToken owner respectively.
     *
     * @param _setToken                     Instance of SetToken
     * @param _collateralNotionalQuantity   Notional collateral quantity to withdraw
     */
    function _withdraw(ISetToken _setToken, uint256 _collateralNotionalQuantity) internal {
        if (_collateralNotionalQuantity == 0) return;

        _setToken.invokeWithdraw(perpVault, collateralToken, _collateralNotionalQuantity);
    }

    /**
     * Withdraws collateral units from Perp vault to SetToken and additionally sets both the collateralToken
     * externalPositionUnit (so Manager contracts have a value they can base calculations for further
     * trading on within the same transaction), and the collateral token default position unit.
     *
     * NOTE: This flow is only used when invoking the external `withdraw` function - it converts
     * a collateral units quantity into a notional quantity before invoking withdraw.
     *
     * @param _setToken                     Instance of SetToken
     * @param _collateralQuantityUnits      Collateral quantity in position units to withdraw
     * @return uint256                      Notional quantity withdrawn
     */
    function _withdrawAndUpdatePositions(
        ISetToken _setToken,
        uint256 _collateralQuantityUnits

    )
        internal
        returns (uint256)
    {
        uint256 initialCollateralPositionBalance = collateralToken.balanceOf(address(_setToken));
        uint256 collateralNotionalQuantity = _collateralQuantityUnits.preciseMul(_setToken.totalSupply());

        _withdraw(_setToken, collateralNotionalQuantity);

        _setToken.calculateAndEditDefaultPosition(
            address(collateralToken),
            _setToken.totalSupply(),
            initialCollateralPositionBalance
        );

        _setToken.editExternalPosition(
            address(collateralToken),
            address(this),
            _calculateExternalPositionUnit(_setToken),
            ""
        );

        return collateralNotionalQuantity;
    }

    /**
     * @dev Formats Perp Protocol openPosition call and executes via SetToken (and PerpV2 lib)
     *
     * `isBaseToQuote`, `isExactInput` and `oppositeAmountBound` are configured as below:
     * | ---------------------------------------------------|---------------------------- |
     * | Action  | isBuy   | isB2Q  | Exact In / Out        | Opposite Bound Description  |
     * | ------- |-------- |--------|-----------------------|---------------------------- |
     * | Buy     |  true   | false  | exact output (false)  | Max quote to pay            |
     * | Sell    |  false  | true   | exact input (true)    | Min quote to receive        |
     * |----------------------------------------------------|---------------------------- |
     *
     * @param _actionInfo  ActionInfo object
     * @return uint256     The base position delta resulting from the trade
     * @return uint256     The quote asset position delta resulting from the trade
     */
    function _executeTrade(ActionInfo memory _actionInfo) internal returns (uint256, uint256) {

        // When isBaseToQuote is true, `baseToken` is being sold, when false, bought
        // When isExactInput is true, `amount` is the swap input, when false, the swap output
        IClearingHouse.OpenPositionParams memory params = IClearingHouse.OpenPositionParams({
            baseToken: _actionInfo.baseToken,
            isBaseToQuote: !_actionInfo.isBuy,
            isExactInput: !_actionInfo.isBuy,
            amount: _actionInfo.baseTokenAmount,
            oppositeAmountBound: _actionInfo.oppositeAmountBound,
            deadline: PreciseUnitMath.maxUint256(),
            sqrtPriceLimitX96: 0,
            referralCode: bytes32(0)
        });

        return _actionInfo.setToken.invokeOpenPosition(perpClearingHouse, params);
    }


    /**
     * @dev Formats Perp Periphery Quoter.swap call and executes via SetToken (and PerpV2 lib)
     *
     * See _executeTrade method comments for details about `isBaseToQuote` and `isExactInput` configuration.
     *
     * @param _actionInfo   ActionInfo object
     * @return uint256      The base position delta resulting from the trade
     * @return uint256      The quote asset position delta resulting from the trade
     */
    function _simulateTrade(ActionInfo memory _actionInfo) internal returns (uint256, uint256) {
        IQuoter.SwapParams memory params = IQuoter.SwapParams({
            baseToken: _actionInfo.baseToken,
            isBaseToQuote: !_actionInfo.isBuy,
            isExactInput: !_actionInfo.isBuy,
            amount: _actionInfo.baseTokenAmount,
            sqrtPriceLimitX96: 0
        });

        IQuoter.SwapResponse memory swapResponse = _actionInfo.setToken.invokeSwap(perpQuoter, params);
        return (swapResponse.deltaAvailableBase, swapResponse.deltaAvailableQuote);
    }

    /**
     * @dev Calculates protocol fee on module and pays protocol fee from SetToken
     *
     * @param  _setToken            Instance of SetToken
     * @param  _exchangedQuantity   Notional quantity of USDC exchanged in trade (e.g deltaQuote)
     * @return uint256              Total protocol fee paid in underlying collateral decimals e.g (USDC = 6)
     */
    function _accrueProtocolFee(
        ISetToken _setToken,
        uint256 _exchangedQuantity
    )
        internal
        returns(uint256)
    {
        uint256 protocolFee = getModuleFee(PROTOCOL_TRADE_FEE_INDEX, _exchangedQuantity);
        uint256 protocolFeeInPreciseUnits = protocolFee.fromPreciseUnitToDecimals(collateralDecimals);

        _withdraw(_setToken, protocolFeeInPreciseUnits);

        payProtocolFeeFromSetToken(_setToken, address(collateralToken), protocolFeeInPreciseUnits);

        return protocolFeeInPreciseUnits;
    }

    /**
     * @dev Construct the ActionInfo struct for trading. This method takes POSITION UNIT amounts and passes to
     *  _createActionInfoNotional to create the struct. If the _baseTokenQuantity is zero then revert. This
     *  method is only called from `trade` - the issue/redeem flow uses createActionInfoNotional directly.
     *
     * @param _setToken             Instance of the SetToken
     * @param _baseToken            Address of base token being traded into/out of
     * @param _baseTokenUnits       Quantity of baseToken to trade in PositionUnits
     * @param _quoteReceiveUnits    Quantity of quote to receive if selling base and pay if buying, in PositionUnits
     *
     * @return ActionInfo           Instance of constructed ActionInfo struct
     */
    function _createAndValidateActionInfo(
        ISetToken _setToken,
        address _baseToken,
        int256 _baseTokenUnits,
        uint256 _quoteReceiveUnits
    )
        internal
        view
        returns(ActionInfo memory)
    {
        require(_baseTokenUnits != 0, "Amount is 0");
        require(perpMarketRegistry.hasPool(_baseToken), "Base token does not exist");

        uint256 totalSupply = _setToken.totalSupply();

        return _createActionInfoNotional(
            _setToken,
            _baseToken,
            _baseTokenUnits.preciseMul(totalSupply.toInt256()),
            _quoteReceiveUnits.preciseMul(totalSupply)
        );
    }

    /**
     * @dev Construct the ActionInfo struct for trading. This method takes NOTIONAL token amounts and creates
     * the struct. If the _baseTokenQuantity is greater than zero then we are buying the baseToken. This method
     * is called during issue and redeem via `_executePositionTrades` and during trade via `_createAndValidateActionInfo`.
     *
     * (See _executeTrade method comments for details about `oppositeAmountBound` configuration)
     *
     * @param _setToken                 Instance of the SetToken
     * @param _baseToken                Address of base token being traded into/out of
     * @param _baseTokenQuantity        Notional quantity of baseToken to trade
     * @param _quoteReceiveQuantity     Notional quantity of quote to receive if selling base and pay if buying
     *
     * @return ActionInfo               Instance of constructed ActionInfo struct
     */
    function _createActionInfoNotional(
        ISetToken _setToken,
        address _baseToken,
        int256 _baseTokenQuantity,
        uint256 _quoteReceiveQuantity
    )
        internal
        pure
        returns(ActionInfo memory)
    {
        // NOT checking that _baseTokenQuantity != 0 here because for places this is directly called
        // (issue/redeem hooks) we know the position cannot be 0. We check in _createAndValidateActionInfo
        // that quantity is 0 for inputs to trade.
        bool isBuy = _baseTokenQuantity > 0;

        return ActionInfo({
            setToken: _setToken,
            baseToken: _baseToken,
            isBuy: isBuy,
            baseTokenAmount: _baseTokenQuantity.abs(),
            oppositeAmountBound: _quoteReceiveQuantity
        });
    }

    /**
     * @dev Update position address array if a token has been newly added or completely sold off
     * during lever/delever
     *
     * @param _setToken     Instance of SetToken
     * @param _baseToken    Address of virtual base token
     */
    function _updatePositionList(ISetToken _setToken, address _baseToken) internal {
        address[] memory positionList = positions[_setToken];
        bool hasBaseToken = positionList.contains(_baseToken);

        if (hasBaseToken) {
            if(!_hasBaseBalance(_setToken, _baseToken)) {
                positions[_setToken].removeStorage(_baseToken);
            }
        } else {
            positions[_setToken].push(_baseToken);
        }
    }

    /**
     * @dev Removes any zero balance positions from the positions array. This
     * sync is done before issuance and redemption to account for positions that may have
     * been liquidated.
     *
     * @param _setToken         Instance of the SetToken
     */
    function _syncPositionList(ISetToken _setToken) internal {
        address[] memory positionList = positions[_setToken];
        uint256 positionLength = positionList.length;
        
        for (uint256 i = 0; i < positionLength; i++) {
            address currPosition = positionList[i];
            if (!_hasBaseBalance(_setToken, currPosition)) {
                positions[_setToken].removeStorage(currPosition);
            }
        }
    }

    /**
     * @dev Checks to see if we can make 1 positionUnit worth of a baseToken position, if not we consider the Set to have
     * no balance and return false
     *
     * @param _setToken     Instance of SetToken
     * @param _baseToken    Address of virtual base token
     * @return bool         True if a non-dust base token balance exists, false otherwise
     */
    function _hasBaseBalance(ISetToken _setToken, address _baseToken) internal view returns(bool) {
        int256 baseBalanceUnit = perpAccountBalance
            .getBase(address(_setToken), _baseToken)
            .preciseDiv(_setToken.totalSupply().toInt256());

        return (baseBalanceUnit > 1) || (baseBalanceUnit < -1);
    }

    /**
     * @dev Gets the mid-point price of a virtual asset from UniswapV3 markets maintained by Perp Protocol
     *
     * @param  _baseToken           Address of virtual token to price
     * @return price                Mid-point price of virtual token in UniswapV3 AMM market
     */
    function _calculateAMMSpotPrice(address _baseToken) internal view returns (uint256 price) {
        address pool = perpMarketRegistry.getPool(_baseToken);
        (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(pool).slot0();
        uint256 priceX96 = sqrtPriceX96.formatSqrtPriceX96ToPriceX96();
        return priceX96.formatX96ToX10_18();
    }

    /**
     * @dev Calculates the sum of collateralToken denominated market-prices of assets and debt for the Perp account per
     * SetToken
     *
     * @param _setToken     Instance of SetToken
     * @return int256       External position unit
     */
    function _calculateExternalPositionUnit(ISetToken _setToken) internal view returns (int256) {
        PositionNotionalInfo[] memory positionInfo = getPositionNotionalInfo(_setToken);
        uint256 positionLength = positionInfo.length;
        int256 totalPositionValue = 0;

        for (uint i = 0; i < positionLength; i++ ) {
            int256 spotPrice = _calculateAMMSpotPrice(positionInfo[i].baseToken).toInt256();
            totalPositionValue = totalPositionValue.add(
                positionInfo[i].baseBalance.preciseMul(spotPrice)
            );
        }

        int256 externalPositionUnitInPreciseUnits = _calculatePartialAccountValuePositionUnit(_setToken)
            .add(totalPositionValue.preciseDiv(_setToken.totalSupply().toInt256()));

        return externalPositionUnitInPreciseUnits.fromPreciseUnitToDecimals(collateralDecimals);
    }

    /**
     * @dev Retrieves collateral balance as an 18 decimal vUSDC quote value
     *
     * @param _setToken     Instance of SetToken
     * @return int256       Collateral balance as an 18 decimal vUSDC quote value
     */
    function _getCollateralBalance(ISetToken _setToken) internal view returns (int256) {
        return perpVault.getBalance(address(_setToken)).toPreciseUnitsFromDecimals(collateralDecimals);
    }

    /**
     * @dev Retrieves net quote balance of all open positions
     *
     * @param _setToken             Instance of SetToken
     * @return netQuoteBalance      Net quote balance of all open positions
     */
    function _getNetQuoteBalance(ISetToken _setToken) internal view returns (int256 netQuoteBalance) {
        address[] memory positionList = positions[_setToken];
        uint256 positionLength = positionList.length;

        for (uint256 i = 0; i < positionLength; i++) {
            netQuoteBalance = netQuoteBalance.add(
                perpAccountBalance.getQuote(address(_setToken), positionList[i])
            );
        }
    }

    /**
     * @dev Returns issuance or redemption adjustments in the format expected by `SlippageIssuanceModule`.
     * The last recorded externalPositionUnit (current) is subtracted from a dynamically generated
     * externalPositionUnit (new) and set in an `equityAdjustments` array which is the same length as
     * the SetToken's components array, at the same index the collateral token occupies in the components
     * array. All other values are left unset (0). An empty-value components length debtAdjustments
     * array is also returned.
     *
     * @param _setToken                         Instance of the SetToken
     * @param _components                       Array of components held by the SetToken
     * @param _newExternalPositionUnit          Dynamically calculated externalPositionUnit
     * @return int256[]                         Components-length array with equity adjustment value at appropriate index
     * @return int256[]                         Components-length array of zeroes (debt adjustements)
     */
    function _formatAdjustments(
        ISetToken _setToken,
        address[] memory _components,
        int256 _newExternalPositionUnit
    )
        internal
        view
        returns (int256[] memory, int256[] memory)
    {
        int256[] memory equityAdjustments = new int256[](_components.length);
        int256[] memory debtAdjustments = new int256[](_components.length);

        (uint256 index, bool isIn) = _components.indexOf(address(collateralToken));

        if (isIn) {
            int256 currentExternalPositionUnit = _setToken.getExternalPositionRealUnit(
                address(collateralToken),
                address(this)
            );

            equityAdjustments[index] = _newExternalPositionUnit.sub(currentExternalPositionUnit);
        }

        return (equityAdjustments, debtAdjustments);
    }
}
