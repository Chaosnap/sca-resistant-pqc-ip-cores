-- Copyright (C) 2025 Patrik Dobias <xdobia13@vut.cz>
-- Released for the non-commercial use only. For licensing, please contact <malina@vut.cz>

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.reduce_pkg.all;
use work.types_pkg.all;

-- a2b and b2a conversions
entity sec_conversion is
port (
    clk: in std_logic;
    rst: in std_logic;

    -- 378b randomness for `sec_add_0`, 350b randomness for `sec_add_1` and 2x24b for initial refreshes
    random: in std_logic_vector(775 downto 0);
    -- 0 - a2b => Z_2^k, 1 -> b2a => Z_q
    random_mode: out std_logic;

    -- 3 downto 2 indicates security level
    -- 1 downto 0 indicates type of bound check
    -- "00" -> gamma1 - beta
    -- "01" -> gamma2 - beta
    -- "10" -> gamma2
    -- "11" -> no bound check
    -- valid with `s_axis_tvalid`
    bound_check_mode: in std_logic_vector(3 downto 0) := "1100";

    s_axis_tdata: in slv_array_t(1 downto 0)(95 downto 0);
    -- "0000" -> kyber a2b
    -- "0100" -> kyber b2a
    -- "1000" -> dilithium a2b
    -- "1001" -> dilithium a2b (no modular reduction)
    -- "1100" -> dilithium b2a
    s_axis_tuser: in std_logic_vector(3 downto 0);
    s_axis_tvalid: in std_logic;
    s_axis_tready: out std_logic;

    m_axis_tdata: out slv_array_t(1 downto 0)(95 downto 0);
    -- copies `s_axis_tuser`
    m_axis_tuser: out std_logic_vector(3 downto 0);
    m_axis_tvalid: out std_logic;
    m_axis_tready: in std_logic
);
end;

architecture behav of sec_conversion is
    signal coeffs_in: slv_array_t(1 downto 0)(95 downto 0);
    signal coeffs_in_mode: std_logic_vector(3 downto 0);
    signal coeffs_in_vld, coeffs_in_next: std_logic;

    signal bound_check_mode_r: std_logic_vector(3 downto 0);

    signal coeffs_fifo_din, coeffs_fifo_dout: std_logic_vector(195 downto 0);
    signal coeffs_fifo_din_vld, coeffs_fifo_dout_vld, coeffs_fifo_dout_rdy, coeffs_fifo_afull: std_logic;

    signal coeffs_in_index, coeffs_out_index: natural range 0 to 3;

    signal coeff_in: slv_array_t(1 downto 0)(23 downto 0);
    signal coeff_in_mode: std_logic_vector(3 downto 0);
    signal coeff_in_vld: std_logic;

    signal coeff_out: slv_array_t(1 downto 0)(23 downto 0);
    signal coeff_out_mode: std_logic_vector(3 downto 0);
    signal coeff_out_vld: std_logic;

    signal pending_transactions: natural range 0 to 63;
    signal has_pending_transactions: std_logic;

    -- assigning DON'T TOUCH attribute
    attribute dont_touch: string;
    attribute dont_touch of behav: architecture is "yes";

    component sec_conversion_internal is
    port (
        clk: in std_logic;
        rst: in std_logic;

        random: in std_logic_vector(775 downto 0);

        bound_check_mode: in std_logic_vector(3 downto 0) := "1100";

        coeff_in: in slv_array_t(1 downto 0)(23 downto 0);
        coeff_in_mode: in std_logic_vector(3 downto 0);
        coeff_in_vld: in std_logic;

        coeff_out: out slv_array_t(1 downto 0)(23 downto 0);
        coeff_out_mode: out std_logic_vector(3 downto 0);
        coeff_out_vld: out std_logic
    );
    end component;

    attribute dont_touch of sec_conversion_internal: component is "yes";
