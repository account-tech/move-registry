/// Copied from https://github.com/interest-protocol/suitears

module account_dao::math {
        /*
     * @notice It performs `x` * `y` / `z` rounding down.
     *
     * @dev It will throw on zero division.
     *
     * @param x The first operand.
     * @param y The second operand.
     * @param z The divisor.
     * @return u256. The result of `x` * `y` / `z`.
     */
    public fun mul_div_down(x: u64, y: u64, z: u64): u64 {
        ((x as u256) * (y as u256) / (z as u256)) as u64
    }

    /*
     * @notice Returns the log2(x) rounding down.
     *
     * @param x The operand.
     * @return u256. Log2(x).
     */
    public fun log2_down(mut x: u256): u8 {
        let mut result = 0;
        if (x >> 128 > 0) {
            x = x >> 128;
            result = result + 128;
        };

        if (x >> 64 > 0) {
            x = x >> 64;
            result = result + 64;
        };

        if (x >> 32 > 0) {
            x = x >> 32;
            result = result + 32;
        };

        if (x >> 16 > 0) {
            x = x >> 16;
            result = result + 16;
        };

        if (x >> 8 > 0) {
            x = x >> 8;
            result = result + 8;
        };

        if (x >> 4 > 0) {
            x = x >> 4;
            result = result + 4;
        };

        if (x >> 2 > 0) {
            x = x >> 2;
            result = result + 2;
        };

        if (x >> 1 > 0) result = result + 1;

        result
    }

    /*
     * @notice It returns the lowest number.
     *
     * @param x The first operand.
     * @param y The second operand.
     * @return u256. The lowest number.
     */
    public fun min(x: u64, y: u64): u64 {
        if (x < y) x else y
    }

    /*
     * @notice Returns the square root of a number. If the number is not a perfect square, the x is rounded down.
     *
     * @dev Inspired by Henry S. Warren, Jr.'s "Hacker's Delight" (Chapter 11).
     *
     * @param x The operand.
     * @return u256. The square root of x rounding down.
     */
    public fun sqrt_down(x: u64): u64 {
        if (x == 0) return 0;

        let mut result = 1 << ((log2_down(x as u256) >> 1) as u8);

        result = (result + x / result) >> 1;
        result = (result + x / result) >> 1;
        result = (result + x / result) >> 1;
        result = (result + x / result) >> 1;
        result = (result + x / result) >> 1;
        result = (result + x / result) >> 1;
        result = (result + x / result) >> 1;

        min(result, x / result)
    }
}