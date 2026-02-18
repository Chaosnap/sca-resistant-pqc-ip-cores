-- Copyright (C) 2024 Patrik Dobias <xdobia13@vut.cz>
-- Released for the non-commercial use only. For licensing, please contact <malina@vut.cz>

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity use_hint is
port (
    clk: in std_logic;
    rst: in std_logic;

    -- determines security level
    mode: in std_logic_vector(1 downto 0);

    -- loading hints and then high bits of w1
    -- w1 coeffs 6b, 16th bit indicates how should be hint used
    -- 0 -> add 1, 1 -> sub 1
    s_axis_tdata: in std_logic_vector(63 downto 0);
    s_axis_tvalid: in std_logic;
    s_axis_tready: out std_logic;

    -- w1 coefficients
    m_axis_tdata: out std_logic_vector(23 downto 0);
    m_axis_tvalid: out std_logic;
    m_axis_tready: in std_logic;

    hints_invalid: out std_logic
);
end;

architecture behav of use_hint is
    type array_13b_t is array(integer range <>) of std_logic_vector(12 downto 0);

    signal reg_ready_m_axis_tdata: std_logic_vector(63 downto 0);
    signal reg_ready_m_axis_tvalid, reg_ready_m_axis_tready: std_logic;

    -- fifo signals
    -- 12 downto 6 - hint count
    -- 5 downto 0 - coeff count / 4
    signal hints_fifo_din: array_13b_t(3 downto 0);
    signal hints_fifo_din_vld: std_logic_vector(3 downto 0);

    signal hints_fifo_dout: array_13b_t(3 downto 0);
    signal hints_fifo_dout_vld, hints_fifo_dout_rdy: std_logic_vector(3 downto 0);

    signal invalid: std_logic;
    signal reading_count, outputing: std_logic;

    signal mode_reg: std_logic_vector(1 downto 0);

    signal coeffs: std_logic_vector(23 downto 0);
    signal coeffs_vld: std_logic;

    signal transactions_count, transactions_count_last: natural range 0 to 511;
    signal transactions_last: std_logic;

    signal counts: std_logic_vector(63 downto 0);
    signal counts_index: natural range 0 to 7;
    signal total_count: natural range 0 to 84;
