library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity decode_encode_top is
port (
    clk: in std_logic;
    rst: in std_logic;

    dec_mode: in std_logic_vector(3 downto 0);
    dec_mode_vld: in std_logic;
    dec_mode_next: out std_logic;

    enc_mode: in std_logic_vector(3 downto 0);
    enc_mode_vld: in std_logic;
    enc_mode_next: out std_logic;

    s_axis_tdata: in std_logic_vector(63 downto 0);
    s_axis_tvalid: in std_logic;
    s_axis_tready: out std_logic;

    m_axis_tdata: out std_logic_vector(63 downto 0);
    m_axis_tvalid: out std_logic;
    m_axis_tready: in std_logic
);
end;

architecture behav of decode_encode_top is
    signal coeffs_tdata: std_logic_vector(95 downto 0);
    signal coeffs_tvalid, coeffs_tready: std_logic;
begin
    decode: entity work.decode
    port map (
        clk => clk,
        rst => rst,

        s_axis_tdata => s_axis_tdata,
        s_axis_tuser => dec_mode,
        s_axis_tvalid => s_axis_tvalid,
        s_axis_tready => s_axis_tready,

        m_axis_tdata => coeffs_tdata,
        m_axis_tvalid => coeffs_tvalid,
        m_axis_tready => coeffs_tready
    );

    encode: entity work.encode
    port map (
        clk => clk,
        rst => rst,

        s_axis_tdata => coeffs_tdata,
        s_axis_tuser => enc_mode,
        s_axis_tvalid => coeffs_tvalid,
        s_axis_tready => coeffs_tready,

        m_axis_tdata => m_axis_tdata,
        m_axis_tvalid => m_axis_tvalid,
        m_axis_tready => m_axis_tready
    );
end;