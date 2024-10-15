// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IRouterBurner} from "../../interfaces/router/IRouterBurner.sol";

import {IBurner} from "@symbioticfi/core/src/interfaces/slasher/IBurner.sol";
import {IRegistry} from "@symbioticfi/core/src/interfaces/common/IRegistry.sol";
import {IVault} from "@symbioticfi/core/src/interfaces/vault/IVault.sol";
import {Subnetwork} from "@symbioticfi/core/src/contracts/libraries/Subnetwork.sol";

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";

contract RouterBurner is OwnableUpgradeable, IRouterBurner {
    using SafeCast for uint256;
    using Subnetwork for bytes32;
    using SafeERC20 for IERC20;

    /**
     * @inheritdoc IRouterBurner
     */
    address public immutable VAULT_FACTORY;

    /**
     * @inheritdoc IRouterBurner
     */
    address public vault;

    /**
     * @inheritdoc IRouterBurner
     */
    address public collateral;

    /**
     * @inheritdoc IRouterBurner
     */
    uint256 public receiverSetEpochsDelay;

    /**
     * @inheritdoc IRouterBurner
     */
    uint256 public lastBalance;

    /**
     * @inheritdoc IRouterBurner
     */
    Address public globalReceiver;

    /**
     * @inheritdoc IRouterBurner
     */
    PendingAddress public pendingGlobalReceiver;

    /**
     * @inheritdoc IRouterBurner
     */
    mapping(address network => Address receiver) public networkReceiver;

    /**
     * @inheritdoc IRouterBurner
     */
    mapping(address network => PendingAddress pendingReceiver) public pendingNetworkReceiver;

    /**
     * @inheritdoc IRouterBurner
     */
    mapping(address network => mapping(address operator => Address receiver)) public operatorNetworkReceiver;

    /**
     * @inheritdoc IRouterBurner
     */
    mapping(address network => mapping(address operator => PendingAddress pendingReceiver)) public
        pendingOperatorNetworkReceiver;

    /**
     * @inheritdoc IRouterBurner
     */
    mapping(address receiver => uint256 amount) public balanceOf;

    constructor(
        address vaultFactory
    ) {
        VAULT_FACTORY = vaultFactory;
    }

    /**
     * @inheritdoc IRouterBurner
     */
    function isInitialized() external view returns (bool) {
        return vault != address(0);
    }

    /**
     * @inheritdoc IBurner
     */
    function onSlash(
        bytes32 subnetwork,
        address operator,
        uint256, /* amount */
        uint48 /* captureTimestamp */
    ) external {
        address network = subnetwork.network();
        uint256 currentBalance = IERC20(collateral).balanceOf(address(this));
        balanceOf[_getReceiver(network, operator)] += currentBalance - lastBalance;
        lastBalance = currentBalance;
    }

    /**
     * @inheritdoc IRouterBurner
     */
    function triggerTransfer(
        address receiver
    ) external returns (uint256 amount) {
        amount = balanceOf[receiver];

        if (amount == 0) {
            revert InsufficientBalance();
        }

        balanceOf[receiver] = 0;

        IERC20(collateral).safeTransfer(receiver, amount);

        emit TriggerTransfer(receiver, amount);
    }

    /**
     * @inheritdoc IRouterBurner
     */
    function setGlobalReceiver(
        address receiver
    ) external onlyOwner {
        _setReceiver(receiver, globalReceiver, pendingGlobalReceiver);

        emit SetGlobalReceiver(receiver);
    }

    /**
     * @inheritdoc IRouterBurner
     */
    function acceptGlobalReceiver() external {
        _acceptReceiver(globalReceiver, pendingGlobalReceiver);

        emit AcceptGlobalReceiver();
    }

    /**
     * @inheritdoc IRouterBurner
     */
    function setNetworkReceiver(address network, address receiver) external onlyOwner {
        _setReceiver(receiver, networkReceiver[network], pendingNetworkReceiver[network]);

        emit SetNetworkReceiver(network, receiver);
    }

    /**
     * @inheritdoc IRouterBurner
     */
    function acceptNetworkReceiver(
        address network
    ) external {
        _acceptReceiver(networkReceiver[network], pendingNetworkReceiver[network]);

        emit AcceptNetworkReceiver(network);
    }

    /**
     * @inheritdoc IRouterBurner
     */
    function setOperatorNetworkReceiver(address network, address operator, address receiver) external onlyOwner {
        _setReceiver(
            receiver, operatorNetworkReceiver[network][operator], pendingOperatorNetworkReceiver[network][operator]
        );

        emit SetOperatorNetworkReceiver(network, operator, receiver);
    }

    /**
     * @inheritdoc IRouterBurner
     */
    function acceptOperatorNetworkReceiver(address network, address operator) external {
        _acceptReceiver(operatorNetworkReceiver[network][operator], pendingOperatorNetworkReceiver[network][operator]);

        emit AcceptOperatorNetworkReceiver(network, operator);
    }

    /**
     * @inheritdoc IRouterBurner
     */
    function setVault(
        address vault_
    ) external {
        if (vault != address(0)) {
            revert VaultAlreadyInitialized();
        }

        if (!IRegistry(VAULT_FACTORY).isEntity(vault_)) {
            revert NotVault();
        }

        if (IVault(vault_).burner() != address(this)) {
            revert InvalidVault();
        }

        vault = vault_;

        collateral = IVault(vault).collateral();

        emit SetVault(vault_);
    }

    function initialize(
        InitParams calldata params
    ) external initializer {
        if (params.receiverSetEpochsDelay < 3) {
            revert InvalidReceiverSetEpochsDelay();
        }

        if (params.owner != address(0)) {
            __Ownable_init(params.owner);
        }

        globalReceiver.value = params.globalReceiver;

        for (uint256 i; i < params.networkReceivers.length; ++i) {
            address network = params.networkReceivers[i].network;
            address receiver = params.networkReceivers[i].receiver;
            Address storage networkReceiver_ = networkReceiver[network];

            if (receiver == address(0)) {
                revert InvalidReceiver();
            }

            if (networkReceiver_.value != address(0)) {
                revert DuplicateNetworkReceiver();
            }

            networkReceiver_.value = receiver;
        }

        for (uint256 i; i < params.operatorNetworkReceivers.length; ++i) {
            address network = params.operatorNetworkReceivers[i].network;
            address operator = params.operatorNetworkReceivers[i].operator;
            address receiver = params.operatorNetworkReceivers[i].receiver;
            Address storage operatorNetworkReceiver_ = operatorNetworkReceiver[network][operator];

            if (receiver == address(0)) {
                revert InvalidReceiver();
            }

            if (operatorNetworkReceiver_.value != address(0)) {
                revert DuplicateOperatorNetworkReceiver();
            }

            operatorNetworkReceiver_.value = receiver;
        }

        receiverSetEpochsDelay = params.receiverSetEpochsDelay;
    }

    function _getReceiver(address network, address operator) internal view returns (address receiver) {
        address operatorNetworkReceiver_ = operatorNetworkReceiver[network][operator].value;
        if (operatorNetworkReceiver_ != address(0)) {
            return operatorNetworkReceiver_;
        }

        address networkReceiver_ = networkReceiver[network].value;
        if (networkReceiver_ != address(0)) {
            return networkReceiver_;
        }

        return globalReceiver.value;
    }

    function _setReceiver(
        address newReceiver,
        Address storage currentReceiver,
        PendingAddress storage pendingReceiver
    ) internal {
        if (pendingReceiver.timestamp != 0 && pendingReceiver.timestamp <= Time.timestamp()) {
            currentReceiver.value = pendingReceiver.value;
            pendingReceiver.value = address(0);
            pendingReceiver.timestamp = 0;
        }

        if (pendingReceiver.timestamp != 0) {
            pendingReceiver.value = address(0);
            pendingReceiver.timestamp = 0;
        } else if (newReceiver == currentReceiver.value) {
            revert AlreadySet();
        }

        if (newReceiver != currentReceiver.value) {
            address vault_ = vault;
            pendingReceiver.value = newReceiver;
            pendingReceiver.timestamp = (
                IVault(vault_).currentEpochStart() + receiverSetEpochsDelay * IVault(vault_).epochDuration()
            ).toUint48();
        }
    }

    function _acceptReceiver(Address storage currentReceiver, PendingAddress storage pendingReceiver) internal {
        if (pendingReceiver.timestamp == 0 || pendingReceiver.timestamp > Time.timestamp()) {
            revert NotReady();
        }

        currentReceiver.value = pendingReceiver.value;
        pendingReceiver.value = address(0);
        pendingReceiver.timestamp = 0;
    }
}