begin
    reg_ready: entity work.reg_ready
    generic map (
        DATA_WIDTH => 64,
        USER_WIDTH => 0
    )
    port map (
        clk => clk,
        rst => (rst or invalid),

        s_axis_tdata => s_axis_tdata,
        s_axis_tuser => (others => '0'),
        s_axis_tvalid => s_axis_tvalid,
        s_axis_tready => s_axis_tready,

        m_axis_tdata => reg_ready_m_axis_tdata,
        m_axis_tuser => open,
        m_axis_tvalid => reg_ready_m_axis_tvalid,
        m_axis_tready => reg_ready_m_axis_tready
    );

    reg_ready_m_axis_tready <= not coeffs_vld or m_axis_tready when outputing = '1' else
        '1' when (transactions_count mod 8) = 7 else
        transactions_last;

    m_axis_tdata <= coeffs;
    m_axis_tvalid <= coeffs_vld;

    hints_invalid <= invalid;

    gen_hints_fifo: for i in 0 to 3 generate
        hints_fifo: entity work.small_fifo
        generic map (
            DATA_WIDTH => 13,
            DATA_DEPTH => 64
        )
        port map (
            clk => clk,
            rst => rst or invalid or (outputing and reg_ready_m_axis_tvalid and (not coeffs_vld or m_axis_tready) and transactions_last),

            din => hints_fifo_din(i),
            din_vld => hints_fifo_din_vld(i),

            dout => hints_fifo_dout(i),
            dout_vld => hints_fifo_dout_vld(i),
            dout_rdy => hints_fifo_dout_rdy(i)
        );

        hints_fifo_din(i) <= std_logic_vector(to_unsigned(transactions_count, 7)) & reg_ready_m_axis_tdata(7 + 8 * (transactions_count mod 8) downto 2 + 8 * (transactions_count mod 8));
        hints_fifo_din_vld(i) <= not outputing and not reading_count and reg_ready_m_axis_tvalid when unsigned(reg_ready_m_axis_tdata(1 + 8 * (transactions_count mod 8) downto 8 * (transactions_count mod 8))) = i else '0';

        hints_fifo_dout_rdy(i) <= outputing and reg_ready_m_axis_tvalid and (not coeffs_vld or m_axis_tready) when unsigned(hints_fifo_dout(i)(5 downto 0)) = (transactions_count mod 64) and unsigned(hints_fifo_dout(i)(12 downto 6)) < unsigned(counts(7 + 8 * counts_index downto 8 * counts_index)) else '0';
    end generate;

    proc_counts: process(clk) is
    begin
        if rising_edge(clk) then
            if (rst or invalid) = '1' then
                counts <= (others => '0');
            else
                if (not outputing and reg_ready_m_axis_tvalid) = '1' then
                    case mode is
                        when "00" => counts(31 downto 0) <= reg_ready_m_axis_tdata(31 downto 0);
                        when "01" =>
                            if reading_count = '0' then
                                counts(7 downto 0) <= reg_ready_m_axis_tdata(63 downto 56);
                            end if;

                            counts(47 downto 8) <= reg_ready_m_axis_tdata(39 downto 0);
                        when others =>
                            if reading_count = '0' then
                                counts(39 downto 0) <= reg_ready_m_axis_tdata(63 downto 24);
                            end if;

                            counts(63 downto 40) <= reg_ready_m_axis_tdata(23 downto 0);
                    end case;
                end if;
            end if;
        end if;
    end process;

    proc_coeffs: process(clk) is
        variable tmp2: std_logic_vector(6 downto 0);
    begin
        if rising_edge(clk) then
            if (rst or invalid) = '1' then
                coeffs_vld <= '0';
            else
                if (outputing and reg_ready_m_axis_tvalid) = '1' then
                    coeffs_vld <= '1';

                    if (not coeffs_vld or m_axis_tready) = '1' then
                        for i in 0 to 3 loop
                            if (hints_fifo_dout_vld(i) and hints_fifo_dout_rdy(i)) = '1' then
                                -- apply hints, most significant bit determines if we should add or subtract 1
                                if reg_ready_m_axis_tdata(15 + 16 * i) = '1' then
                                    -- check overflow when subtracting
                                    if reg_ready_m_axis_tdata(5 + 16 * i downto 16 * i) = "000000" then
                                        if mode = "00" then
                                            coeffs(5 + 6 * i downto 6 * i) <= "10" & x"b";
                                        else
                                            coeffs(5 + 6 * i downto 6 * i) <= "00" & x"f";
                                        end if;
                                    else
                                        tmp2 := std_logic_vector(signed('0' & reg_ready_m_axis_tdata(5 + 16 * i downto 16 * i)) - 1);
                                        coeffs(5 + 6 * i downto 6 * i) <= tmp2(5 downto 0);
                                    end if;
                                else
                                    -- check overflow when adding
                                    if reg_ready_m_axis_tdata(5 + 16 * i downto 16 * i) /= "10" & x"b" and (mode = "00" or reg_ready_m_axis_tdata(3 + 16 * i downto 16 * i) /= x"f") then
                                        coeffs(5 + 6 * i downto 6 * i) <= std_logic_vector(unsigned(reg_ready_m_axis_tdata(5 + 16 * i downto 16 * i)) + 1);
                                    else
                                        coeffs(5 + 6 * i downto 6 * i) <= (others => '0');
                                    end if;
                                end if;
                            else
                                coeffs(5 + 6 * i downto 6 * i) <= reg_ready_m_axis_tdata(5 + 16 * i downto 16 * i);
                            end if;
                        end loop;
                    end if;
                elsif m_axis_tready = '1' then
                    coeffs_vld <= '0';
                end if;
            end if;
        end if;
    end process;

    proc_validity: process(clk) is
        variable cnt: natural range 0 to 4;
    begin
        if rising_edge(clk) then
            if (rst or invalid) = '1' then
                invalid <= '0';

                counts_index <= 0;
                total_count <= 0;
            else
                if (outputing and reg_ready_m_axis_tvalid and (not coeffs_vld or m_axis_tready)) = '1' then
                    cnt := 0;

                    for i in 0 to 3 loop
                        if (hints_fifo_dout_vld(i) and hints_fifo_dout_rdy(i)) = '1' then
                            cnt := cnt + 1;
                        end if;
                    end loop;

                    total_count <= total_count + cnt;
                end if;

                if (outputing and reg_ready_m_axis_tvalid and (not coeffs_vld or m_axis_tready)) = '1' and transactions_count mod 64 = 63 then
                    -- check followed counts increase
                    if counts_index /= 0 and unsigned(counts(7 + 8 * counts_index downto 8 * counts_index)) < unsigned(counts(7 + 8 * (counts_index - 1) downto 8 * (counts_index - 1))) then
                        invalid <= '1';
                    end if;

                    -- check number of 1s
                    case mode_reg is
                        when "00" => if total_count > 80 then invalid <= '1'; end if;
                        when "01" => if total_count > 55 then invalid <= '1'; end if;
                        when others => if total_count > 75 then invalid <= '1'; end if;
                    end case;

                    -- check we used correct number of hints
                    if unsigned(counts(7 + 8 * counts_index downto 8 * counts_index)) /= total_count + cnt then
                        invalid <= '1';
                    end if;

                    if transactions_last = '1' then
                        total_count <= 0;

                        counts_index <= 0;
                    else
                        counts_index <= counts_index + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    transactions_count_last <= 0 when reading_count = '1' else
        79 when outputing = '0' and mode_reg = "00" else
        54 when outputing = '0' and mode_reg = "01" else
        74 when outputing = '0' else
        255 when mode_reg = "00" else
        383 when mode_reg = "01" else
        511;

    transactions_last <= '1' when transactions_count = transactions_count_last else '0';

    proc_transactions: process(clk) is
    begin
        if rising_edge(clk) then
            if outputing = '0' then
                mode_reg <= mode;
            end if;

            if (rst or invalid) = '1' then
                reading_count <= '0';
                outputing <= '0';

                transactions_count <= 0;
            else
                if ((not outputing and reg_ready_m_axis_tvalid) or (reg_ready_m_axis_tvalid and (not coeffs_vld or m_axis_tready))) = '1' then
                    if transactions_last = '1' then
                        reading_count <= not reading_count and not outputing;
                        outputing <= reading_count;

                        transactions_count <= 0;
                    else
                        transactions_count <= transactions_count + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;
end;