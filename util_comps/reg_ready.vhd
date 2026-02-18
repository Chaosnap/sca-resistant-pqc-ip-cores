-- Copyright (C) 2024 Patrik Dobias <xdobia13@vut.cz>
-- Released for the non-commercial use only. For licensing, please contact <malina@vut.cz>

library ieee;
use ieee.std_logic_1164.all;

entity reg_ready is
generic (
    DATA_WIDTH: natural;
    USER_WIDTH: natural := 0
);
port (
    clk: in std_logic;
    rst: in std_logic;

    s_axis_tdata: in std_logic_vector(DATA_WIDTH - 1 downto 0);
    s_axis_tuser: in std_logic_vector(USER_WIDTH - 1 downto 0) := (others => '0');
    s_axis_tvalid: in std_logic;
    s_axis_tready: out std_logic;

    m_axis_tdata: out std_logic_vector(DATA_WIDTH - 1 downto 0);
    m_axis_tuser: out std_logic_vector(USER_WIDTH - 1 downto 0);
    m_axis_tvalid: out std_logic;
    m_axis_tready: in std_logic
);
end;

architecture behav of reg_ready is
    signal reg_tdata: std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal reg_tuser: std_logic_vector(USER_WIDTH - 1 downto 0);
    signal reg_tvalid: std_logic;
begin
    s_axis_tready <= not reg_tvalid;

    m_axis_tdata <= reg_tdata when reg_tvalid = '1' else s_axis_tdata;
    m_axis_tuser <= reg_tuser when reg_tvalid = '1' else s_axis_tuser;
    m_axis_tvalid <= reg_tvalid or s_axis_tvalid;

    process(clk) is
    begin
        if rising_edge(clk) then
            if (s_axis_tvalid and not reg_tvalid and not m_axis_tready) = '1' then
                reg_tdata <= s_axis_tdata;
                reg_tuser <= s_axis_tuser;
            end if;

            if rst = '1' then
                reg_tvalid <= '0';
            else
                if (s_axis_tvalid and not m_axis_tready) = '1' then
                    reg_tvalid <= '1';
                elsif m_axis_tready = '1' then
                    reg_tvalid <= '0';
                end if;
            end if;
        end if;
    end process;
end;
