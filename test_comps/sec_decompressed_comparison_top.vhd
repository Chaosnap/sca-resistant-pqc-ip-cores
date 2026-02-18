library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.types_pkg.all;

entity sec_decompressed_comparison_top is
port (
    clk: in std_logic;
    rst: in std_logic;

    -- 776b for `sec_conversion`
    sec_conversion_random: in std_logic_vector(775 downto 0);
    -- 0 - a2b => Z_2^k, 1 -> b2a => Z_q
    sec_conversion_random_mode: out std_logic;
    other_random: in std_logic_vector(7 downto 0);

    s_axis_tdata: in slv_array_t(1 downto 0)(95 downto 0);
    s_axis_tuser: in std_logic_vector(1 downto 0);
    s_axis_tvalid: in std_logic;
    s_axis_tready: out std_logic;

    invalid: out std_logic;
    invalid_vld: out std_logic
);
end;

architecture behav of sec_decompressed_comparison_top is
    signal conversion_s_axis_tdata: slv_array_t(1 downto 0)(95 downto 0);
    signal conversion_s_axis_tvalid, conversion_s_axis_tready: std_logic;

    signal conversion_m_axis_tdata: slv_array_t(1 downto 0)(95 downto 0);
    signal conversion_m_axis_tvalid: std_logic;
begin
    sec_conversion: entity work.sec_conversion
    port map (
        clk => clk,
        rst => rst,

        random => sec_conversion_random,
        random_mode => sec_conversion_random_mode,

        s_axis_tdata => conversion_s_axis_tdata,
        s_axis_tuser => "0000",
        s_axis_tvalid => conversion_s_axis_tvalid,
        s_axis_tready => conversion_s_axis_tready,

        m_axis_tdata => conversion_m_axis_tdata,
        m_axis_tvalid => conversion_m_axis_tvalid,
        m_axis_tready => '1'
    );

    sec_decompressed_comparison: entity work.sec_decompressed_comparison
    port map (
        clk => clk,
        rst => rst,

        conversion_s_axis_tdata => conversion_s_axis_tdata,
        conversion_s_axis_tvalid => conversion_s_axis_tvalid,
        conversion_s_axis_tready => conversion_s_axis_tready,

        conversion_m_axis_tdata => conversion_m_axis_tdata,
        conversion_m_axis_tvalid => conversion_m_axis_tvalid,

        r => other_random,

        s_axis_tdata => s_axis_tdata,
        s_axis_tuser => s_axis_tuser,
        s_axis_tvalid => s_axis_tvalid,
        s_axis_tready => s_axis_tready,

        invalid => invalid,
        invalid_vld => invalid_vld
    );
end;
