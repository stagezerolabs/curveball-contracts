// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Virtual-reserve constant-product curve math. Every rounding step favours the curve.
/// @dev `vT`/`vQ` are the virtual token and quote reserves. Callers keep them within uint128,
///      so `vT * vQ` never overflows.
library CurveMath {
    uint256 internal constant BPS = 10_000;

    error InvalidTarget();
    error InvalidAmount();
    error SoldOut();
    error ZeroOutput();
    error DustTrade();
    error InsufficientReserve();

    struct Buy {
        uint256 tokensOut;
        uint256 spent;
        uint256 curveQuote;
        uint256 fee;
        uint256 tax;
    }

    struct Sell {
        uint256 net;
        uint256 gross;
        uint256 fee;
        uint256 tax;
    }

    /// @notice Starting virtual quote such that selling `curveSupply` raises exactly `target`.
    /// @dev With vT0 = supply, the sellout reserve is supply * vQ0 / (supply - curveSupply), so
    ///      vQ0 = target * (supply - curveSupply) / curveSupply must divide exactly.
    function initialVirtualQuote(uint256 target, uint256 supply, uint256 curveSupply)
        internal
        pure
        returns (uint256 vQ0)
    {
        uint256 scaled = target * (supply - curveSupply);
        if (target == 0 || scaled % curveSupply != 0) revert InvalidTarget();
        vQ0 = scaled / curveSupply;
        if (vQ0 + target > type(uint128).max) revert InvalidTarget();
    }

    /// @notice Spends at most `maxSpend` (curve quote plus fee plus tax) for up to `remaining` tokens.
    function quoteBuy(uint256 vT, uint256 vQ, uint256 remaining, uint256 maxSpend, uint256 feeBps, uint256 taxBps)
        internal
        pure
        returns (Buy memory b)
    {
        if (maxSpend == 0 || maxSpend > type(uint128).max) revert InvalidAmount();
        if (remaining == 0) revert SoldOut();
        uint256 k = vT * vQ;
        uint256 budget = maxSpend * BPS / (BPS + feeBps + taxBps);
        b.tokensOut = vT - Math.ceilDiv(k, vQ + budget);
        if (b.tokensOut > remaining) {
            b.tokensOut = remaining;
            b.curveQuote = Math.ceilDiv(k, vT - remaining) - vQ;
        } else {
            b.curveQuote = budget;
        }
        if (b.tokensOut == 0) revert ZeroOutput();
        b.fee = b.curveQuote * feeBps / BPS;
        b.tax = b.curveQuote * taxBps / BPS;
        // The final fill is exempt: near sellout a buyer can leave so little that any fill's fee rounds
        // to 0, and rejecting it would wedge the curve just short of graduation.
        if (feeBps != 0 && b.fee == 0 && b.tokensOut != remaining) revert DustTrade();
        b.spent = b.curveQuote + b.fee + b.tax;
    }

    /// @notice Sells `amount` tokens; fee and tax come out of the gross quote paid by the curve.
    function quoteSell(uint256 vT, uint256 vQ, uint256 realQuote, uint256 amount, uint256 feeBps, uint256 taxBps)
        internal
        pure
        returns (Sell memory s)
    {
        if (amount == 0) revert InvalidAmount();
        s.gross = vQ - Math.ceilDiv(vT * vQ, vT + amount);
        if (s.gross == 0) revert ZeroOutput();
        if (s.gross > realQuote) revert InsufficientReserve();
        s.fee = s.gross * feeBps / BPS;
        s.tax = s.gross * taxBps / BPS;
        if (feeBps != 0 && s.fee == 0) revert DustTrade();
        s.net = s.gross - s.fee - s.tax;
    }

    /// @notice Tokens that pair with `quoteAmount` at the curve's spot price vQ / vT, rounded down.
    function tokensFor(uint256 quoteAmount, uint256 vT, uint256 vQ) internal pure returns (uint256) {
        return Math.mulDiv(quoteAmount, vT, vQ);
    }

    /// @notice The creator receives its fee share plus the whole tax; protocol takes the remainder.
    function splitFee(uint256 fee, uint256 tax, uint256 creatorShareBps, uint256 buybackShareBps)
        internal
        pure
        returns (uint256 creator, uint256 buyback, uint256 protocol)
    {
        creator = fee * creatorShareBps / BPS + tax;
        buyback = fee * buybackShareBps / BPS;
        protocol = fee + tax - creator - buyback;
    }
}
