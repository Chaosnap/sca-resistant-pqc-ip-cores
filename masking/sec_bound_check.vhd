-- Copyright (C) 2025 Patrik Dobias <xdobia13@vut.cz>
-- Released for the non-commercial use only. For licensing, please contact <malina@vut.cz>

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.params_pkg.all;
use work.types_pkg.all;
use work.reduce_pkg.all;

-- secure implementation of bound check
entity sec_bound_check is
generic (
    SIMULATION: boolean := false
);
port (
    clk: in std_logic;
    rst: in std_logic;

    -- interface for mask conversions to enable efficient sharing
    conversion_bound_check_mode: out std_logic_vector(3 downto 0);

    conversion_s_axis_tdata: out slv_array_t(1 downto 0)(95 downto 0);
    conversion_s_axis_tvalid: out std_logic;
    conversion_s_axis_tready: in std_logic;

    conversion_m_axis_tdata: in slv_array_t(1 downto 0)(95 downto 0);
    conversion_m_axis_tvalid: in std_logic;

    s_axis_tdata: in slv_array_t(1 downto 0)(95 downto 0);
    -- 3 downto 2 indicates security level
    -- 1 downto 0 indicates type of bound check
    -- 00 - z ≥ gamma1 - beta
    -- 01 - r0 ≥ gamma2 - beta
    -- 10 - ct0 ≥ gamma2
    s_axis_tuser: in std_logic_vector(3 downto 0);
    s_axis_tvalid: in std_logic;
    s_axis_tready: out std_logic;

    -- indicates coefficient failing bound check
    invalid: out std_logic;
    invalid_vld: out std_logic
);
end;

architecture behav of sec_bound_check is
    constant SEC_ADD_DELAY: natural := 13;

    -- only for simulation
    signal debug_invalid: natural range 0 to 4;

    signal mode_fifo_dout: std_logic_vector(3 downto 0);
    signal mode_shift_reg: slv_array_t(SEC_ADD_DELAY - 1 downto 0)(3 downto 0);

    signal transactions_count, transactions_count_last: natural range 0 to 2047;
    signal transactions_last: std_logic;

    -- assigning DON'T TOUCH attribute
    attribute dont_touch: string;
    attribute dont_touch of behav: architecture is "yes";
begin
    s_axis_tready <= (not conversion_s_axis_tvalid) or conversion_s_axis_tready;

    mode_fifo: entity work.small_fifo
    generic map (
        DATA_WIDTH => 4,
        DATA_DEPTH => 64
    ) port map (
        clk => clk,
        rst => rst,

        din => s_axis_tuser,
        din_vld => s_axis_tvalid and s_axis_tready,

        dout => mode_fifo_dout,
        dout_vld => open, -- will be always valid when needed,
        dout_rdy => conversion_m_axis_tvalid
    );

    -- convert arithmetic shares to boolean shares
    conversion_p: process(clk) is
        variable bound: std_logic_vector(23 downto 0);
    begin
        if rising_edge(clk) then
            if ((not conversion_s_axis_tvalid) or conversion_s_axis_tready) = '1' then
                -- add (bound - 1) to the coefficient, so we need to check if subtracting 2*bound will result into negative number
                case s_axis_tuser(1 downto 0) is
                    when "00" => bound := std_logic_vector_for_sec_level(s_axis_tuser(3 downto 2), x"01ffb1", x"07ff3b", x"07ff87");
                    when "01" => bound := std_logic_vector_for_sec_level(s_axis_tuser(3 downto 2), x"0173b1", x"03fe3b", x"03fe87");
                    when others=> bound := std_logic_vector_for_sec_level(s_axis_tuser(3 downto 2), x"0173ff", x"03feff", x"03feff");
                end case;

                for i in 0 to 3 loop
                    conversion_s_axis_tdata(0)(23 + 24 * i downto 24 * i) <= dilithium_add_reduce(s_axis_tdata(0)(23 + 24 * i downto 24 * i), bound);
                end loop;

                conversion_s_axis_tdata(1) <= s_axis_tdata(1);
                conversion_bound_check_mode <= s_axis_tuser;
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

    mode_shift_reg_p: process(clk) is
    begin
        if rising_edge(clk) then
            if rst = '1' then
                mode_shift_reg <= (others => "0000");
            else
                mode_shift_reg <= mode_fifo_dout & mode_shift_reg(mode_shift_reg'left downto 1);
            end if;
        end if;
    end process;

    with mode_fifo_dout select transactions_count_last <=
        255 when "0000",
        319 when "0100",
        447 when "1000",
        255 when "0001" | "0010",
        383 when "0101" | "0110",
        511 when "1001" | "1010",
        0 when others;

    transactions_last <= '1' when transactions_count = transactions_count_last else '0';

    process(clk) is
        variable x: natural range 0 to 4;
    begin
        if rising_edge(clk) then
            if SIMULATION then
                x := 0;

                for i in 0 to 3 loop
                    if (conversion_m_axis_tvalid and (not (conversion_m_axis_tdata(0)(23 + 24 * i) xor conversion_m_axis_tdata(1)(23 + 24 * i)))) = '1' then
                        x := x + 1;
                    end if;
                end loop;

                debug_invalid <= x;
            end if;

            if (rst or invalid_vld) = '1' then
                invalid <= '0';
                invalid_vld <= '0';

                transactions_count <= 0;
            elsif conversion_m_axis_tvalid = '1' then
                for i in 0 to 3 loop
                    if (conversion_m_axis_tdata(0)(23 + 24 * i) xor conversion_m_axis_tdata(1)(23 + 24 * i)) = '0' then
                        invalid <= '1';
                    end if;
                end loop;

                if transactions_last = '1' then
                    invalid_vld <= '1';

                    transactions_count <= 0;
                else
                    transactions_count <= transactions_count + 1;
                end if;
            end if;
        end if;
    end process;
end;
