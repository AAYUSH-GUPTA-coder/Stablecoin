// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// internal & private view & pure functions
// external & public view & pure functions

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author Aayush Gupta
 *
 * This system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg.
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algorithmically stable
 *
 * It is similar to DAI if DAI had no governance, no fees and was only backed by wETH and wBTC.
 *
 * Our DSC System should always be "OVERCOLLATERALIZED". At no point, should the value of all collateral <= the $ backed value of all the DSC.
 *
 * @notice This contract is core of DSC system. it handles all the logic for mining and redeeming DSC, as well as depositing & withdrawing collateral.
 * @notice This contract is very loosely based on the MakerDAO DSS (DAI) system
 */
contract DSCEngine is ReentrancyGuard {
    //************** */
    // Erros         //
    //************** */
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedsMustBeSameLength();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreakHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOK();
    error DSCEngine__HealthFactorNotImproved();

    //********************* */
    // State Variables      //
    //********************* */
    mapping(address token => address priceFeed) private s_priceFeeds; // tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited; // userToTokenToAmount
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% over collaterised
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // this means a 10% bonus

    //********************* */
    // Events              //
    //********************* */
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralRedeemed(
        address indexed redeemedFrom,
        address indexed redeemedTo,
        address indexed tokenCollateralAddress,
        uint256 amountCollateral
    );

    //************** */
    // Modifier      //
    //************** */
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) revert DSCEngine__NeedsMoreThanZero();
        _;
    }

    modifier isAllowedToken(address tokenAddress) {
        if (s_priceFeeds[tokenAddress] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    //************** */
    // Functions     //
    //************** */
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        // usd price feed
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedsMustBeSameLength();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    //************************* */
    // External Functions      //
    //************************ */

    /**
     * @notice This function will deposit your collateral and mint DSC in one transcation
     * @param _tokenCollateralAddress The address of the token to deposit as collateral
     * @param _amountCollateral The amount of token to deposit as collateral
     * @param _amountDscToMint The amount of DSC Token, user wants to mint
     */
    function depositCollateralAndMintDsc(
        address _tokenCollateralAddress,
        uint256 _amountCollateral,
        uint256 _amountDscToMint
    ) external {
        depositCollateral(_tokenCollateralAddress, _amountCollateral);
        mintDsc(_amountDscToMint);
    }

    /**
     * @notice function to burn the DSC token and redeem the collateral
     * @param _tokenCollateralAddress address of collateral token
     * @param _amountCollateral amount of collateral token
     * @param _amountDscToBurn amount of DSC token to burn
     */
    function redeemCollateralForDsc(
        address _tokenCollateralAddress,
        uint256 _amountCollateral,
        uint256 _amountDscToBurn
    ) external moreThanZero(_amountCollateral) isAllowedToken(_tokenCollateralAddress) {
        _burnDsc(_amountDscToBurn, msg.sender, msg.sender);
        _redeemCollateral(msg.sender, msg.sender, _tokenCollateralAddress, _amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    //************************* */
    // Public Functions        //
    //************************ */

    /**
     *
     * @param _tokenCollateralAddress The address of the token to deposit as collateral
     * @param _amountCollateral the amount of collateral to deposit
     */
    function depositCollateral(address _tokenCollateralAddress, uint256 _amountCollateral)
        public
        moreThanZero(_amountCollateral)
        isAllowedToken(_tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][_tokenCollateralAddress] += _amountCollateral;
        emit CollateralDeposited(msg.sender, _tokenCollateralAddress, _amountCollateral);
        bool success = IERC20(_tokenCollateralAddress).transferFrom(msg.sender, address(this), _amountCollateral);
        if (!success) revert DSCEngine__TransferFailed();
    }

    // in order to to redeem collateral
    // 1. health factor must be over 1, after Collateral Pulled
    function redeemCollateral(address _tokenCollateralAddress, uint256 _amountCollateral)
        public
        moreThanZero(_amountCollateral)
        isAllowedToken(_tokenCollateralAddress)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, _tokenCollateralAddress, _amountCollateral);
        // $100 of ETH Deposited ---> $20 DSC minted
        // 100 (break)
        // 1. burn DSC
        // 2. redeem ETH

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * function to mint DSC token
     * @param _amountDscToMint amount of DSC token to mint
     */
    function mintDsc(uint256 _amountDscToMint) public moreThanZero(_amountDscToMint) nonReentrant {
        // 1. check if user collateral value > DSC amount
        s_DSCMinted[msg.sender] += _amountDscToMint;
        // if they minted too much ($150 DSC, $100 ETH)
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, _amountDscToMint);
        if (!minted) revert DSCEngine__MintFailed();
    }

    /**
     * @notice function to burn DSC token
     * @param _amount amount of DSC token to burn
     */
    function burnDsc(uint256 _amount) public moreThanZero(_amount) nonReentrant {
        _burnDsc(_amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // I don't think this would ever be needed
    }

    // threshold to let's say 150%
    // $100 ETH -> $40 ETH (if it hits $40, it will get liquidate)
    // $50 DSC

    // if someone pays back your minted DSC, they can have all your collateral for a discount
    // if we do start nearing undercollateralization, we need someone to liquidate position

    // $100 ETH backing $50 DSC
    // if value Tank and $100 worth of ETH, now become $20. we need someone to liquidate the position
    // $20  ETH backing $50 DSC <-- DSC isn't worth $1!!!

    // $75 backing $50 DSC, which is lower than our threshold, so we allow liquidators to liquidate our position
    // liquidator take $75 backing and pays off the $50 DSC

    // if someone is almost undercollateralized, we will pay you to liquidate them!

    /**
     * @notice You can partially liquidate the user
     * @notice You will get the liquidation bonus for taking the users funds
     * @notice This function working assumes the protocol will be roughly 200% overcollateralized in order for this to work
     *
     * @notice A known bug would be if the protocol were 100% or less collateralized, then we wouldn't be able to incentive the liquidators.
     * For example, if the price of the collateral plummed before anyone could be liquidated.
     *
     *
     * @param _collateral address of the collateral asset to liquidate
     * @param _user address of the user, who is undercollaterized
     * @param _debtToCover the amount of DSC you want to burn to improve the user's health factor
     */
    function liquidate(address _collateral, address _user, uint256 _debtToCover)
        external
        isAllowedToken(_collateral)
        moreThanZero(_debtToCover)
        nonReentrant
    {
        // check the user health factor
        uint256 startingUserHealthFactor = _healthFactor(_user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOK();
        }
        // We want to burn the DSC "debt"
        // and send the collateral to the liquidator
        // Bad user example, $140 ETH, $100 DSC
        // debtToCover = $100
        // $100 of DSC == ??? ETH

        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(_collateral, _debtToCover);

        // And give them a 10% bonus for taking the risk
        // so we are giving the liquidator $110 of WETH for 100 DSC
        // We should implement a feature to liquidate in the event the protocol is insolvent (Future TODO)
        // and sweep extra amounts into a treasury

        // (0.5 ETH * 10) / 100
        // 5 / 100 = 0.05 ETH
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(_user, msg.sender, _collateral, totalCollateralToRedeem);
        // burn DSC
        _burnDsc(_debtToCover, _user, msg.sender);

        // check that health factor of the user has improved
        uint256 endingUserHealthFactor = _healthFactor(_user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }

        // check that health factor of the liquidator remain above MINIMUM_HEALTH_FACTOR after liquidating the user
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    //***************************************** */
    // Private and Internal View Functions      //
    //***************************************** */

    /**
     * @dev low-level internal function, do not call unless the function calling it, is checking for health factor
     * @param _amountDscToBurn amount to burn
     * @param _onBehalfOf address of the user, whose debt is getting squared off
     * @param _dscFrom address of the liquidator, whose DSC is being burned and who is squarring off the debt of the user / _onBehalfOf address
     */
    function _burnDsc(uint256 _amountDscToBurn, address _onBehalfOf, address _dscFrom) private {
        s_DSCMinted[_onBehalfOf] -= _amountDscToBurn;
        bool success = i_dsc.transferFrom(_dscFrom, address(this), _amountDscToBurn);
        if (!success) revert DSCEngine__TransferFailed();
        i_dsc.burn(_amountDscToBurn);
    }

    /**
     * function to get TotalDSCToken minted and Collateral Deposied in USD by the user
     * @param _user address of the user
     * @return totalDscMinted returns Total amount DSC minted by the user
     * @return collateralValueInUsd returns the total Amount of Collateral deposited by the user
     */
    function _getAccountInformation(address _user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[_user];
        collateralValueInUsd = getAccountCollateralValueInUsd(_user);
    }

    function _calculateHealthFactor(uint256 _totalDscMinted, uint256 _collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (_totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (_collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / _totalDscMinted;
    }

    /**
     * Returns how close to liquidation a user is
     * if a user goes below 1, they can get liquidated
     */
    function _healthFactor(address _user) private view returns (uint256 healthFactor) {
        // // total DSC minted
        // // total collateral Value
        // (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(_user);

        // // (1000 * 50) / 100
        // // 50,000 / 100 = 500
        // uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        // // (500 * 1e18) / 100 * 1e18 = 5 > 1
        // //! testing
        // // if (totalDscMinted == 0) return (collateralAdjustedForThreshold * PRECISION) / 1e18;
        // // return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
        // if (totalDscMinted == 0) {
        //     healthFactor = (collateralAdjustedForThreshold * PRECISION) / 1e18;
        // } else {
        //     healthFactor = (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
        // }

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(_user);
        // if (totalDscMinted == 0) return type(uint256).max;

        // // (1000 * 50) / 100
        // // 50,000 / 100 = 500
        // uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        // return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        // 1. check health factor (do they have enough collateral to back their DSC)
        // 2. Revert if they don't
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) revert DSCEngine__BreakHealthFactor(userHealthFactor);
    }

    function _redeemCollateral(address _from, address _to, address _tokenCollateralAddress, uint256 _amountCollateral)
        private
    {
        s_collateralDeposited[_from][_tokenCollateralAddress] -= _amountCollateral;
        emit CollateralRedeemed(_from, _to, _tokenCollateralAddress, _amountCollateral);

        // _calculateHealthFactorAfter(), This is gas inefficient
        bool success = IERC20(_tokenCollateralAddress).transfer(_to, _amountCollateral);
        if (!success) revert DSCEngine__TransferFailed();
    }

    //***************************************** */
    // Public and External View Functions      //
    //***************************************** */
    function getAccountCollateralValueInUsd(address _user) public view returns (uint256 totalCollateralValueInUsd) {
        // loop through each collateral token, get the amount they have deposited, and map it to the price, to get the USD value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[_user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
    }

    function getUsdValue(address _token, uint256 _amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[_token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // 1 ETH = $1000
        // The returned value from chainlink will be 1000 * 1e8, while we need it in 1000 * 1e18
        // (1000 * 1e8 * 1e10 * 1) / 1e18 = 1000 * 1 = 1000
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * _amount) / PRECISION;
    }

    function getTokenAmountFromUsd(address _token, uint256 _usdAmountInWei) public view returns (uint256) {
        // price of ETH (token)
        // $ / ETH ETH ??
        // $2000 / ETH, $1000 = 0.5 ETH

        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[_token]);
        (, int256 price,,,) = priceFeed.latestRoundData();

        // ($1000e18 * 1e18) / ($2000e8 * 1e10) = 0.5e18
        return (_usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    /**
     * function to get TotalDSCToken minted and Collateral Deposied in USD by the user
     * @param _user address of the user
     * @return totalDscMinted returns Total amount DSC minted by the user
     * @return collateralValueInUsd returns the total Amount of Collateral deposited by the user
     */
    function getAccountInformation(address _user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(_user);
    }

    function getUserHealthFactor(address _user) external view returns (uint256 healthFactor) {
        healthFactor = _healthFactor(_user);
    }

    /**
     * function to get the Collateral Token amount deposited by the user
     * @param _collateralToken address of the collateral Token
     * @param _user address of the user
     */
    function getCollateralTokenAmount(address _collateralToken, address _user) external view returns (uint256) {
        return s_collateralDeposited[_user][_collateralToken];
    }

    function getDSCMinted(address _user) external view returns (uint256 balance) {
        balance = s_DSCMinted[_user];
    }

    function calculateHealthFactor(uint256 _totalDscMinted, uint256 _collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(_totalDscMinted, _collateralValueInUsd);
    }
}
