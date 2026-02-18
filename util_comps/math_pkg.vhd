-- Copyright (C) 2024 Patrik Dobias <xdobia13@vut.cz>
-- Released for the non-commercial use only. For licensing, please contact <malina@vut.cz>

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

package math_pkg is
    function log2(x: natural) return natural;

    type numbers_array is array(integer range <>) of natural;
end;

package body math_pkg is
    function log2(x: natural) return natural is
    begin
        return natural(ceil(log2(real(x))));
    end function;
end;
