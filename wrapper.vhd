library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.types_pkg.all;

entity wrapper is
generic (
    UART_CYCLES_PER_BIT: natural
);
port (
    clk: in std_logic;
    rst_n: in std_logic;

    uart_rx: in std_logic;
    uart_tx: out std_logic;

    trigger: out std_logic
);
end;

architecture behav of wrapper is
    signal rst: std_logic;

    signal rx_byte_vld: std_logic;
    signal rx_byte: std_logic_vector(7 downto 0);

    signal tx_byte_vld, tx_byte_next: std_logic;
    signal tx_byte: std_logic_vector(7 downto 0);

    signal fifo_din: slv_array_t(1 downto 0)(63 downto 0);
    signal fifo_din_last: std_logic;
    signal fifo_din_vld: std_logic;

    signal fifo_dout: slv_array_t(1 downto 0)(63 downto 0);
    signal fifo_dout_rdy: std_logic;

    signal fifo_din_ser, fifo_dout_ser: std_logic_vector(128 downto 0);

    signal random: std_logic_vector(800 downto 0);

    signal sec_conversion_random: std_logic_vector(23 downto 0);
    signal sec_conversion_random_mode: std_logic;
    signal other_random: std_logic_vector(24 downto 0);

    signal random_fifo_rst: std_logic;
    signal random_fifo_dout_rdy: std_logic;

    signal sec_conversion_random_fifo_din: std_logic_vector(23 downto 0);
    signal sec_conversion_random_fifo_din_vld, sec_conversion_random_fifo_din_rdy: std_logic_vector(1 downto 0);
    signal sec_conversion_random_fifo_dout: std_logic_vector(23 downto 0);

    signal other_random_fifo_din: std_logic_vector(5 downto 0);
    signal other_random_fifo_din_vld, other_random_fifo_din_rdy: std_logic;
    signal other_random_fifo_dout: std_logic_vector(5 downto 0);

    signal top_component_mode: std_logic_vector(10 downto 0);
    signal top_component_mode_vld, top_component_mode_next: std_logic;

    signal top_s_axis_tdata: slv_array_t(1 downto 0)(63 downto 0);
    signal top_s_axis_tlast, top_s_axis_tvalid, top_s_axis_tready: std_logic;

    signal top_m_axis_tdata: slv_array_t(1 downto 0)(63 downto 0);
    signal top_m_axis_tlast, top_m_axis_tvalid, top_m_axis_tready: std_logic;

    signal in_transactions, out_transactions: unsigned(13 downto 0);
    signal in_transactions_target: natural range 0 to 936 := 936;
    signal out_transactions_target: natural range 0 to 936;

    type state_t is (IDLE, READ_MODE, READ_DATA, COMPUTE_IN, COMPUTE_OUT, WRITE_DATA);
    signal state: state_t;