begin
    random_mode <= coeff_in_mode(2);

    s_axis_tready <= (not coeffs_in_vld) or coeffs_in_next;

    m_axis_tdata <= (0 => coeffs_fifo_dout(95 downto 0), 1 => coeffs_fifo_dout(191 downto 96));
    m_axis_tuser <= coeffs_fifo_dout(195 downto 192);
    m_axis_tvalid <= coeffs_fifo_dout_vld;

    coeffs_fifo: entity work.small_fifo
    generic map (
        -- 95 downto 0 -> 0 share
        -- 191 downto 96 -> 1 share
        -- 195 downto 192 -> mode
        DATA_WIDTH => 196,
        DATA_DEPTH => 64,
        ALMOST_FULL_OFFSET => 26, -- 2x `SEC_ADD_DELAY` in `sec_conversion_internal`
        OUT_REG => false
    )
    port map (
        clk => clk,
        rst => rst,

        din => coeffs_fifo_din,
        din_vld => coeffs_fifo_din_vld,

        dout => coeffs_fifo_dout,
        dout_vld => coeffs_fifo_dout_vld,
        dout_rdy => coeffs_fifo_dout_rdy,

        afull => coeffs_fifo_afull
    );

    coeffs_fifo_dout_rdy <= m_axis_tready;

    -- registering, so it can be read in multiple cycles
    coeffs_in_p: process(clk) is
    begin
        if rising_edge(clk) then
            if ((not coeffs_in_vld) or coeffs_in_next) = '1' then
                coeffs_in <= s_axis_tdata;
                coeffs_in_mode <= s_axis_tuser;
                bound_check_mode_r <= bound_check_mode;
            end if;

            if rst = '1' then
                coeffs_in_vld <= '0';
            else
                if s_axis_tvalid = '1' then
                    coeffs_in_vld <= '1';
                elsif coeffs_in_next = '1' then
                    coeffs_in_vld <= '0';
                end if;
            end if;
        end if;
    end process;

    coeffs_in_next <= (not coeffs_fifo_afull) when coeffs_in_index = 3 else '0';

    coeffs_p: process(clk) is
    begin
        if rising_edge(clk) then
            coeffs_fifo_din(23 + 24 * coeffs_out_index downto 24 * coeffs_out_index) <= coeff_out(0);
            coeffs_fifo_din(23 + 24 * (coeffs_out_index + 4) downto 24 * (coeffs_out_index + 4)) <= coeff_out(1);

            coeffs_fifo_din(195 downto 192) <= coeff_out_mode;

            if rst = '1' then
                coeffs_fifo_din_vld <= '0';
            else
                if coeffs_out_index = 3 then
                    coeffs_fifo_din_vld <= coeff_out_vld;
                else
                    coeffs_fifo_din_vld <= '0';
                end if;
            end if;
        end if;
    end process;

    -- for lower area utilization one coefficient is processed each cycle, but input/output has 4 dilithium or 8 kyber coefficients
    -- we need to keep track of what coefficient to process
    coeff_index_p: process(clk) is
    begin
        if rising_edge(clk) then
            if rst = '1' then
                coeffs_in_index <= 0;
                coeffs_out_index <= 0;
            else
                if coeff_in_vld = '1' then
                    if coeffs_in_index = 3 then
                        coeffs_in_index <= 0;
                    else
                        coeffs_in_index <= coeffs_in_index + 1;
                    end if;
                end if;

                if coeff_out_vld = '1' then
                    if coeffs_out_index = 3 then
                        coeffs_out_index <= 0;
                    else
                        coeffs_out_index <= coeffs_out_index + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    has_pending_transactions <= '0' when pending_transactions = 0 else '1';

    -- internal pipeline for a2b without modular reduction is half of the remaining conversions, so make sure that there are no data in internal path before using a2b without modular reduction
    pending_transactions_p: process(clk) is
    begin
        if rising_edge(clk) then
            if rst = '1' then
                pending_transactions <= 0;
            else
                if coeff_in_mode /= "1001" and coeff_in_vld = '1' and (coeff_out_mode = "1001" or coeff_out_vld = '0') then
                    pending_transactions <= pending_transactions + 1;
                elsif coeff_out_mode /= "1001" and coeff_out_vld = '1' and (coeff_in_mode = "1001" or coeff_in_vld = '0') then
                    pending_transactions <= pending_transactions - 1;
                end if;
            end if;
        end if;
    end process;

    sec_conversion_internal_i: entity work.sec_conversion_internal
    port map (
        clk => clk,
        rst => rst,

        random => random,
        random_q => random(23 downto 0),

        bound_check_mode => bound_check_mode_r,

        coeff_in => coeff_in,
        coeff_in_mode => coeff_in_mode,
        coeff_in_vld => coeff_in_vld,

        coeff_out => coeff_out,
        coeff_out_mode => coeff_out_mode,
        coeff_out_vld => coeff_out_vld
    );

    coeff_in(0) <= coeffs_in(0)(23 + 24 * coeffs_in_index downto 24 * coeffs_in_index);
    coeff_in(1) <= coeffs_in(1)(23 + 24 * coeffs_in_index downto 24 * coeffs_in_index);
    coeff_in_mode <= coeffs_in_mode;
    coeff_in_vld <= coeffs_in_vld and (not coeffs_fifo_afull) and (not has_pending_transactions) when coeff_in_mode = "1001" else coeffs_in_vld and (not coeffs_fifo_afull);
end;
