// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {SwapAndBridgeOptimismRouter, IL1StandardBridge} from "../src/SwapAndBridgeOptimismRouter.sol";

interface IOUTbToken {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function faucet() external;
}

contract TestSwapAndBridgeOptimismRouter is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    /*//////////////////////////////////////////////////////////////
        EVENTS (from L1StandardBridge and L1CrossDomainMessenger)
    //////////////////////////////////////////////////////////////*/

    event ETHDepositInitiated(address indexed from, address indexed to, uint256 amount, bytes extraData);
    event ERC20DepositInitiated(
        address indexed l1Token,
        address indexed l2Token,
        address indexed from,
        address to,
        uint256 amount,
        bytes extraData
    );
    event ETHBridgeInitiated(address indexed from, address indexed to, uint256 amount, bytes extraData);
    event ERC20BridgeInitiated(
        address indexed localToken,
        address indexed remoteToken,
        address indexed from,
        address to,
        uint256 amount,
        bytes extraData
    );
    event SentMessage(address indexed target, address sender, bytes message, uint256 messageNonce, uint256 gasLimit);
    event SentMessageExtension1(address indexed sender, uint256 value);

    /*//////////////////////////////////////////////////////////////
        TEST STORAGE
    //////////////////////////////////////////////////////////////*/

    SwapAndBridgeOptimismRouter poolSwapAndBridgeOptimism;

    // OUTb = Optimism Useless Token Bridged (ETH Sepolia and OP Sepolia addresses)
    IOUTbToken OUTbL1Token = IOUTbToken(0x12608ff9dac79d8443F17A4d39D93317BAD026Aa);
    IOUTbToken OUTbL2Token = IOUTbToken(0x7c6b91D9Be155A6Db01f749217d76fF02A7227F2);

    // L1 Standard Bridge on ETH Sepolia
    IL1StandardBridge public constant l1StandardBridge = IL1StandardBridge(0xFBb0621E0B23b5478B630BD55a5f21f67730B0F1);

    // L2CrossDomainMessenger predeploy
    address public constant l2CrossDomainMessenger = 0x4200000000000000000000000000000000000010;

    /*//////////////////////////////////////////////////////////////
        SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        // rpc.sepolia.org from the lesson is often down; use SEPOLIA_RPC_URL if set, else the public RPC alias
        string memory rpc = vm.envOr("SEPOLIA_RPC_URL", vm.rpcUrl("sepolia"));
        vm.createSelectFork(rpc);
        vm.deal(address(this), 500 ether);

        deployFreshManagerAndRouters();
        poolSwapAndBridgeOptimism = new SwapAndBridgeOptimismRouter(manager, l1StandardBridge);

        OUTbL1Token.faucet();
        OUTbL1Token.approve(address(poolSwapAndBridgeOptimism), type(uint256).max);
        OUTbL1Token.approve(address(modifyLiquidityRouter), type(uint256).max);

        poolSwapAndBridgeOptimism.addL1ToL2TokenAddress(address(OUTbL1Token), address(OUTbL2Token));

        (key,) = initPool(
            CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(OUTbL1Token)), IHooks(address(0)), 3000, SQRT_PRICE_1_1
        );
        modifyLiquidityRouter.modifyLiquidity{value: 1 ether}(
            key,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 10 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );
    }

    // We are on an L1 fork, so the OP Sepolia side can't be checked: we assert on emitted bridge events.

    /*//////////////////////////////////////////////////////////////
        ETH -> OUTb, bridge
    //////////////////////////////////////////////////////////////*/

    function _expectERC20BridgeEvents(address recipient) internal {
        vm.expectEmit(true, true, true, false);
        emit ERC20DepositInitiated(
            address(OUTbL1Token), address(OUTbL2Token), address(poolSwapAndBridgeOptimism), recipient, 0, ZERO_BYTES
        );
        vm.expectEmit(true, true, true, false);
        emit ERC20BridgeInitiated(
            address(OUTbL1Token), address(OUTbL2Token), address(poolSwapAndBridgeOptimism), recipient, 0, ZERO_BYTES
        );
        vm.expectEmit(true, false, false, false);
        emit SentMessage(l2CrossDomainMessenger, address(0), ZERO_BYTES, 0, 0);
        vm.expectEmit(true, false, false, false);
        emit SentMessageExtension1(address(l1StandardBridge), 0);
    }

    function _expectETHBridgeEvents(address recipient) internal {
        vm.expectEmit(true, true, false, false);
        emit ETHDepositInitiated(address(poolSwapAndBridgeOptimism), recipient, 0, ZERO_BYTES);
        vm.expectEmit(true, true, false, false);
        emit ETHBridgeInitiated(address(poolSwapAndBridgeOptimism), recipient, 0, ZERO_BYTES);
        vm.expectEmit(true, false, false, false);
        emit SentMessage(l2CrossDomainMessenger, address(0), ZERO_BYTES, 0, 0);
        vm.expectEmit(true, false, false, false);
        emit SentMessageExtension1(address(l1StandardBridge), 0);
    }

    function _swapETHForOUTb(bool bridge, address recipient) internal {
        poolSwapAndBridgeOptimism.swap{value: 0.001 ether}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -0.001 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            SwapAndBridgeOptimismRouter.SwapSettings({bridgeTokens: bridge, recipientAddress: recipient}),
            ZERO_BYTES
        );
    }

    function _swapOUTbForETH(bool bridge, address recipient) internal {
        poolSwapAndBridgeOptimism.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: -0.001 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            SwapAndBridgeOptimismRouter.SwapSettings({bridgeTokens: bridge, recipientAddress: recipient}),
            ZERO_BYTES
        );
    }

    function test_swapETHForOUTb_bridgeTokensToOptimism_recipientSameAsSender() public {
        _expectERC20BridgeEvents(address(this));
        _swapETHForOUTb(true, address(this));
    }

    function test_swapETHForOUTb_bridgeTokensToOptimism_recipientNotSameAsSender() public {
        _expectERC20BridgeEvents(address(0x1));
        _swapETHForOUTb(true, address(0x1));
    }

    /*//////////////////////////////////////////////////////////////
        OUTb -> ETH, bridge
    //////////////////////////////////////////////////////////////*/

    function test_swapOUTbForETH_bridgeTokensToOptimism_recipientSameAsSender() public {
        _expectETHBridgeEvents(address(this));
        _swapOUTbForETH(true, address(this));
    }

    function test_swapOUTbForETH_bridgeTokensToOptimism_recipientNotSameAsSender() public {
        _expectETHBridgeEvents(address(0x1));
        _swapOUTbForETH(true, address(0x1));
    }

    /*//////////////////////////////////////////////////////////////
        No bridging
    //////////////////////////////////////////////////////////////*/

    function test_swapETHForOUTb_dontBridgeTokens() public {
        uint256 ethBefore = address(this).balance;
        uint256 outbBefore = OUTbL1Token.balanceOf(address(this));

        _swapETHForOUTb(false, address(this));

        assertEq(ethBefore - address(this).balance, 0.001 ether);
        assertGt(OUTbL1Token.balanceOf(address(this)), outbBefore);
    }

    function test_swapOUTbForETH_dontBridgeTokens() public {
        uint256 ethBefore = address(this).balance;
        uint256 outbBefore = OUTbL1Token.balanceOf(address(this));

        _swapOUTbForETH(false, address(this));

        assertGt(address(this).balance, ethBefore);
        assertEq(outbBefore - OUTbL1Token.balanceOf(address(this)), 0.001 ether);
    }

    /*//////////////////////////////////////////////////////////////
        Extra: unsupported token reverts early
    //////////////////////////////////////////////////////////////*/

    function test_revertsIfOutputTokenNotSupported() public {
        poolSwapAndBridgeOptimism.addL1ToL2TokenAddress(address(OUTbL1Token), address(0));
        vm.expectRevert(SwapAndBridgeOptimismRouter.TokenCannotBeBridged.selector);
        _swapETHForOUTb(true, address(this));
    }
}
