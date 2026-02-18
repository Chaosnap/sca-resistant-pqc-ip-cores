-- Copyright (C) 2024 Patrik Dobias <xdobia13@vut.cz>
-- Released for the non-commercial use only. For licensing, please contact <malina@vut.cz>

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.params_pkg.all;

entity bound_check is
port (
    clk: in std_logic;
    rst: in std_logic;

    -- indicates security level
    mode: in std_logic_vector(1 downto 0);

    coeffs: in std_logic_vector(95 downto 0);
    coeffs_vld: in std_logic;

    -- indicates coefficient passing bound check
    in_bound: out std_logic;
    in_bound_vld: out std_logic
);
end;

architecture behav of bound_check is
    signal mode_reg: std_logic_vector(1 downto 0);
    signal coeffs_reg: std_logic_vector(95 downto 0);
    signal coeffs_vld_reg: std_logic;

    signal transactions_count, transactions_count_last: natural range 0 to 511;
    signal transactions_last: std_logic;

    signal coeffs_in_bound, coeffs_in_bound_vld: std_logic;
begin
    in_bound <= coeffs_in_bound;
    in_bound_vld <= coeffs_in_bound_vld;

    with mode_reg select transactions_count_last <=
        255 when "00",
        319 when "01",
        447 when "10",
        0 when others;

    transactions_last <= '1' when transactions_count = transactions_count_last else '0';

    process(clk) is
        variable x: signed(23 downto 0);
        variable bound: signed(19 downto 0);
    begin
        if rising_edge(clk) then
            coeffs_vld_reg <= coeffs_vld;

            if coeffs_vld = '1' then
                coeffs_reg <= coeffs;
                mode_reg <= mode;
            end if;

            case mode_reg is
                when "00" => bound := x"1ffb2";
                when "01" => bound := x"7ff3c";
                when "10" => bound := x"7ff88";
                when others =>
            end case;

            if rst = '1' then
                coeffs_in_bound <= '1';
                coeffs_in_bound_vld <= '0';

                transactions_count <= 0;
            else
                if coeffs_vld_reg = '1' then
                    for i in 0 to 3 loop
                        x := signed(coeffs_reg(23 + 24 * i downto 24 * i));

                        if x(22) = '1' then
                            x := signed(DILITHIUM_Q) - x;
                        end if;

                        x := x - bound;

                        if x(23) = '0' then
                            coeffs_in_bound <= '0';
                        end if;
                    end loop;

                    if transactions_last = '1' then
                        coeffs_in_bound_vld <= '1';

                        transactions_count <= 0;
                    else
                        transactions_count <= transactions_count + 1;
                    end if;
                end if;

                if coeffs_in_bound_vld = '1' then
                    coeffs_in_bound <= '1';
                    coeffs_in_bound_vld <= '0';
                end if;
            end if;
        end if;
    end process;
end;
