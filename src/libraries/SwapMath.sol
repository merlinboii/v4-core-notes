// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {FullMath} from "./FullMath.sol";
import {SqrtPriceMath} from "./SqrtPriceMath.sol";

/// @title Computes the result of a swap within ticks
/// @notice Contains methods for computing the result of a swap within a single tick price range, i.e., a single tick.
library SwapMath {
    /// @notice the swap fee is represented in hundredths of a bip, so the max is 100%
    /// @dev the swap fee is the total fee on a swap, including both LP and Protocol fee
    uint256 internal constant MAX_SWAP_FEE = 1e6;

    /// @notice Computes the sqrt price target for the next swap step
    /// @param zeroForOne The direction of the swap, true for currency0 to currency1, false for currency1 to currency0
    /// @param sqrtPriceNextX96 The Q64.96 sqrt price for the next initialized tick
    /// @param sqrtPriceLimitX96 The Q64.96 sqrt price limit. If zero for one, the price cannot be less than this value //@note to capture the logic read this
    /// after the swap. If one for zero, the price cannot be greater than this value after the swap
    /// @return sqrtPriceTargetX96 The price target for the next swap step
    function getSqrtPriceTarget(bool zeroForOne, uint160 sqrtPriceNextX96, uint160 sqrtPriceLimitX96)
        internal
        pure
        returns (uint160 sqrtPriceTargetX96)
    {
        assembly ("memory-safe") {
            // a flag to toggle between sqrtPriceNextX96 and sqrtPriceLimitX96
            // when zeroForOne == true, nextOrLimit reduces to sqrtPriceNextX96 >= sqrtPriceLimitX96
            // sqrtPriceTargetX96 = max(sqrtPriceNextX96, sqrtPriceLimitX96)
            // when zeroForOne == false, nextOrLimit reduces to sqrtPriceNextX96 < sqrtPriceLimitX96
            // sqrtPriceTargetX96 = min(sqrtPriceNextX96, sqrtPriceLimitX96)
            sqrtPriceNextX96 := and(sqrtPriceNextX96, 0xffffffffffffffffffffffffffffffffffffffff)   //@note to -> 20 bytes -> 160 bit
            sqrtPriceLimitX96 := and(sqrtPriceLimitX96, 0xffffffffffffffffffffffffffffffffffffffff)
            let nextOrLimit := xor(lt(sqrtPriceNextX96, sqrtPriceLimitX96), and(zeroForOne, 0x1))   //@note xor -> same: 0 -> use Limit, diff:1 -> use Next
            let symDiff := xor(sqrtPriceNextX96, sqrtPriceLimitX96)
            sqrtPriceTargetX96 := xor(sqrtPriceLimitX96, mul(symDiff, nextOrLimit)) //@note keep return as sqrtPriceLimitX96 (nextOrLimit: 0) OR returns sqrtPriceNextX96(nextOrLimit: 1)
        }
    }

    /// @notice Computes the result of swapping some amount in, or amount out, given the parameters of the swap
    /// @dev If the swap's amountSpecified is negative, the combined fee and input amount will never exceed the absolute value of the remaining amount.
    /// @param sqrtPriceCurrentX96 The current sqrt price of the pool
    /// @param sqrtPriceTargetX96 The price that cannot be exceeded, from which the direction of the swap is inferred
    /// @param liquidity The usable liquidity
    /// @param amountRemaining How much input or output amount is remaining to be swapped in/out
    /// @param feePips The fee taken from the input amount, expressed in hundredths of a bip
    /// @return sqrtPriceNextX96 The price after swapping the amount in/out, not to exceed the price target
    /// @return amountIn The amount to be swapped in, of either currency0 or currency1, based on the direction of the swap
    /// @return amountOut The amount to be received, of either currency0 or currency1, based on the direction of the swap
    /// @return feeAmount The amount of input that will be taken as a fee   //@note only collcet fee at `amountIn`
    /// @dev feePips must be no larger than MAX_SWAP_FEE for this function. We ensure that before setting a fee using LPFeeLibrary.isValid.
    function computeSwapStep(
        uint160 sqrtPriceCurrentX96,
        uint160 sqrtPriceTargetX96,
        uint128 liquidity,
        int256 amountRemaining,
        uint24 feePips
    ) internal pure returns (uint160 sqrtPriceNextX96, uint256 amountIn, uint256 amountOut, uint256 feeAmount) {    //@note returns the amountIn/Out based on the available liquidity
        unchecked {
            uint256 _feePips = feePips; // upcast once and cache
            bool zeroForOne = sqrtPriceCurrentX96 >= sqrtPriceTargetX96;    //@note reassign the swap direction
            bool exactIn = amountRemaining < 0;

            if (exactIn) {  //@note amountRemaining = (-)
                uint256 amountRemainingLessFee =    //@note amount extract fee
                    FullMath.mulDiv(uint256(-amountRemaining), MAX_SWAP_FEE - _feePips, MAX_SWAP_FEE);  //@note (+)amountRemaining * (MAX_SWAP_FEE - _feePips: swapFee) / MAX_SWAP_FEE
                amountIn = zeroForOne   //@note RETURN min(amountRemainingLessFee, amountIn);
                    ? SqrtPriceMath.getAmount0Delta(sqrtPriceTargetX96, sqrtPriceCurrentX96, liquidity, true /** round up */)    //@note 0 -> 1 && exact0 => cal amountIn(0) (actual)
                    : SqrtPriceMath.getAmount1Delta(sqrtPriceCurrentX96, sqrtPriceTargetX96, liquidity, true /** round up */);   //@note 1 -> 0 && exact1 => cal amountIn(1) (actual)
                if (amountRemainingLessFee >= amountIn) {   //@note can cover actual amountIn
                    // `amountIn` is capped by the target price
                    sqrtPriceNextX96 = sqrtPriceTargetX96;
                    feeAmount = _feePips == MAX_SWAP_FEE
                        ? amountIn // amountIn is always 0 here, as amountRemainingLessFee == 0 and amountRemainingLessFee >= amountIn
                        : FullMath.mulDivRoundingUp(amountIn, _feePips, MAX_SWAP_FEE - _feePips);
                } else {    //@note amountRemainingLessFee < amountIn (actual)
                    // exhaust the remaining amount
                    amountIn = amountRemainingLessFee;
                    sqrtPriceNextX96 = SqrtPriceMath.getNextSqrtPriceFromInput(
                        sqrtPriceCurrentX96, liquidity, amountRemainingLessFee /**amountIn L77 */, zeroForOne
                    );
                    // we didn't reach the target, so take the remainder of the maximum input as fee
                    feeAmount = uint256(-amountRemaining) - amountIn;
                }
                amountOut = zeroForOne
                    ? SqrtPriceMath.getAmount1Delta(sqrtPriceNextX96, sqrtPriceCurrentX96, liquidity, false /** round down */)    //@note 0 -> 1 && exact0 => cal amountOut(1)
                    : SqrtPriceMath.getAmount0Delta(sqrtPriceCurrentX96, sqrtPriceNextX96, liquidity, false /** round down */);    //@note 1 -> 0 && exact1 => cal amountOut(0)
            } else {    //@note amountRemaining = ()
                amountOut = zeroForOne  //@note RETURN min(amountRemaining, amountOut);
                    ? SqrtPriceMath.getAmount1Delta(sqrtPriceTargetX96, sqrtPriceCurrentX96, liquidity, false) //@note 0 -> 1 && exact1 => cal amountOut(1) (actual)
                    : SqrtPriceMath.getAmount0Delta(sqrtPriceCurrentX96, sqrtPriceTargetX96, liquidity, false); //@note 1 -> 0 && exact0 => cal amountOut(0) (actual)
                if (uint256(amountRemaining) >= amountOut) {    //@note expect exact amount >= the actual output
                    // `amountOut` is capped by the target price
                    sqrtPriceNextX96 = sqrtPriceTargetX96;
                } else {    //@note amountRemaining < amountOut
                    // cap the output amount to not exceed the remaining output amount
                    amountOut = uint256(amountRemaining);
                    sqrtPriceNextX96 =
                        SqrtPriceMath.getNextSqrtPriceFromOutput(sqrtPriceCurrentX96, liquidity, amountOut, zeroForOne);
                }
                amountIn = zeroForOne
                    ? SqrtPriceMath.getAmount0Delta(sqrtPriceNextX96, sqrtPriceCurrentX96, liquidity, true) //@note 0 -> 1 && exact1 => cal amountIn(0)
                    : SqrtPriceMath.getAmount1Delta(sqrtPriceCurrentX96, sqrtPriceNextX96, liquidity, true);    //@note 1 -> 0 && exact0 => cal amountIn(1)
                // `feePips` cannot be `MAX_SWAP_FEE` for exact out
                feeAmount = FullMath.mulDivRoundingUp(amountIn, _feePips, MAX_SWAP_FEE - _feePips);
            }
        }
    }
}
