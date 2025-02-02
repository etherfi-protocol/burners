// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {SelfDestruct} from "../common/SelfDestruct.sol";
import {UintRequests} from "../common/UintRequests.sol";

import {ISwEXIT} from "../../interfaces/burners/swETH/ISwEXIT.sol";
import {IswETH_Burner} from "../../interfaces/burners/swETH/IswETH_Burner.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract swETH_Burner is UintRequests, IswETH_Burner, IERC721Receiver {
    using Math for uint256;

    /**
     * @inheritdoc IswETH_Burner
     */
    address public immutable COLLATERAL;

    /**
     * @inheritdoc IswETH_Burner
     */
    address public immutable SWEXIT;

    constructor(address collateral, address swEXIT) {
        COLLATERAL = collateral;

        SWEXIT = swEXIT;

        IERC20(COLLATERAL).approve(SWEXIT, type(uint256).max);
    }

    /**
     * @inheritdoc IswETH_Burner
     */
    function triggerWithdrawal(
        uint256 maxRequests
    ) external returns (uint256 firstRequestId, uint256 lastRequestId) {
        uint256 amount = IERC20(COLLATERAL).balanceOf(address(this));

        uint256 maxWithdrawalAmount = ISwEXIT(SWEXIT).withdrawRequestMaximum();
        uint256 minWithdrawalAmount = ISwEXIT(SWEXIT).withdrawRequestMinimum();

        uint256 requests = amount / maxWithdrawalAmount;
        if (amount % maxWithdrawalAmount >= minWithdrawalAmount) {
            requests += 1;
        }
        requests = Math.min(requests, maxRequests);

        if (requests == 0) {
            revert InsufficientWithdrawal();
        }

        uint256 requestsMinusOne = requests - 1;
        firstRequestId = ISwEXIT(SWEXIT).getLastTokenIdCreated() + 1;
        lastRequestId = firstRequestId + requestsMinusOne;
        uint256 requestId = firstRequestId;
        for (; requestId < lastRequestId; ++requestId) {
            _addRequestId(requestId);
            ISwEXIT(SWEXIT).createWithdrawRequest(maxWithdrawalAmount);
        }
        _addRequestId(requestId);
        ISwEXIT(SWEXIT).createWithdrawRequest(
            Math.min(amount - requestsMinusOne * maxWithdrawalAmount, maxWithdrawalAmount)
        );

        emit TriggerWithdrawal(msg.sender, firstRequestId, lastRequestId);

        return (firstRequestId, lastRequestId);
    }

    /**
     * @inheritdoc IswETH_Burner
     */
    function triggerBurn(
        uint256 requestId
    ) external {
        _removeRequestId(requestId);

        ISwEXIT(SWEXIT).finalizeWithdrawal(requestId);

        new SelfDestruct{value: address(this).balance}();

        emit TriggerBurn(msg.sender, requestId);
    }

    /**
     * @inheritdoc IERC721Receiver
     */
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}
