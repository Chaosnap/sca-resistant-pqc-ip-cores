-- Copyright (C) 2025 Patrik Dobias <xdobia13@vut.cz>
-- Released for the non-commercial use only. For licensing, please contact <malina@vut.cz>

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.params_pkg.all;
use work.types_pkg.all;
use work.reduce_pkg.all;

-- secure implementation of message decoding
entity sec_decoder is
port (
    clk: in std_logic;
    rst: in std_logic;

    conversion_s_axis_tdata: out slv_array_t(1 downto 0)(95 downto 0);
    conversion_s_axis_tvalid: out std_logic;
    conversion_s_axis_tready: in std_logic;

    conversion_m_axis_tdata: in slv_array_t(1 downto 0)(95 downto 0);
    conversion_m_axis_tvalid: in std_logic;
    conversion_m_axis_tready: out std_logic;

    s_axis_tdata: in slv_array_t(1 downto 0)(95 downto 0);
    s_axis_tvalid: in std_logic;
    s_axis_tready: out std_logic;

    m_axis_tdata: out slv_array_t(1 downto 0)(7 downto 0);
    m_axis_tvalid: out std_logic;
    m_axis_tready: in std_logic
);
end;

architecture behav of sec_decoder is
    -- assigning DON'T TOUCH attribute
    attribute dont_touch: string;
    attribute dont_touch of behav: architecture is "yes";
begin
    conversion_m_axis_tready <= m_axis_tready;

    s_axis_tready <= (not conversion_s_axis_tvalid) or conversion_s_axis_tready;

    out_g: for i in 0 to 7 generate
        m_axis_tdata(0)(i) <= conversion_m_axis_tdata(0)(11 + 12 * i);
        m_axis_tdata(1)(i) <= conversion_m_axis_tdata(1)(11 + 12 * i);
    end generate;

    m_axis_tvalid <= conversion_m_axis_tvalid;

    -- convert arithmetic shares to boolean shares
    conversion_p: process(clk) is
    begin
        if rising_edge(clk) then
            if s_axis_tready = '1' then
                for i in 0 to 7 loop
                    conversion_s_axis_tdata(0)(11 + 12 * i downto 12 * i) <= kyber_sub_reduce(s_axis_tdata(0)(11 + 12 * i downto 12 * i), x"341");
                end loop;

                conversion_s_axis_tdata(1) <= s_axis_tdata(1);
            end if;

            if rst = '1' then
                conversion_s_axis_tvalid <= '0';
            else
                if s_axis_tvalid = '1' then
                    conversion_s_axis_tvalid <= '1';
                elsif conversion_s_axis_tready = '1' then
                    conversion_s_axis_tvalid <= '0';
                end if;
            end if;
        end if;
    end process;
end;
