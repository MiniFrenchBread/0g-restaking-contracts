// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Bridge} from "../src/bridge/Bridge.sol";
import {BridgeAgency} from "../src/bridge/BridgeAgency.sol";
import {BridgeERC20} from "../src/bridge/BridgeERC20.sol";
import {IBridge} from "../src/bridge/IBridge.sol";

import {Token} from "./mocks/Token.sol";

/**
 * @title BridgeBaseTest
 * @notice Common setUp for bridge tests: deploys Bridge / BridgeAgency / BridgeERC20 (impl + beacon
 *         + proxy where applicable) and wires ADMIN_ROLE → Agency.
 * @dev Mirrors the production deployment topology so test scenarios exercise the same trust path
 *      as launch-day. W0G-specific infrastructure (mock precompile + mock W0G token) is set up
 *      separately by W0gIntegrationTest to keep this base lean.
 */
contract BridgeBaseTest is Test {
    address internal owner;
    address internal alice;
    address internal bob;

    Bridge internal bridge;
    BridgeAgency internal agency;

    UpgradeableBeacon internal bridgeBeacon;
    UpgradeableBeacon internal agencyBeacon;
    UpgradeableBeacon internal bridgeERC20Beacon;

    /// @dev This chain's chainID under test. Set arbitrarily but consistently.
    uint64 internal constant LOCAL_CID = 1;
    /// @dev Default destination chainID used in user-path tests.
    uint64 internal constant DST_CID = 2;

    function setUp() public virtual {
        owner = address(this);
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // BridgeERC20 beacon (impl + beacon, no proxy — proxies are deployed per-token at runtime).
        BridgeERC20 erc20Impl = new BridgeERC20();
        bridgeERC20Beacon = new UpgradeableBeacon(address(erc20Impl), owner);

        // Bridge impl + beacon + proxy. Initialize with a dummy agency address; we'll re-init the
        // agency after we know the proxy addresses, so we use a two-step pattern:
        // 1) Deploy bridge impl + beacon.
        // 2) Deploy agency impl + beacon + proxy with bridge address known.
        // 3) Deploy bridge proxy with agency address known.
        Bridge bridgeImpl = new Bridge();
        bridgeBeacon = new UpgradeableBeacon(address(bridgeImpl), owner);

        BridgeAgency agencyImpl = new BridgeAgency();
        agencyBeacon = new UpgradeableBeacon(address(agencyImpl), owner);

        // Bridge proxy address is dependent on agency proxy address — we need to break the cycle.
        // Since Agency.initialize(bridge, beacon, owner) needs the bridge address, but
        // Bridge.initialize(localCID, beacon, agency) needs the agency address, we use the
        // approach: deploy Bridge proxy without agency known by predicting agency address using
        // CREATE nonce determinism. A simpler path: deploy Agency proxy with a placeholder bridge,
        // then later re-call setLocalChainID via owner — but Agency stores `bridge` at init too,
        // so we need to know it. Cleanest path under Foundry: predict agency address using
        // vm.computeCreateAddress.
        address predictedAgency = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);

        BeaconProxy bridgeProxy = new BeaconProxy(
            address(bridgeBeacon),
            abi.encodeCall(Bridge.initialize, (LOCAL_CID, address(bridgeERC20Beacon), predictedAgency))
        );
        bridge = Bridge(address(bridgeProxy));

        BeaconProxy agencyProxy = new BeaconProxy(
            address(agencyBeacon),
            abi.encodeCall(BridgeAgency.initialize, (address(bridge), address(bridgeERC20Beacon), owner))
        );
        agency = BridgeAgency(address(agencyProxy));

        // Sanity: ensure prediction matches.
        require(address(agency) == predictedAgency, "agency address mismatch");
    }

    /// @dev Deploy a mock LockRelease ERC-20 owned by `recipient`, wire it into the bridge as
    ///      LockRelease, and map a remote token at `DST_CID`.
    function _deployLockReleaseToken(address holder, uint256 supply) internal returns (Token token, address remote) {
        token = new Token("MockLR");
        token.transfer(holder, supply);
        remote = makeAddr("remoteLR");
        agency.addToken(address(token), IBridge.BridgeMode.LockRelease);
        agency.mapRemote(address(token), DST_CID, remote);
    }

    /// @dev Deploy a fresh BridgeERC20 via the agency, register as MintBurn, and map remote.
    function _deployMintBurnToken(
        string memory name,
        string memory symbol
    ) internal returns (BridgeERC20 token, address remote) {
        address t = agency.deployAndAddBridgeToken(name, symbol);
        token = BridgeERC20(t);
        remote = makeAddr(string.concat("remote-", symbol));
        agency.mapRemote(t, DST_CID, remote);
    }

    /// @dev Build a single InboundMessage (helper for system-call tests).
    function _msg(
        uint64 srcCID,
        uint64 nonce,
        address localToken,
        address recipient,
        uint256 amount
    ) internal pure returns (IBridge.InboundMessage memory) {
        return IBridge.InboundMessage({
            srcChainID: srcCID,
            nonce: nonce,
            localToken: localToken,
            recipient: recipient,
            amount: amount
        });
    }
}
