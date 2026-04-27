// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {Bridge} from "../src/bridge/Bridge.sol";
import {BridgeAgency} from "../src/bridge/BridgeAgency.sol";
import {BridgeERC20} from "../src/bridge/BridgeERC20.sol";
import {IBridge} from "../src/bridge/IBridge.sol";

import {BridgeBaseTest} from "./BridgeBase.t.sol";
import {Token} from "./mocks/Token.sol";

/// @notice Covers `BridgeAgency`: onlyOwner enforcement, deployAndAddBridgeToken returns a working
///         BridgeERC20 BeaconProxy where Bridge is MINTER_ROLE-holder, and the various pass-through
///         setters.
contract BridgeAgencyTest is BridgeBaseTest {
    function test_addToken_onlyOwner() public {
        Token token = new Token("X");
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        agency.addToken(address(token), IBridge.BridgeMode.LockRelease);
    }

    function test_deployAndAddBridgeToken_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        agency.deployAndAddBridgeToken("X", "X");
    }

    function test_mapRemote_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        agency.mapRemote(address(0xdead), 7, address(0xbeef));
    }

    function test_setEnabled_onlyOwner() public {
        Token t = new Token("X");
        agency.addToken(address(t), IBridge.BridgeMode.LockRelease);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        agency.setEnabled(address(t), false);
    }

    function test_deployAndAddBridgeToken_grantsMinterRole() public {
        address t = agency.deployAndAddBridgeToken("Sat USDT", "satUSDT");
        BridgeERC20 token = BridgeERC20(t);

        assertTrue(token.hasRole(token.MINTER_ROLE(), address(bridge)));
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), address(bridge)));
        assertEq(token.name(), "Sat USDT");
        assertEq(token.symbol(), "satUSDT");

        // Bridge can mint via prank.
        vm.prank(address(bridge));
        token.mint(alice, 100 ether);
        assertEq(token.balanceOf(alice), 100 ether);

        // Random caller cannot mint.
        vm.expectRevert();
        vm.prank(alice);
        token.mint(alice, 1);
    }

    function test_deployAndAddBridgeToken_registersAsMintBurn() public {
        address t = agency.deployAndAddBridgeToken("Sat", "S");
        (bool enabled, IBridge.BridgeMode mode) = bridge.tokenConfig(t);
        assertTrue(enabled);
        assertEq(uint8(mode), uint8(IBridge.BridgeMode.MintBurn));
    }

    function test_addToken_thenMapRemote_thenSetEnabled() public {
        Token t = new Token("LR");
        agency.addToken(address(t), IBridge.BridgeMode.LockRelease);
        agency.mapRemote(address(t), 5, makeAddr("dst5"));

        // Verify Bridge state reflects the agency's calls.
        (bool enabled, IBridge.BridgeMode mode) = bridge.tokenConfig(address(t));
        assertTrue(enabled);
        assertEq(uint8(mode), uint8(IBridge.BridgeMode.LockRelease));
        assertEq(bridge.remoteToken(address(t), 5), makeAddr("dst5"));

        agency.setEnabled(address(t), false);
        (enabled, mode) = bridge.tokenConfig(address(t));
        assertFalse(enabled);
        // mode preserved
        assertEq(uint8(mode), uint8(IBridge.BridgeMode.LockRelease));
    }

    function test_setLocalChainID_routesToBridge() public {
        // Reset the bridge's local chain ID to 0 by re-deploying a fresh proxy.
        // Easier: this test expects setLocalChainID to revert because LOCAL_CID is already set in setUp.
        vm.expectRevert(IBridge.InvalidLocalChainID.selector);
        agency.setLocalChainID(99);
    }

    function test_views() public view {
        assertEq(agency.bridge(), address(bridge));
        assertEq(agency.bridgeERC20Beacon(), address(bridgeERC20Beacon));
    }
}
