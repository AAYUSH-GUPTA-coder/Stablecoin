// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import { MockFailedMintDSC } from "../mocks/MockFailedMintDSC.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethUsdPriceFeed;
    address weth;
    address btcUsdPriceFeed;
    uint256 amountToMint = 100 ether; // 100 DSC
    uint256 amountCollateral = 10 ether;
    uint256 amountCollateralRedeem = 2 ether;

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    address public USER = makeAddr("user");
    address public LIQUIDATER = makeAddr("LIQUIDATER");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant LIQUIDATER_BALANCE = 100 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth,,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(weth).mint(LIQUIDATER, LIQUIDATER_BALANCE);
    }

    ///////////////////////////////
    // Modifier for Test        //
    //////////////////////////////

    modifier approveCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    modifier depositedCollateralAndMint() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint); // 10 ETH, 100 DSC
        vm.stopPrank();
        _;
    }

    modifier depositCollateralAndRedeem() {
        vm.startPrank(USER);
        // approve
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        // collateral and mint
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint); // 10 ETH, 100 DSC
        // Reedeem
        dsce.redeemCollateral(weth, amountCollateralRedeem);
        vm.stopPrank();
        _;
    }

    /////////////////////////////
    // Constructor Test        //
    /////////////////////////////
    function testRevertsIfTokenLengthDoesntMatchPriceFeedsLendth() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedsMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    /////////////////////////
    // Price Test        //
    ////////////////////////

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        // 15e18 * 2000/ETH = 30e18;

        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        // $2000 / ETH, $100 / 2000 = 0.05 ether
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    ///////////////////////////////////
    // DepositCollateral Tests      //
    //////////////////////////////////
    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertWithUnapprovedCollateral() public {
        ERC20Mock testToken = new ERC20Mock("TestToken", "TT", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector);
        dsce.depositCollateral(address(testToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertWithNeedsMoreThanZero() public approveCollateral {
        vm.startPrank(USER);
        // ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testCanDepositCollateralAndCheckCollateralDepositedEvent() public approveCollateral {
        vm.startPrank(USER);
        // ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        vm.expectEmit(true, true, true, true);
        emit DSCEngine.CollateralDeposited(USER, weth, AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, 0);
        uint256 expectedAmountCollateralInUsd = dsce.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValueInUsd, expectedAmountCollateralInUsd);
    }

    ///////////////////////////////////
    // mintDsc Tests                //
    //////////////////////////////////

    function testCanMintDsc() public depositedCollateral {
        vm.prank(USER);
        dsce.mintDsc(amountToMint);

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, amountToMint);
    }

    function testChecks_DSCMinted() public depositedCollateral {
        vm.prank(USER);
        dsce.mintDsc(amountToMint);

        uint256 userBalance = dsce.getDSCMinted(USER);
        assertEq(userBalance, amountToMint);
        vm.stopPrank();
    }

    function testRevertBreakHealthFactor() public {
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreakHealthFactor.selector, 0));
        dsce.mintDsc(amountToMint);
        vm.stopPrank();
    }

    function testHealthFactorWhenDscTokenIsNotMinted() public depositedCollateral {
        vm.prank(USER);
        uint256 healthFactor = dsce.getUserHealthFactor(USER);
        uint256 expectedHealthFactor = type(uint256).max;

        assertEq(healthFactor, expectedHealthFactor);
        vm.stopPrank();
    }

    function testHealthFactorWhenDscTokenIsMinted() public depositedCollateral {
        vm.prank(USER);
        dsce.mintDsc(amountToMint);

        uint256 healthFactor = dsce.getUserHealthFactor(USER);
        console.log("healthFactor :", healthFactor);
        // 100_000_000_000_000_000_000

        // maximum threshold = 10000
        // amountToMint = 100
        // expectedHealthFactor = 10000 / 100 = 100

        uint256 expectedHealthFactor = 100e18;
        assertEq(healthFactor, expectedHealthFactor);
        vm.stopPrank();
    }

    // This test needs it's own custom setup
    function testRevertsIfMintFails() public {
        // Arrange - Setup
        MockFailedMintDSC mockDsc = new MockFailedMintDSC();
        tokenAddresses = [weth];
        priceFeedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(mockDsce), amountCollateral);

        vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);
        mockDsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();
    }

    /////////////////////////////////////////////////////
    // depositCollateralAndMintDsc Tests                //
    /////////////////////////////////////////////////////
    function testRevertIfCollateralIsZero() public {
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateralAndMintDsc(weth, 0, amountToMint);
        vm.stopPrank();
    }

    function testRevertIfDscIsZero() public approveCollateral {
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, 0);
        vm.stopPrank();
    }

    function testRevertIfTokenNotAllowed() public {
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector);
        dsce.depositCollateralAndMintDsc(address(1), amountCollateral, 0);
        vm.stopPrank();
    }

    function testCanDepositCollateralAndMintDsc() public depositedCollateralAndMint {
        vm.prank(USER);
        uint256 userBalance = dsce.getDSCMinted(USER);
        assertEq(userBalance, amountToMint);
        vm.stopPrank();
    }

    function testRevertIfHealthFactorBrokeWhenDscAmountIsGreater() public approveCollateral {
        vm.prank(USER);
        uint256 amountToMintToFail = 20000 ether;
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreakHealthFactor.selector, 0.5 ether));
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMintToFail);
        vm.stopPrank();
    }

    /////////////////////////////////////////////////////
    // RedeemCollateral Tests                          //
    /////////////////////////////////////////////////////
    function testCanRedeemCollateral() public depositCollateralAndRedeem {
        vm.prank(USER);
        uint256 expectedCollateralBalance =
            dsce.getUsdValue(weth, amountCollateral) - dsce.getUsdValue(weth, amountCollateralRedeem);
        (, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        assertEq(collateralValueInUsd, expectedCollateralBalance);
        vm.stopPrank();
    }

    function testRevertIfAmountCollateralIsZero() public depositedCollateralAndMint {
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertIfCollateralTokenIsValid() public depositedCollateralAndMint {
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector);
        dsce.redeemCollateral(address(0), 1 ether);
        vm.stopPrank();
    }

    function testRevertIfCollateralRedeemIsGreaterThanCollateralBalance() public depositedCollateralAndMint {
        vm.prank(USER);
        vm.expectRevert();
        dsce.redeemCollateral(weth, amountCollateral + 1 ether);
        vm.stopPrank();
    }

    function testEmitTheCorrectRedeemValue() public depositedCollateralAndMint {
        vm.prank(USER);
        vm.expectEmit(true, true, true, true);
        emit DSCEngine.CollateralRedeemed(USER, USER, weth, amountCollateralRedeem);
        dsce.redeemCollateral(weth, amountCollateralRedeem);
        vm.stopPrank();
    }

    /////////////////////////////////////////
    // burnDsc Tests                          //
    /////////////////////////////////////////

    function testRevertIfBurnDscIsZero() public depositedCollateralAndMint {
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.burnDsc(0);
        vm.stopPrank();
    }

    function testRevertIfBurnAmountIsGreaterThanDscBalance() public depositedCollateralAndMint {
        vm.prank(USER);
        vm.expectRevert();
        dsce.burnDsc(120 ether);
        vm.stopPrank();
    }

    function testCanBurnDsc() public depositedCollateralAndMint {
        vm.startPrank(USER);
        dsc.approve(address(dsce), amountToMint);
        dsce.burnDsc(10 ether); // 10 DSC
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 90 ether);
    }

    function testRevertIfApprovalIsNotGivenForBurnDsc() public depositedCollateralAndMint {
        vm.startPrank(USER);
        vm.expectRevert();
        dsce.burnDsc(10 ether);
        vm.stopPrank();
    }

    ///////////////////////////////////////////////////////////
    // redeemCollateralForDsc Tests                          //
    ///////////////////////////////////////////////////////////

    function testRedeemCollateralForDscValidCollateralAddress() public depositedCollateralAndMint {
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector);
        dsce.redeemCollateralForDsc(address(0), 1 ether, 100 ether);
    }

    function testRevertIfCollateralAddressIsZeroInRedeemCollateralForDsc() public depositedCollateralAndMint {
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.redeemCollateralForDsc(weth, 0, 100 ether);
    }

    function testCanRedeemDepositedCollateral() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        dsc.approve(address(dsce), amountToMint);
        dsce.redeemCollateralForDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    function testRevertIfHealthFactorBrokeRedeemDepositedCollateral() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        // dsce.depositCollateral(weth, )
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        dsc.approve(address(dsce), amountToMint);

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreakHealthFactor.selector, 0));
        dsce.redeemCollateralForDsc(weth, amountCollateral, 1 ether);
        vm.stopPrank();
    }

    //////////////////////////////////////////////
    // liquidate Tests                          //
    ///////////////////////////////////////////////

    function testRevertWhenCollateralTokenIsNotApproved() public depositedCollateralAndMint {
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector);
        dsce.liquidate(address(0), USER, 1 ether);
    }

    function testRevertWhenDebtToCoverIsZero() public depositedCollateralAndMint {
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.liquidate(weth, USER, 0);
    }

    function testRevertWhenHealthFactorIsOk() public depositedCollateralAndMint {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOK.selector);
        dsce.liquidate(weth, USER, 0.1 ether);
        vm.stopPrank();
    }

    function testCanLiquidate() public depositedCollateralAndMint {
        vm.startPrank(USER);
        
        vm.stopPrank();
    }
}

// src/DSCEngine.sol               | 53.03% (35/66)  | 53.76% (50/93)  | 20.00% (2/10) | 52.17% (12/23)

// src/DSCEngine.sol               | 56.06% (37/66)  | 55.91% (52/93)  | 20.00% (2/10) | 52.17% (12/23)

// src/DSCEngine.sol               | 65.15% (43/66)  | 63.44% (59/93)   | 20.00% (2/10) | 60.87% (14/23) |

// src/DSCEngine.sol               | 72.06% (49/68)  | 69.47% (66/95)   | 20.00% (2/10) | 66.67% (16/24)

//  src/DSCEngine.sol               | 76.47% (52/68)  | 72.63% (69/95)   | 20.00% (2/10) | 70.83% (17/24) |

// src/DSCEngine.sol               | 76.47% (52/68)  | 72.63% (69/95)   | 20.00% (2/10) | 70.83% (17/24)

// src/DSCEngine.sol               | 79.41% (54/68)  | 74.74% (71/95)   | 30.00% (3/10) | 79.17% (19/24)
