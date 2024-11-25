// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from
    "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/mocks/ERC20Mock.sol";

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

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth,,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    modifier approveCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
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

    /////////////////////////////////////////////////////
    // depositCollateralAndMintDsc Tests                //
    /////////////////////////////////////////////////////
    function testRevertIfCollateralIsZero() public {
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateralAndMintDsc(weth, 0, amountToMint);
        vm.stopPrank();
    }

    function testRevertIfDscIsZero() public {
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

    // 500_000_000_000_000_000
}

//  src/DSCEngine.sol               | 35.38% (23/65)  | 34.78% (32/92)  | 10.00% (1/10) | 27.27% (6/22)  |

//  src/DSCEngine.sol               | 35.38% (23/65)  | 34.78% (32/92)  | 10.00% (1/10) | 27.27% (6/22)  |

// src/DSCEngine.sol               | 50.77% (33/65)  | 51.09% (47/92)  | 10.00% (1/10) | 40.91% (9/22)

// src/DSCEngine.sol               | 51.52% (34/66)  | 51.61% (48/93)  | 10.00% (1/10) | 43.48% (10/23)

// src/DSCEngine.sol          | 51.52% (34/66)  | 52.69% (49/93)  | 20.00% (2/10) | 43.48% (10/23)

//  src/DSCEngine.sol               | 53.03% (35/66)  | 53.76% (50/93)  | 20.00% (2/10) | 47.83% (11/23)

// src/DSCEngine.sol               | 53.03% (35/66)  | 53.76% (50/93)  | 20.00% (2/10) | 52.17% (12/23)

// src/DSCEngine.sol               | 56.06% (37/66)  | 55.91% (52/93)  | 20.00% (2/10) | 52.17% (12/23)
