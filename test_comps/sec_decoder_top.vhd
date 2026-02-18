library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.types_pkg.all;

entity sec_decoder_top is
port (
    clk: in std_logic;
    rst: in std_logic;

    -- 776b for `sec_conversion`
    sec_conversion_random: in std_logic_vector(775 downto 0);
    -- 0 - a2b => Z_2^k, 1 -> b2a => Z_q
    sec_conversion_random_mode: out std_logic;

    s_axis_tdata: in slv_array_t(1 downto 0)(95 downto 0);
    s_axis_tvalid: in std_logic;
    s_axis_tready: out std_logic;

    m_axis_tdata: out slv_array_t(1 downto 0)(7 downto 0);
    m_axis_tvalid: out std_logic;
    m_axis_tready: in std_logic
);
end;

architecture behav of sec_decoder_top is
    signal conversion_s_axis_tdata: slv_array_t(1 downto 0)(95 downto 0);
    signal conversion_s_axis_tvalid, conversion_s_axis_tready: std_logic;

    signal conversion_m_axis_tdata: slv_array_t(1 downto 0)(95 downto 0);
    signal conversion_m_axis_tvalid, conversion_m_axis_tready: std_logic;
begin
    sec_conversion: entity work.sec_conversion
    port map (
        clk => clk,
        rst => rst,

        random => sec_conversion_random,
        random_mode => sec_conversion_random_mode,

        bound_check_mode => "0000",

        s_axis_tdata => conversion_s_axis_tdata,
        s_axis_tuser => "0000",
        s_axis_tvalid => conversion_s_axis_tvalid,
        s_axis_tready => conversion_s_axis_tready,

        m_axis_tdata => conversion_m_axis_tdata,
        m_axis_tvalid => conversion_m_axis_tvalid,
        m_axis_tready => conversion_m_axis_tready
    );

    sec_decoder: entity work.sec_decoder
    port map (
        clk => clk,
        rst => rst,

        conversion_s_axis_tdata => conversion_s_axis_tdata,
        conversion_s_axis_tvalid => conversion_s_axis_tvalid,
        conversion_s_axis_tready => conversion_s_axis_tready,

        conversion_m_axis_tdata => conversion_m_axis_tdata,
        conversion_m_axis_tvalid => conversion_m_axis_tvalid,
        conversion_m_axis_tready => conversion_m_axis_tready,

        s_axis_tdata => s_axis_tdata,
        s_axis_tvalid => s_axis_tvalid,
        s_axis_tready => s_axis_tready,

        m_axis_tdata => m_axis_tdata,
        m_axis_tvalid => m_axis_tvalid,
        m_axis_tready => m_axis_tready
    );
end;
