-- Copyright (C) 2024 Patrik Dobias <xdobia13@vut.cz>
-- Released for the non-commercial use only. For licensing, please contact <malina@vut.cz>

library ieee;
use ieee.std_logic_1164.all;

package types_pkg is
    type slv_array_t is array (natural range <>) of std_logic_vector;

    function slv_array_ser(x: slv_array_t; ITEMS_X: natural; DATA_WIDTH: natural) return std_logic_vector;

    function slv_array_deser(x: std_logic_vector; ITEMS_X: natural; DATA_WIDTH: natural) return slv_array_t;
end;

package body types_pkg is
    function slv_array_ser(x: slv_array_t; ITEMS_X: natural; DATA_WIDTH: natural) return std_logic_vector is
        variable y: std_logic_vector(ITEMS_X * DATA_WIDTH - 1 downto 0);
    begin
        for i in 0 to ITEMS_X - 1 loop
            y((i + 1) * DATA_WIDTH - 1 downto i * DATA_WIDTH) := x(i);
        end loop;

        return y;
    end function;

    function slv_array_deser(x: std_logic_vector; ITEMS_X: natural; DATA_WIDTH: natural) return slv_array_t is
        variable y: slv_array_t(ITEMS_X - 1 downto 0)(DATA_WIDTH - 1 downto 0);
    begin
        for i in 0 to ITEMS_X - 1 loop
            y(i) := x((i + 1) * DATA_WIDTH - 1 downto i * DATA_WIDTH);
        end loop;

        return y;
    end function;
end;
