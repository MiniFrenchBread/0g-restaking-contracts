// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBridge} from "./IBridge.sol";
import {BridgeERC20} from "./BridgeERC20.sol";

/// @dev Minimal interface for any token that supports MINTER_ROLE-style mint/burnFrom.
///      Both BridgeERC20 (templated minted-token) and W0G match this shape.
interface IMintBurnable {
    function mint(address to, uint256 amount) external;
    function burnFrom(address from, uint256 amount) external;
}

/**
 * @title Bridge
 * @notice Cross-chain bridge contract deployed at a fixed address on every 0G chain (primary + satellite).
 * @dev Storage namespace `0g.bridge.Bridge` (ERC-7201). Beacon-upgradeable; no UUPS.
 *      User flow: `lockAndSend` (LockRelease) / `burnAndSend` (MintBurn) emit a `BridgeOut` event.
 *      System flow: CL → EL → SYSTEM_ADDRESS calls `executeRemoteMessages` with decoded
 *      `InboundMessage[]`. Each message is dispatched via try/catch (self external call) so failures
 *      land in `pendingMessages` and don't abort the entire system call. Anyone can later call
 *      `retry` to reattempt a failed message.
 *      The CL strictly enforces per-(srcCID, dstCID) monotonic nonce, so the contract's
 *      `inboundConsumed` mapping is a defensive replay-shield rather than the primary order check.
 */
