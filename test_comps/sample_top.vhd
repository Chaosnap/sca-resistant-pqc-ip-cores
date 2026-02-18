library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.types_pkg.all;

entity sample_top is
port (
    clk: in std_logic;
    rst: in std_logic;

    -- 776b for `sec_conversion`
    sec_conversion_random: in std_logic_vector(775 downto 0);
    -- 0 - a2b => Z_2^k, 1 -> b2a => Z_q
    sec_conversion_random_mode: out std_logic;
    other_random: in std_logic_vector(24 downto 0);

    -- 0 - sample bounded ETA=2 - input shake-256
    -- 1 - sample bounded ETA=4 - input shake-256
    -- must be valid during whole computation
    mode: in std_logic;

    s_axis_tdata: in slv_array_t(1 downto 0)(63 downto 0);
    s_axis_tuser: in std_logic_vector(2 downto 0);
    s_axis_tvalid: in std_logic;
    s_axis_tready: out std_logic;

    m_axis_tdata: out slv_array_t(1 downto 0)(95 downto 0);
    m_axis_tuser: out std_logic_vector(2 downto 0);
    m_axis_tlast: out std_logic;
    m_axis_tvalid: out std_logic;
    m_axis_tready: in std_logic
);
end;

architecture behav of sample_top is
    signal sec_conversion_s_axis_tdata: slv_array_t(1 downto 0)(95 downto 0);
    signal sec_conversion_s_axis_tuser: std_logic_vector(3 downto 0);
    signal sec_conversion_s_axis_tvalid, sec_conversion_s_axis_tready: std_logic;

    signal sec_conversion_m_axis_tdata: slv_array_t(1 downto 0)(95 downto 0);
    signal sec_conversion_m_axis_tuser: std_logic_vector(3 downto 0);
    signal sec_conversion_m_axis_tvalid, sec_conversion_m_axis_tready: std_logic;
begin
    sec_conversion: entity work.sec_conversion
    port map (
        clk => clk,
        rst => rst or (m_axis_tvalid and m_axis_tready and m_axis_tlast),

        random => sec_conversion_random,
        random_mode => sec_conversion_random_mode,

        s_axis_tdata => sec_conversion_s_axis_tdata,
        s_axis_tuser => sec_conversion_s_axis_tuser,
        s_axis_tvalid => sec_conversion_s_axis_tvalid,
        s_axis_tready => sec_conversion_s_axis_tready,

        m_axis_tdata => sec_conversion_m_axis_tdata,
        m_axis_tuser => sec_conversion_m_axis_tuser,
        m_axis_tvalid => sec_conversion_m_axis_tvalid,
        m_axis_tready => sec_conversion_m_axis_tready
    );

    sample: entity work.sample
    port map (
        clk => clk,
        rst => rst or (m_axis_tvalid and m_axis_tready and m_axis_tlast),

        random => other_random,

        mode => mode,

        sec_conversion_s_axis_tdata => sec_conversion_s_axis_tdata,
        sec_conversion_s_axis_tuser => sec_conversion_s_axis_tuser,
        sec_conversion_s_axis_tvalid => sec_conversion_s_axis_tvalid,
        sec_conversion_s_axis_tready => sec_conversion_s_axis_tready,

        sec_conversion_m_axis_tdata => sec_conversion_m_axis_tdata,
        sec_conversion_m_axis_tuser => sec_conversion_m_axis_tuser,
        sec_conversion_m_axis_tvalid => sec_conversion_m_axis_tvalid,
        sec_conversion_m_axis_tready => sec_conversion_m_axis_tready,

        s_axis_tdata => s_axis_tdata,
        s_axis_tuser => s_axis_tuser,
        s_axis_tvalid => s_axis_tvalid,
        s_axis_tready => s_axis_tready,

        m_axis_tdata => m_axis_tdata,
        m_axis_tuser => m_axis_tuser,
        m_axis_tlast => m_axis_tlast,
        m_axis_tvalid => m_axis_tvalid,
        m_axis_tready => m_axis_tready
    );
end;