begin
    rst <= not rst_n;

    trigger <= rx_byte_vld when in_transactions(13 downto 4) = in_transactions_target - 1 and in_transactions(3 downto 0) = 15 and state = READ_DATA else '0';

    rx: entity work.uart_rx
    generic map (
        CYCLES_PER_BIT => UART_CYCLES_PER_BIT
    )
    port map (
        clk => clk,
        rst => rst,

        uart_rx => uart_rx,

        byte => rx_byte,
        byte_vld => rx_byte_vld
    );

    tx: entity work.uart_tx
    generic map (
        CYCLES_PER_BIT => UART_CYCLES_PER_BIT
    )
    port map (
        clk => clk,
        rst => rst,

        byte => tx_byte,
        byte_vld => tx_byte_vld,
        byte_next => tx_byte_next,

        uart_tx => uart_tx
    );

    tx_byte <= fifo_dout_ser(7 + 8 * to_integer(out_transactions(3 downto 0)) downto 8 * to_integer(out_transactions(3 downto 0)));
    tx_byte_vld <= '1' when state = WRITE_DATA else '0';

    fifo: entity work.small_fifo
    generic map (
        DATA_WIDTH => 129,
        DATA_DEPTH => 1024,
        OUT_REG => true
    )
    port map (
        clk => clk,
        rst => rst,

        din => fifo_din_ser,
        din_vld => fifo_din_vld,

        dout => fifo_dout_ser,
        dout_vld => open, -- must always have valid data when in state of reading from it
        dout_rdy => fifo_dout_rdy
    );

    fifo_din_ser <= fifo_din_last & slv_array_ser(fifo_din, 2, 64);

    fifo_dout <= slv_array_deser(fifo_dout_ser(127 downto 0), 2, 64);

    fifo_dout_rdy <= top_s_axis_tready when state = COMPUTE_IN else
        tx_byte_next when state = WRITE_DATA and out_transactions(3 downto 0) = 15 else
        '0';

    proc_fifo: process(clk) is
    begin
        if rising_edge(clk) then
            if state = READ_DATA then
                fifo_din(to_integer(in_transactions(3 downto 3)))(7 + 8 * to_integer(in_transactions(2 downto 0)) downto 8 * to_integer(in_transactions(2 downto 0))) <= rx_byte;

                if in_transactions(3 downto 0) = 15 then
                    if in_transactions(13 downto 4) = in_transactions_target - 1 then
                        fifo_din_last <= '1';
                    end if;

                    fifo_din_vld <= rx_byte_vld;
                else
                    fifo_din_last <= '0';
                    fifo_din_vld <= '0';
                end if;
            elsif state = COMPUTE_OUT then
                fifo_din <= top_m_axis_tdata;
                fifo_din_vld <= top_m_axis_tvalid;
            else
                fifo_din_vld <= '0';
            end if;
        end if;
    end process;

    lfsr0: entity work.lfsr
    generic map (
        SEED1_BITS => 145,
        SEED2_BITS => 146,
        RANDOM_BITS => 145
    )
    port map (
        clk => clk,
        rst => rst,

        seed1 => '1' & x"7e45af7b4c0e678c85f8e14111e77bcfa83a",
        seed2 => "10" & x"e27e209a90ef0ff162254a24b07c96493e91",

        random => random(144 downto 0)
    );

    lfsr1: entity work.lfsr
    generic map (
        SEED1_BITS => 161,
        SEED2_BITS => 162,
        RANDOM_BITS => 161
    )
    port map (
        clk => clk,
        rst => rst,

        seed1 => '0' & x"e5f6f5ff488ca43d790261399d931cc1acc93dbd",
        seed2 => "10" & x"ab751ec1e41d348bbc2a4e430eff610a205bee53",

        random => random(305 downto 145)
    );

    lfsr2: entity work.lfsr
    generic map (
        SEED1_BITS => 163,
        SEED2_BITS => 164,
        RANDOM_BITS => 163
    )
    port map (
        clk => clk,
        rst => rst,

        seed1 => "110" & x"11ecf9f66417e978f68b7e9de50e4db077cf5a8b",
        seed2 => x"9b15face0906ccd779c76a90c7b89f02781f82a41",

        random => random(468 downto 306)
    );

    lfsr3: entity work.lfsr
    generic map (
        SEED1_BITS => 165,
        SEED2_BITS => 166,
        RANDOM_BITS => 165
    )
    port map (
        clk => clk,
        rst => rst,

        seed1 => '0' & x"dfd764e01a4580358e34186f675f972b84141dd7e",
        seed2 => "10" & x"0ac43076223b0b8586f6a55d843737da0e10ca994",

        random => random(633 downto 469)
    );

    lfsr4: entity work.lfsr
    generic map (
        SEED1_BITS => 167,
        SEED2_BITS => 168,
        RANDOM_BITS => 167
    )
    port map (
        clk => clk,
        rst => rst,

        seed1 => "100" & x"ba822c8ae54173e70a49536e96291b038b096261e",
        seed2 => x"0b6d9f97d651d6770a147f9c15f0a99c574facbdef",

        random => random(800 downto 634)
    );

    random_fifo_rst <= '1' when state = IDLE else '0';
    random_fifo_dout_rdy <= '1' when state = COMPUTE_IN or state = COMPUTE_OUT else '0';

    sec_conversion_random_fifo_g: for i in 0 to 1 generate
        sec_conversion_random_fifo: entity work.small_fifo
        generic map (
            DATA_WIDTH => 12,
            DATA_DEPTH => 1024,
            OUT_REG => true
        )
        port map (
            clk => clk,
            rst => random_fifo_rst,

            din => sec_conversion_random_fifo_din(11 + 12 * i downto 12 * i),
            din_vld => sec_conversion_random_fifo_din_vld(i) and sec_conversion_random_fifo_din_rdy(i),
            din_rdy => sec_conversion_random_fifo_din_rdy(i),

            dout => sec_conversion_random_fifo_dout(11 + 12 * i downto 12 * i),
            dout_rdy => random_fifo_dout_rdy
        );
    end generate;

    sec_conversion_random_fifo_p: process(clk) is
    begin
        if rising_edge(clk) then
            if state = READ_DATA or state = COMPUTE_IN or state = COMPUTE_OUT then
                if (or top_component_mode(8 downto 6)) = '1' then
                    if unsigned(random(23 downto 0)) < x"7fe001" then
                        sec_conversion_random_fifo_din <= std_logic_vector(unsigned(random(23 downto 0)) + 1);
                        sec_conversion_random_fifo_din_vld <= "11";
                    else
                        sec_conversion_random_fifo_din_vld <= "00";
                    end if;
                else
                    for i in 0 to 1 loop
                        if unsigned(random(11 + 12 * i downto 12 * i)) < x"d01" then
                            sec_conversion_random_fifo_din(11 + 12 * i downto 12 * i) <= std_logic_vector(unsigned(random(11 + 12 * i downto 12 * i)) + 1);
                            sec_conversion_random_fifo_din_vld(i) <= '1';
                        else
                            sec_conversion_random_fifo_din_vld(i) <= '0';
                        end if;
                    end loop;
                end if;
            else
                sec_conversion_random_fifo_din_vld <= (others => '0');
            end if;
        end if;
    end process;

    other_random_fifo: entity work.small_fifo
    generic map (
        DATA_WIDTH => 6,
        DATA_DEPTH => 1024,
        OUT_REG => true
    )
    port map (
        clk => clk,
        rst => random_fifo_rst,

        din => other_random_fifo_din,
        din_vld => other_random_fifo_din_vld and other_random_fifo_din_rdy,
        din_rdy => other_random_fifo_din_rdy,

        dout => other_random_fifo_dout,
        dout_rdy => random_fifo_dout_rdy
    );

    other_random_fifo_p: process(clk) is
    begin
        if rising_edge(clk) then
            if state = READ_DATA or state = COMPUTE_IN or state = COMPUTE_OUT then
                if top_component_mode(7) = '1' then
                    if top_component_mode(10 downto 9) = "00" then
                        other_random_fifo_din <= random(781 downto 776);

                        if unsigned(random(781 downto 776)) < x"2c" then
                            other_random_fifo_din_vld <= '1';
                        else
                            other_random_fifo_din_vld <= '0';
                        end if;
                    else
                        other_random_fifo_din <= random(781 downto 776) and "001111";
                        other_random_fifo_din_vld <= '1';
                    end if;
                end if;
            else
                other_random_fifo_din_vld <= '0';
            end if;
        end if;
    end process;

    sec_conversion_random <= sec_conversion_random_fifo_dout when sec_conversion_random_mode = '1' else random(23 downto 0);
    other_random <= (24 downto 6 => '0') & other_random_fifo_dout when top_component_mode(7) = '1' else random(800 downto 776);

    top: entity work.top
    port map (
        clk => clk,
        rst => rst,

        sec_conversion_random => random(775 downto 24) & sec_conversion_random,
        sec_conversion_random_mode => sec_conversion_random_mode,
        other_random => other_random,

        component_mode => top_component_mode,
        component_mode_vld => top_component_mode_vld,
        component_mode_next => top_component_mode_next,

        s_axis_tdata => top_s_axis_tdata,
        s_axis_tlast => top_s_axis_tlast,
        s_axis_tvalid => top_s_axis_tvalid,
        s_axis_tready => top_s_axis_tready,

        m_axis_tdata => top_m_axis_tdata,
        m_axis_tlast => top_m_axis_tlast,
        m_axis_tvalid => top_m_axis_tvalid,
        m_axis_tready => top_m_axis_tready
    );

    top_s_axis_tdata <= fifo_dout;
    top_s_axis_tlast <= fifo_dout_ser(128);
    top_s_axis_tvalid <= '1' when state = COMPUTE_IN else '0';

    top_m_axis_tready <= '1';

    proc_in: process(clk) is
    begin
        if rising_edge(clk) then
            if rst = '1' then
                in_transactions <= (others => '0');
            else
                if state = READ_DATA and rx_byte_vld = '1' then
                    if in_transactions(13 downto 4) = in_transactions_target - 1 and in_transactions(3 downto 0) = 15 then
                        in_transactions <= (others => '0');
                    else
                        in_transactions <= in_transactions + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    proc_out: process(clk) is
    begin
        if rising_edge(clk) then
            if rst = '1' then
                out_transactions <= (others => '0');
            else
                if state = WRITE_DATA and tx_byte_next = '1' then
                    if out_transactions(13 downto 4) = out_transactions_target - 1 and out_transactions(3 downto 0) = 15 then
                        out_transactions <= (others => '0');
                    else
                        out_transactions <= out_transactions + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    proc_component_mode: process(clk) is
    begin
        if rising_edge(clk) then
            if rst = '1' then
                top_component_mode_vld <= '0';
            else
                if state = READ_DATA and rx_byte_vld = '1' and in_transactions(13 downto 4) = in_transactions_target - 1 and in_transactions(3 downto 0) = 15 then
                    top_component_mode_vld <= '1';
                elsif top_component_mode_next = '1' then
                    top_component_mode_vld <= '0';
                end if;
            end if;

            if state = READ_MODE and rx_byte_vld = '1' then
                case rx_byte is
                    when x"01" => top_component_mode <= "00000000001"; in_transactions_target <= 4; out_transactions_target <= 196;
                    when x"02" => top_component_mode <= "00000000010"; in_transactions_target <= 108; out_transactions_target <= 96;
                    when x"03" => top_component_mode <= "00000000100"; in_transactions_target <= 192; out_transactions_target <= 4;
                    when x"04" => top_component_mode <= "00000001000"; in_transactions_target <= 8; out_transactions_target <= 304;
                    when x"05" => top_component_mode <= "00000010000"; in_transactions_target <= 104; out_transactions_target <= 100;
                    when x"06" => top_component_mode <= "00000100000"; in_transactions_target <= 300; out_transactions_target <= 4;
                    when x"07" => top_component_mode <= "00001000000"; in_transactions_target <= 4; out_transactions_target <= 484;
                    when x"08" => top_component_mode <= "00010000000"; in_transactions_target <= 328; out_transactions_target <= 303;
                    when x"09" => top_component_mode <= "00100000000"; in_transactions_target <= 471; out_transactions_target <= 1;
                    when x"11" => top_component_mode <= "01000000001"; in_transactions_target <= 4; out_transactions_target <= 292;
                    when x"12" => top_component_mode <= "01000000010"; in_transactions_target <= 156; out_transactions_target <= 136;
                    when x"13" => top_component_mode <= "01000000100"; in_transactions_target <= 280; out_transactions_target <= 4;
                    when x"14" => top_component_mode <= "01000001000"; in_transactions_target <= 8; out_transactions_target <= 448;
                    when x"15" => top_component_mode <= "01000010000"; in_transactions_target <= 152; out_transactions_target <= 140;
                    when x"16" => top_component_mode <= "01000100000"; in_transactions_target <= 436; out_transactions_target <= 4;
                    when x"17" => top_component_mode <= "01001000000"; in_transactions_target <= 4; out_transactions_target <= 748;
                    when x"18" => top_component_mode <= "01010000000"; in_transactions_target <= 512; out_transactions_target <= 414;
                    when x"19" => top_component_mode <= "01100000000"; in_transactions_target <= 662; out_transactions_target <= 1;
                    when x"21" => top_component_mode <= "10000000001"; in_transactions_target <= 4; out_transactions_target <= 388;
                    when x"22" => top_component_mode <= "10000000010"; in_transactions_target <= 204; out_transactions_target <= 196;
                    when x"23" => top_component_mode <= "10000000100"; in_transactions_target <= 388; out_transactions_target <= 4;
                    when x"24" => top_component_mode <= "10000001000"; in_transactions_target <= 8; out_transactions_target <= 592;
                    when x"25" => top_component_mode <= "10000010000"; in_transactions_target <= 200; out_transactions_target <= 200;
                    when x"26" => top_component_mode <= "10000100000"; in_transactions_target <= 592; out_transactions_target <= 4;
                    when x"27" => top_component_mode <= "10001000000"; in_transactions_target <= 4; out_transactions_target <= 936;
                    when x"28" => top_component_mode <= "10010000000"; in_transactions_target <= 620; out_transactions_target <= 579;
                    when x"29" => top_component_mode <= "10100000000"; in_transactions_target <= 907; out_transactions_target <= 1;
                    when others =>
                end case;
            end if;
        end if;
    end process;

    proc_state: process(clk) is
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state <= IDLE;
            else
                case state is
                    when IDLE => if rx_byte_vld = '1' and rx_byte = x"01" then state <= READ_MODE; end if;
                    when READ_MODE => if rx_byte_vld = '1' then state <= READ_DATA; end if;
                    when READ_DATA => if rx_byte_vld = '1' and in_transactions(13 downto 4) = in_transactions_target - 1 and in_transactions(3 downto 0) = 15 then state <= COMPUTE_IN; end if;
                    when COMPUTE_IN => if (top_s_axis_tvalid and top_s_axis_tready and top_s_axis_tlast) = '1' then state <= COMPUTE_OUT; end if;
                    when COMPUTE_OUT => if (top_m_axis_tvalid and top_m_axis_tready and top_m_axis_tlast) = '1' then state <= WRITE_DATA; end if;
                    when WRITE_DATA => if tx_byte_next = '1' and out_transactions(3 downto 0) = 15 and out_transactions(13 downto 4) = out_transactions_target - 1 then state <= IDLE; end if;
                end case;
            end if;
        end if;
    end process;
end;
