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

//************** */
// Erros         //
//************** */
error DSCEngine__NeedsMoreThanZero();
error DSCEngine__TokenAddressesAndPriceFeedsMustBeSameLength();
error DSCEngine__TokenNotAllowed();
error DSCEngine__TransferFailed();

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
    //********************* */
    // State Variables      //
    //********************* */
    mapping(address token => address priceFeed) private s_priceFeeds; // tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited; // userToTokenToAmount
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dcs;

    //********************* */
    // Events              //
    //********************* */
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);

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
        i_dcs = DecentralizedStableCoin(dscAddress);
    }

    //************************* */
    // External Functions      //
    //************************ */
    function depositCollateralAndMintDsc() external {}

    /**
     *
     * @param _tokenCollateralAddress The address of the token to deposit as collateral
     * @param _amountCollateral the amount of collateral to deposit
     */
    function depositCollateral(address _tokenCollateralAddress, uint256 _amountCollateral)
        external
        moreThanZero(_amountCollateral)
        isAllowedToken(_tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][_tokenCollateralAddress] += _amountCollateral;
        emit CollateralDeposited(msg.sender, _tokenCollateralAddress, _amountCollateral);
        bool success = IERC20(_tokenCollateralAddress).transferFrom(msg.sender, address(this), _amountCollateral);
        if (!success) revert DSCEngine__TransferFailed();
    }

    function redeemCollateralForDsc() external {}

    function redeemCollateral() external {}

    /**
     * @notice follows CEI
     * @param amountDscToMint The amount od DSC Stablecoin to mint
     * @notice They must have more collateral value than the minimum threshold
     */
    function mintDsc(uint256 amountDscToMint) external moreThanZero(amountDscToMint) nonReentrant {
        // 1. check if user collateral value > DSC amount
        s_DSCMinted[msg.sender] += amountDscToMint;
        // if they minted too much ($150 DSC, $100 ETH)
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function burnDsc() external {}

    // threshold to let's say 150%
    // $100 ETH -> $40 ETH (if it hits $40, it will get liquidate)
    // $50 DSC

    // if someone pays back your minted DSC, they can have all your collateral for a discount
    function liquidate() external {}

    function getHealthFactor() external view returns (uint256) {}

    function getCollateralValue() external view returns (uint256) {}

    function getDscValue() external view returns (uint256) {}

    //***************************************** */
    // Private and Internal View Functions      //
    //***************************************** */

    function _getAccountInformation(address _user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[_user];
        collateralValueInUsd = getAccountCollateralValue(_user);
    }

    /**
     * Returns how close to liquidation a user is
     * if a user goes below 1, they can get liquidated
     */
    function _healthFactor(address _user) private view returns (uint256) {
        // total DSC minted
        // total collateral Value
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(_user);
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        // 1. check health factor (do they have enough collateral to back their DSC)
        // 2. Revert if they don't
    }

    //***************************************** */
    // Public and External View Functions      //
    //***************************************** */
    function getAccountCollateralValue(address _user) public view returns (uint256) {
        // loop through each collateral token, get the amount they have deposited, and map it to the price, to get the USD value
        for (uint256 i = 0; i < s_collateralDeposited.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[_user][token];
            // uint256 price = i_priceFeed.getPrice(token);
            // uint256 value = amount * price;
            // totalValue += value;
        }
        // return totalValue;
    }

    function getUsdValue(address _token, uint256 _amount) public view returns (uint256) {}
}
