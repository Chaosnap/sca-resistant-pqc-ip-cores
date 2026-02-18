library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.types_pkg.all;

entity sec_decompose_top is
port (
    clk: in std_logic;
    rst: in std_logic;

    -- 776b for `sec_conversion`
    sec_conversion_random: in std_logic_vector(775 downto 0);
    -- 0 - a2b => Z_2^k, 1 -> b2a => Z_q
    sec_conversion_random_mode: out std_logic;
    other_random: in std_logic_vector(5 downto 0);

    s_axis_tdata: in slv_array_t(1 downto 0)(95 downto 0);
    -- 0 -> δ = 44
    -- 1 -> δ = 16
    s_axis_tuser: in std_logic;
    s_axis_tvalid: in std_logic;
    s_axis_tready: out std_logic;

    -- high bits (only 6 bits are needed per coefficient)
    m_axis_tdata: out std_logic_vector(23 downto 0);
    -- low bits
    m_axis_low_bits_tdata: out slv_array_t(1 downto 0)(95 downto 0);
    m_axis_tvalid: out std_logic;
    m_axis_tready: in std_logic
);
end;

architecture behav of sec_decompose_top is
    signal conversion_s_axis_tdata: slv_array_t(1 downto 0)(95 downto 0);
    signal conversion_s_axis_tuser: std_logic_vector(3 downto 0);
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

        s_axis_tdata => conversion_s_axis_tdata,
        s_axis_tuser => conversion_s_axis_tuser,
        s_axis_tvalid => conversion_s_axis_tvalid,
        s_axis_tready => conversion_s_axis_tready,

        m_axis_tdata => conversion_m_axis_tdata,
        m_axis_tvalid => conversion_m_axis_tvalid,
        m_axis_tready => conversion_m_axis_tready
    );

    sec_decompose: entity work.sec_decompose
    port map (
        clk => clk,
        rst => rst,

        random_q => other_random,

        conversion_s_axis_tdata => conversion_s_axis_tdata,
        conversion_s_axis_tuser => conversion_s_axis_tuser,
        conversion_s_axis_tvalid => conversion_s_axis_tvalid,
        conversion_s_axis_tready => conversion_s_axis_tready,

        conversion_m_axis_tdata => conversion_m_axis_tdata,
        conversion_m_axis_tvalid => conversion_m_axis_tvalid,
        conversion_m_axis_tready => conversion_m_axis_tready,

        s_axis_tdata => s_axis_tdata,
        s_axis_tuser => s_axis_tuser,
        s_axis_tvalid => s_axis_tvalid,
        s_axis_tready => s_axis_tready,

        m_axis_tdata => m_axis_tdata,
        m_axis_low_bits_tdata => m_axis_low_bits_tdata,
        m_axis_tvalid => m_axis_tvalid,
        m_axis_tready => m_axis_tready
    );
end;
