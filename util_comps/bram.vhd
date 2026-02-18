-- Copyright (C) 2024 Patrik Dobias <xdobia13@vut.cz>
-- Released for the non-commercial use only. For licensing, please contact <malina@vut.cz>

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.math_pkg.all;

entity bram is
generic (
    DATA_WIDTH: natural := 64;
    DATA_DEPTH: natural := 64;
    OUT_DELAY: natural := 2
);
port (
    clk: in std_logic;

    DEBUG_DATA: out std_logic_vector(DATA_WIDTH - 1 downto 0) := (others => '0');
    DEBUG_ADDR: in std_logic_vector(log2(DATA_DEPTH) - 1 downto 0) := (others => '0');

    wea: in std_logic;
    reb: in std_logic;

    dina: in std_logic_vector(DATA_WIDTH - 1 downto 0);
    doutb: out std_logic_vector(DATA_WIDTH - 1 downto 0);

    addra: in std_logic_vector(log2(DATA_DEPTH) - 1 downto 0);
    addrb: in std_logic_vector(log2(DATA_DEPTH) - 1 downto 0)
);
end;

architecture behav of bram is
    type data_t is array(integer range <>) of std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal data: data_t(DATA_DEPTH - 1 downto 0);

    signal data_shift_reg: data_t(OUT_DELAY - 1 downto 0);
begin
    DEBUG_DATA <= data(to_integer(unsigned(DEBUG_ADDR)));

    doutb <= data_shift_reg(0);

    process(clk) is
    begin
        if rising_edge(clk) then
            if wea = '1' then
                data(to_integer(unsigned(addra))) <= dina;
            end if;

            if reb = '1' then
                data_shift_reg(data_shift_reg'left) <= data(to_integer(unsigned(addrb)));
            end if;

            data_shift_reg(data_shift_reg'left - 1 downto 0) <= data_shift_reg(data_shift_reg'left downto 1);
        end if;
    end process;
end;