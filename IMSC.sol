// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

interface IMSC {
    function mscPrice() external view returns(uint256);
    function mscPriceTime(uint256 timestamp) external view returns(uint256);
}