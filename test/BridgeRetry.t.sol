// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";

import {Bridge} from "../src/bridge/Bridge.sol";
import {BridgeERC20} from "../src/bridge/BridgeERC20.sol";
import {IBridge} from "../src/bridge/IBridge.sol";

import {BridgeBaseTest} from "./BridgeBase.t.sol";

/// @notice Covers `retry`: happy path, no-pending revert, already-consumed revert, retry-fail
///         keeps pending, retry-fail-then-succeed.
contract BridgeRetryTest is BridgeBaseTest {
    address constant SYSTEM = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;
    uint64 constant SRC_CID = 99;

    /// @dev Drive a message into pendingMessages by disabling the token before the system call.
    function _makePending(BridgeERC20 token, uint64 nonce, uint256 amount) internal {
        agency.setEnabled(address(token), false);
        IBridge.InboundMessage[] memory msgs = new IBridge.InboundMessage[](1);
        msgs[0] = _msg(SRC_CID, nonce, address(token), bob, amount);
        vm.prank(SYSTEM);
        bridge.executeRemoteMessages(msgs);
        // Sanity: pending and not consumed.
        assertFalse(bridge.inboundConsumed(SRC_CID, nonce));
        assertEq(bridge.pendingMessage(SRC_CID, nonce).amount, amount);
    }

    function test_retry_happy() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        _makePending(token, 1, 5 ether);

        // Re-enable so retry succeeds.
        agency.setEnabled(address(token), true);

        // Anyone can call retry — exercise from a third party.
        address random = makeAddr("random");

        vm.expectEmit(true, false, false, true, address(bridge));
        emit IBridge.BridgeIn(SRC_CID, 1, address(token), bob, 5 ether);
        vm.expectEmit(true, false, false, true, address(bridge));
        emit IBridge.BridgeMessageRetried(SRC_CID, 1, true);
        vm.prank(random);
        bridge.retry(SRC_CID, 1);

        assertTrue(bridge.inboundConsumed(SRC_CID, 1));
        assertEq(token.balanceOf(bob), 5 ether);
        // pending cleared
        IBridge.InboundMessage memory cleared = bridge.pendingMessage(SRC_CID, 1);
        assertEq(cleared.amount, 0);
        assertEq(cleared.recipient, address(0));
    }

    function test_retry_revertsIfNoPending() public {
        vm.expectRevert(IBridge.NoPendingMessage.selector);
        bridge.retry(SRC_CID, 42);
    }

    function test_retry_revertsIfAlreadyConsumed() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        // Drive nonce=1 into pending, then artificially mark it consumed via a successful execute.
        _makePending(token, 1, 5 ether);
        agency.setEnabled(address(token), true);
        bridge.retry(SRC_CID, 1); // success → consumed=true, pending cleared
        assertTrue(bridge.inboundConsumed(SRC_CID, 1));

        // Pending was cleared — retrying again hits no-pending first.
        vm.expectRevert(IBridge.NoPendingMessage.selector);
        bridge.retry(SRC_CID, 1);
    }

    function test_retry_failKeepsPending() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        _makePending(token, 1, 5 ether);

        // Token still disabled — retry should fail-keep-pending.
        vm.expectEmit(true, false, false, true, address(bridge));
        emit IBridge.BridgeMessageRetried(SRC_CID, 1, false);
        bridge.retry(SRC_CID, 1);

        assertFalse(bridge.inboundConsumed(SRC_CID, 1));
        assertEq(bridge.pendingMessage(SRC_CID, 1).amount, 5 ether);
    }

    function test_retry_failThenSucceed() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        _makePending(token, 1, 5 ether);

        // First retry fails — token still disabled.
        bridge.retry(SRC_CID, 1);
        assertFalse(bridge.inboundConsumed(SRC_CID, 1));
        assertEq(bridge.pendingMessage(SRC_CID, 1).amount, 5 ether);

        // Re-enable and retry — succeeds.
        agency.setEnabled(address(token), true);
        bridge.retry(SRC_CID, 1);
        assertTrue(bridge.inboundConsumed(SRC_CID, 1));
        assertEq(token.balanceOf(bob), 5 ether);
        assertEq(bridge.pendingMessage(SRC_CID, 1).amount, 0);
    }

    function test_retry_isPermissionless() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        _makePending(token, 1, 5 ether);
        agency.setEnabled(address(token), true);

        // Call from EOA with no roles.
        address rando = makeAddr("rando");
        vm.deal(rando, 1 ether);
        vm.prank(rando);
        bridge.retry(SRC_CID, 1);

        assertTrue(bridge.inboundConsumed(SRC_CID, 1));
    }
}
