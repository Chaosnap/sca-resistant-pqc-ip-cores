-- Copyright (C) 2024 Patrik Dobias <xdobia13@vut.cz>
-- Released for the non-commercial use only. For licensing, please contact <malina@vut.cz>

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.params_pkg.all;

entity make_hint is
port (
    clk: in std_logic;
    rst: in std_logic;

    -- determines security level
    mode: in std_logic_vector(1 downto 0);

    coeffs_high_bits: in std_logic_vector(23 downto 0);
    coeffs: in std_logic_vector(95 downto 0);
    coeffs_vld: in std_logic;

    m_axis_tdata: out std_logic_vector(63 downto 0);
    -- indicates validity of hint
    m_axis_tuser: out std_logic;
    m_axis_tvalid: out std_logic;
    m_axis_tready: in std_logic
);
end;

architecture behav of make_hint is
    signal mode_reg: std_logic_vector(1 downto 0);

    signal coeffs_high_bits_reg: std_logic_vector(23 downto 0);
    signal coeffs_reg: std_logic_vector(95 downto 0);
    signal coeffs_vld_shift_reg: std_logic_vector(1 downto 0);

    signal outputing: std_logic;

    signal hints_vld: std_logic_vector(3 downto 0);

    signal hints: std_logic_vector(87 downto 0);
    signal hints_vld_count: unsigned(3 downto 0);

    signal counts: std_logic_vector(63 downto 0);
    signal counts_vld: std_logic; signal counts_index: natural range 0 to 7;
    signal total_count: natural range 0 to 84;

    signal transactions_count, transactions_count_last: natural range 0 to 511;
    signal transactions_last, transactions_second_to_last: std_logic;

    signal invalid: std_logic;

    -- fifo signals
    signal hints_fifo_din: std_logic_vector(63 downto 0);
    signal hints_fifo_din_vld: std_logic;

    signal hints_fifo_dout: std_logic_vector(63 downto 0);
    signal hints_fifo_dout_vld, hints_fifo_dout_rdy: std_logic;