contract Bridge is IBridge, Initializable, AccessControlUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice EIP-4788 / EIP-7002 / EIP-7685 system caller.
    address public constant SYSTEM_ADDRESS = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;

    /// @dev Role granted to BridgeAgency on init; allows configuring tokens, mappings, and
    ///      deploying new BridgeERC20 instances.
    bytes32 public constant ADMIN_ROLE = keccak256("BRIDGE_ADMIN_ROLE");

    /// @notice Per-token bridge configuration. Schema-frozen (only enabled flag + mode).
    struct TokenConfig {
        bool enabled;
        BridgeMode mode;
    }

    /// @custom:storage-location erc7201:0g.bridge.Bridge
    struct BridgeStorage {
        uint64 localChainID;
        address bridgeERC20Beacon;
        address agency;
        mapping(address => TokenConfig) tokens;
        mapping(address => mapping(uint64 => address)) remoteToken;
        mapping(uint64 => uint64) outboundNonce;
        mapping(uint64 => mapping(uint64 => bool)) inboundConsumed;
        mapping(uint64 => mapping(uint64 => InboundMessage)) pendingMessages;
        mapping(uint64 => mapping(uint64 => bool)) hasPending;
    }

    // keccak256(abi.encode(uint256(keccak256("0g.bridge.Bridge")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BridgeStorageLocation = 0x1324c42040668e5a4f3621d919fc96f623467372a61a391f09286004a0ed7e00;

    function _getBridgeStorage() internal pure returns (BridgeStorage storage $) {
        assembly {
            $.slot := BridgeStorageLocation
        }
    }

    /// @notice Initialize the Bridge.
    /// @param localChainID_ This chain's `chainId`. May be set to 0 here and finalized later via
    ///        `setLocalChainID` (one-shot) — convenient for the Nick-method deploy where the chain
    ///        config isn't yet known at code constant baking time.
    /// @param bridgeERC20Beacon_ Address of the shared `UpgradeableBeacon` for BridgeERC20 instances.
    /// @param agency_ Address granted ADMIN_ROLE; typically the BridgeAgency proxy.
    function initialize(uint64 localChainID_, address bridgeERC20Beacon_, address agency_) external initializer {
        __AccessControl_init();
        if (bridgeERC20Beacon_ == address(0) || agency_ == address(0)) {
            revert ZeroAddress();
        }
        _grantRole(DEFAULT_ADMIN_ROLE, agency_);
        _grantRole(ADMIN_ROLE, agency_);

        BridgeStorage storage $ = _getBridgeStorage();
        $.localChainID = localChainID_;
        $.bridgeERC20Beacon = bridgeERC20Beacon_;
        $.agency = agency_;
    }

    // ============= User paths =============

    /// @inheritdoc IBridge
    function lockAndSend(address token, uint64 dstCID, address recipient, uint256 amount) external {
        BridgeStorage storage $ = _getBridgeStorage();
        TokenConfig memory cfg = $.tokens[token];
        if (!cfg.enabled) revert TokenDisabled();
        if (cfg.mode != BridgeMode.LockRelease) revert WrongMode();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint64 nonce = ++$.outboundNonce[dstCID];
        emit BridgeOut(
            $.localChainID, dstCID, nonce, token, $.remoteToken[token][dstCID], recipient, amount, uint8(cfg.mode)
        );
    }

    /// @inheritdoc IBridge
    function burnAndSend(address token, uint64 dstCID, address recipient, uint256 amount) external {
        BridgeStorage storage $ = _getBridgeStorage();
        TokenConfig memory cfg = $.tokens[token];
        if (!cfg.enabled) revert TokenDisabled();
        if (cfg.mode != BridgeMode.MintBurn) revert WrongMode();

        IMintBurnable(token).burnFrom(msg.sender, amount);
        uint64 nonce = ++$.outboundNonce[dstCID];
        emit BridgeOut(
            $.localChainID, dstCID, nonce, token, $.remoteToken[token][dstCID], recipient, amount, uint8(cfg.mode)
        );
    }

    // ============= System path =============

    /// @inheritdoc IBridge
    function executeRemoteMessages(
        InboundMessage[] calldata msgs
    ) external {
        if (msg.sender != SYSTEM_ADDRESS) revert NotSystemCaller();
        BridgeStorage storage $ = _getBridgeStorage();
        uint256 n = msgs.length;
        for (uint256 i = 0; i < n; ++i) {
            InboundMessage calldata m = msgs[i];
            if ($.inboundConsumed[m.srcChainID][m.nonce]) {
                emit BridgeMessageFailed(m.srcChainID, m.nonce, bytes("replay"));
                continue;
            }
            _tryDispatch(m);
        }
    }

    // ============= Permissionless retry =============

    /// @inheritdoc IBridge
    function retry(uint64 srcCID, uint64 nonce) external {
        BridgeStorage storage $ = _getBridgeStorage();
        if (!$.hasPending[srcCID][nonce]) revert NoPendingMessage();
        if ($.inboundConsumed[srcCID][nonce]) revert AlreadyConsumed();

        InboundMessage memory stored = $.pendingMessages[srcCID][nonce];
        bool ok;
        bytes memory reason;
        try this.executeOneInternal(stored) {
            ok = true;
        } catch (bytes memory r) {
            reason = r;
        }
        if (ok) {
            $.inboundConsumed[srcCID][nonce] = true;
            delete $.pendingMessages[srcCID][nonce];
            $.hasPending[srcCID][nonce] = false;
            emit BridgeIn(srcCID, nonce, stored.localToken, stored.recipient, stored.amount);
            emit BridgeMessageRetried(srcCID, nonce, true);
        } else {
            emit BridgeMessageFailed(srcCID, nonce, reason);
            emit BridgeMessageRetried(srcCID, nonce, false);
        }
    }

    /// @inheritdoc IBridge
    /// @dev Externally-callable for try/catch. Reverts unless caller is the bridge itself.
    function executeOneInternal(
        InboundMessage calldata m
    ) external {
        if (msg.sender != address(this)) revert OnlySelf();
        BridgeStorage storage $ = _getBridgeStorage();
        TokenConfig memory cfg = $.tokens[m.localToken];
        if (!cfg.enabled) {
            // bubble up an ASCII reason that matches the schema's failure-reason convention.
            assembly {
                mstore(0x00, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                mstore(0x04, 0x20) // string offset
                mstore(0x24, 0x08) // length 8
                mstore(0x44, "disabled")
                revert(0x00, 0x64)
            }
        }
        if (cfg.mode == BridgeMode.MintBurn) {
            IMintBurnable(m.localToken).mint(m.recipient, m.amount);
        } else {
            IERC20(m.localToken).safeTransfer(m.recipient, m.amount);
        }
    }

    /// @dev Wrap an InboundMessage execution in try/catch and route success/failure to storage.
    function _tryDispatch(
        InboundMessage calldata m
    ) internal {
        BridgeStorage storage $ = _getBridgeStorage();
        bool ok;
        bytes memory reason;
        try this.executeOneInternal(m) {
            ok = true;
        } catch (bytes memory r) {
            reason = r;
        }
        if (ok) {
            $.inboundConsumed[m.srcChainID][m.nonce] = true;
            // Wipe any stale pending entry (defensive — should be impossible under CL nonce rules).
            if ($.hasPending[m.srcChainID][m.nonce]) {
                delete $.pendingMessages[m.srcChainID][m.nonce];
                $.hasPending[m.srcChainID][m.nonce] = false;
            }
            emit BridgeIn(m.srcChainID, m.nonce, m.localToken, m.recipient, m.amount);
        } else {
            $.pendingMessages[m.srcChainID][m.nonce] = m;
            $.hasPending[m.srcChainID][m.nonce] = true;
            emit BridgeMessageFailed(m.srcChainID, m.nonce, reason);
        }
    }

    // ============= Admin (ADMIN_ROLE) =============

    /// @inheritdoc IBridge
    function configureToken(address localToken, bool enabled, BridgeMode mode) external onlyRole(ADMIN_ROLE) {
        if (localToken == address(0)) revert ZeroAddress();
        BridgeStorage storage $ = _getBridgeStorage();
        $.tokens[localToken] = TokenConfig({enabled: enabled, mode: mode});
    }

    /// @inheritdoc IBridge
    function mapRemoteToken(address localToken, uint64 dstCID, address remoteToken_) external onlyRole(ADMIN_ROLE) {
        if (localToken == address(0)) revert ZeroAddress();
        BridgeStorage storage $ = _getBridgeStorage();
        $.remoteToken[localToken][dstCID] = remoteToken_;
    }

    /// @inheritdoc IBridge
    function deployBridgeERC20(
        string memory name_,
        string memory symbol_
    ) external onlyRole(ADMIN_ROLE) returns (address localToken) {
        BridgeStorage storage $ = _getBridgeStorage();
        bytes memory init = abi.encodeCall(BridgeERC20.initialize, (name_, symbol_, address(this)));
        localToken = address(new BeaconProxy($.bridgeERC20Beacon, init));
    }

    /// @inheritdoc IBridge
    function setLocalChainID(
        uint64 chainID
    ) external onlyRole(ADMIN_ROLE) {
        if (chainID == 0) revert InvalidLocalChainID();
        BridgeStorage storage $ = _getBridgeStorage();
        if ($.localChainID != 0) revert InvalidLocalChainID();
        $.localChainID = chainID;
    }

    // ============= Views =============

    /// @inheritdoc IBridge
    function localChainID() external view returns (uint64) {
        return _getBridgeStorage().localChainID;
    }

    /// @inheritdoc IBridge
    function tokenConfig(
        address localToken
    ) external view returns (bool enabled, BridgeMode mode) {
        TokenConfig memory cfg = _getBridgeStorage().tokens[localToken];
        return (cfg.enabled, cfg.mode);
    }

    /// @inheritdoc IBridge
    function remoteToken(address localToken, uint64 dstCID) external view returns (address) {
        return _getBridgeStorage().remoteToken[localToken][dstCID];
    }

    /// @inheritdoc IBridge
    function outboundNonce(
        uint64 dstCID
    ) external view returns (uint64) {
        return _getBridgeStorage().outboundNonce[dstCID];
    }

    /// @inheritdoc IBridge
    function inboundConsumed(uint64 srcCID, uint64 nonce) external view returns (bool) {
        return _getBridgeStorage().inboundConsumed[srcCID][nonce];
    }

    /// @inheritdoc IBridge
    function pendingMessage(uint64 srcCID, uint64 nonce) external view returns (InboundMessage memory) {
        return _getBridgeStorage().pendingMessages[srcCID][nonce];
    }

    /// @notice Returns the BridgeERC20 beacon address (read helper, not in IBridge interface).
    function bridgeERC20Beacon() external view returns (address) {
        return _getBridgeStorage().bridgeERC20Beacon;
    }

    /// @notice Returns the agency address granted ADMIN_ROLE.
    function agency() external view returns (address) {
        return _getBridgeStorage().agency;
    }
}
