// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

abstract contract ReentrancyGuard {
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;
    uint256 private _status = NOT_ENTERED;

    error Reentrant();

    modifier nonReentrant() {
        if (_status == ENTERED) revert Reentrant();
        _status = ENTERED;
        _;
        _status = NOT_ENTERED;
    }
}