begin
    proc_out: process(all) is
    begin
        if hints_fifo_dout_vld = '1' then
            m_axis_tdata <= hints_fifo_dout;

            if transactions_second_to_last = '1' then
                case mode_reg is
                    when "01" =>
                        m_axis_tdata(63 downto 56) <= counts(7 downto 0);
                    when "10" =>
                        m_axis_tdata(63 downto 24) <= counts(39 downto 0);
                    when others =>
                end case;
            end if;
        else
            m_axis_tdata <= (others => '0');

            case mode_reg is
                when "00" =>
                    if transactions_last = '1' then
                        m_axis_tdata <= counts;
                    end if;
                when "01" =>
                    if transactions_second_to_last = '1' then
                        m_axis_tdata(63 downto 56) <= counts(7 downto 0);
                    elsif transactions_last = '1' then
                        m_axis_tdata(55 downto 0) <= counts(63 downto 8);
                    end if;
                when "10" =>
                    if transactions_second_to_last = '1' then
                        m_axis_tdata(63 downto 24) <= counts(39 downto 0);
                    elsif transactions_last = '1' then
                        m_axis_tdata(23 downto 0) <= counts(63 downto 40);
                    end if;
                when others =>
            end case;
        end if;
    end process;

    m_axis_tuser <= invalid;
    m_axis_tvalid <= outputing;

    hints_fifo: entity work.small_fifo
    generic map (
        DATA_WIDTH => 64,
        DATA_DEPTH => 64
    )
    port map (
        clk => clk,
        rst => rst or (invalid and outputing),

        din => hints_fifo_din,
        din_vld => hints_fifo_din_vld,

        dout => hints_fifo_dout,
        dout_vld => hints_fifo_dout_vld,
        dout_rdy => hints_fifo_dout_rdy
    );

    hints_fifo_din <= hints(63 downto 0);
    hints_fifo_din_vld <= hints_vld_count(3) or outputing when hints_vld_count /= 0 else '0';

    hints_fifo_dout_rdy <= m_axis_tready when outputing = '1' else '0';

    proc_hints: process(clk) is
        variable x: signed(23 downto 0);
        variable bound: unsigned(19 downto 0);
        variable index: natural range 0 to 22;
    begin
        if rising_edge(clk) then
            if mode /= "00" then
                -- (Q - 1) // 32 + 1
                bound := x"3ff01";
            else
                -- -(Q - 1) // 88 + Q + 1
                bound := x"17401";
            end if;

            if coeffs_vld_shift_reg(1) = '1' then
                for i in 0 to 3 loop
                    x := signed(coeffs_reg(23 + 24 * i downto 24 * i));

                    if x(22) = '1' then
                        x := signed(DILITHIUM_Q) - x;
                    end if;

                    x := x - signed(bound);

                    if x(23) = '0' then
                        hints_vld(i) <= '1';
                    elsif coeffs_reg(22 + 24 * i) = '1' and x = -1 then
                        hints_vld(i) <= '1' when coeffs_high_bits_reg(5 + 6 * i downto 6 * i) /= "000000" else '0';
                    else
                        hints_vld(i) <= '0';
                    end if;
                end loop;
            end if;

            if hints_fifo_din_vld = '1' then
                hints <= (others => '0');

                if invalid = '0' then
                    case hints_vld_count(1 downto 0) is
                        when "01" => hints(7 downto 0) <= hints(71 downto 64);
                        when "10" => hints(15 downto 0) <= hints(79 downto 64);
                        when "11" => hints(23 downto 0) <= hints(87 downto 64);
                        when others =>
                    end case;
                end if;
            end if;

            if coeffs_vld_shift_reg(0) = '1' then
                index := to_integer(hints_vld_count(2 downto 0));

                for i in 0 to 3 loop
                    if hints_vld(i) = '1' then
                        hints(7 + 8 * index downto 8 * index) <= std_logic_vector(to_unsigned(4 * (transactions_count mod 64) + i, 8));

                        index := index + 1;
                    end if;
                end loop;
            end if;

            if rst = '1' then
                hints_vld_count <= (others => '0');
                total_count <= 0;
            else
                if (outputing and (not hints_vld_count(3) or invalid)) = '1' then
                    hints_vld_count <= (others => '0');
                end if;

                if (outputing and m_axis_tready) = '1' then
                    total_count <= 0;
                end if;

                if coeffs_vld_shift_reg(0) = '1' then
                    case hints_vld is
                        when "0001" | "0010" | "0100" | "1000" =>
                            hints_vld_count <= hints_vld_count + 1;
                            if invalid = '0' then
                                total_count <= total_count + 1;
                            end if;
                        when "0011" | "0101" | "1001" | "0110" | "1010" | "1100" =>
                            hints_vld_count <= hints_vld_count + 2;
                            if invalid = '0' then
                                total_count <= total_count + 2;
                            end if;
                        when "0111" | "1011" | "1101" | "1110" =>
                            hints_vld_count <= hints_vld_count + 3;
                            if invalid = '0' then
                                total_count <= total_count + 3;
                            end if;
                        when "1111" =>
                            hints_vld_count <= hints_vld_count + 4;
                            if invalid = '0' then
                                total_count <= total_count + 4;
                            end if;
                        when others =>
                    end case;
                end if;

                if hints_fifo_din_vld = '1' then
                    hints_vld_count(3) <= '0';
                end if;
            end if;
        end if;
    end process;

    proc_counts: process(clk) is
    begin
        if rising_edge(clk) then
            if rst = '1' then
                counts <= (others => '0');
                counts_vld <= '0';
                counts_index <= 0;
            else
                if (outputing and transactions_last and m_axis_tready) = '1' then
                    counts <= (others => '0');
                    counts_index <= 0;
                elsif counts_vld = '1' then
                    counts(7 + 8 * counts_index downto 8 * counts_index) <= std_logic_vector(to_unsigned(total_count, 8));

                    if counts_index < 7 then
                        counts_index <= counts_index + 1;
                    end if;
                end if;

                if coeffs_vld_shift_reg(0) = '1' and transactions_count mod 64 = 63 then
                    counts_vld <= '1';
                else
                    counts_vld <= '0';
                end if;
            end if;
        end if;
    end process;

    proc_invalid: process(all) is
    begin
        invalid <= '0';

        case mode_reg is
            when "00" => if total_count > 80 then invalid <= '1'; end if;
            when "01" => if total_count > 55 then invalid <= '1'; end if;
            when "10" => if total_count > 75 then invalid <= '1'; end if;
            when others =>
        end case;
    end process;

    with outputing & mode_reg select transactions_count_last <=
        255 when "000",
        383 when "001",
        511 when "010",
        10 when "100",
        7 when "101",
        10 when "110",
        255 when others;

    transactions_last <= '1' when transactions_count = transactions_count_last else invalid and outputing;
    transactions_second_to_last <= '1' when transactions_count = transactions_count_last - 1 else '0';

    process(clk) is
    begin
        if rising_edge(clk) then
            coeffs_vld_shift_reg <= coeffs_vld & coeffs_vld_shift_reg(coeffs_vld_shift_reg'left downto 1);

            if coeffs_vld = '1' then
                coeffs_high_bits_reg <= coeffs_high_bits;
                coeffs_reg <= coeffs;
                mode_reg <= mode;
            end if;

            if rst = '1' then
                outputing <= '0';

                transactions_count <= 0;
            else
                if ((not outputing and coeffs_vld_shift_reg(0)) or (outputing and m_axis_tready)) = '1' then
                    if transactions_last = '1' then
                        outputing <= not outputing;

                        transactions_count <= 0;
                    else
                        transactions_count <= transactions_count + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;
end;
