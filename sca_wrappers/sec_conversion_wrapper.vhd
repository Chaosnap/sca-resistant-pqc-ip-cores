-- Copyright (C) 2025 Patrik Dobias <xdobia13@vut.cz>
-- Released for the non-commercial use only. For licensing, please contact <malina@vut.cz>

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.types_pkg.all;

entity sec_conversion_wrapper is
generic (
    UART_CYCLES_PER_BIT: natural;
    MASKING_EN: boolean
);
port (
    clk: in std_logic;
    rst_n: in std_logic;

    uart_rx: in std_logic;
    uart_tx: out std_logic;

    trigger: out std_logic
);
end;

architecture behav of sec_conversion_wrapper is
    constant TRANSACTIONS: natural := 24;
    constant INSTANCES: natural := 9;

    type array3d_t is array (natural range <>) of slv_array_t;

    signal rst: std_logic;

    signal rx_byte_vld: std_logic;
    signal rx_byte: std_logic_vector(7 downto 0);

    signal tx_byte_vld, tx_byte_next: std_logic;
    signal tx_byte: std_logic_vector(7 downto 0);

    signal fifo_din_vld: std_logic;

    signal fifo_dout: slv_array_t(1 downto 0)(95 downto 0);
    signal fifo_dout_vld, fifo_dout_rdy: std_logic;

    signal fifo_din_ser, fifo_dout_ser: std_logic_vector(191 downto 0);

    signal lfsr_en: std_logic;
    signal random: std_logic_vector(775 downto 0);

    signal random_fifo_rst: std_logic;
    signal random_fifo_din: std_logic_vector(23 downto 0);
    signal random_fifo_din_vld, random_fifo_din_rdy: std_logic;
    signal random_fifo_dout: std_logic_vector(23 downto 0);
    signal random_fifo_dout_rdy: std_logic;

    signal sec_conversion_s_axis_tdata: slv_array_t(1 downto 0)(95 downto 0);
    signal sec_conversion_s_axis_tuser: std_logic_vector(3 downto 0);
    signal sec_conversion_s_axis_tvalid: std_logic;
    signal sec_conversion_s_axis_tready: std_logic_vector(INSTANCES - 1 downto 0);

    signal sec_conversion_m_axis_tdata: array3d_t(INSTANCES - 1 downto 0)(1 downto 0)(95 downto 0);
    signal sec_conversion_m_axis_tvalid: std_logic_vector(INSTANCES - 1 downto 0);
    signal sec_conversion_m_axis_tready: std_logic;

    signal in_transactions_lower, out_transactions_lower: natural range 0 to TRANSACTIONS - 1;
    signal in_transactions_higher, out_transactions_higher: natural range 0 to 63;
    signal in_transactions_target: natural range 0 to 64;
    signal out_transactions_target: natural range 0 to 64;

    signal counter: unsigned(7 downto 0);

    type state_t is (IDLE, READ_MODE, READ_DATA, WAIT_BEFORE, COMPUTE_IN, COMPUTE_OUT, WAIT_AFTER, WRITE_DATA);
    signal state: state_t;

    component sec_conversion is
    port (
        clk: in std_logic;
        rst: in std_logic;

        random: in std_logic_vector(775 downto 0);

        bound_check_mode: in std_logic_vector(3 downto 0) := "1100";

        s_axis_tdata: in slv_array_t(1 downto 0)(95 downto 0);
        s_axis_tuser: in std_logic_vector(3 downto 0);
        s_axis_tvalid: in std_logic;
        s_axis_tready: out std_logic;

        m_axis_tdata: out slv_array_t(1 downto 0)(95 downto 0);
        m_axis_tuser: out std_logic_vector(3 downto 0);
        m_axis_tvalid: out std_logic;
        m_axis_tready: in std_logic
    );
    end component;

    attribute dont_touch: string;
    attribute dont_touch of sec_conversion: component is "yes";
begin
    rst <= not rst_n;

    trigger <= sec_conversion_s_axis_tvalid;

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

    tx_byte <= fifo_dout_ser(7 + 8 * out_transactions_lower downto 8 * out_transactions_lower);
    tx_byte_vld <= '1' when state = WRITE_DATA else '0';

    fifo: entity work.small_fifo
    generic map (
        DATA_WIDTH => 192,
        DATA_DEPTH => 1024,
        OUT_REG => true
    )
    port map (
        clk => clk,
        rst => rst,

        din => fifo_din_ser,
        din_vld => fifo_din_vld,

        dout => fifo_dout_ser,
        dout_vld => fifo_dout_vld,
        dout_rdy => fifo_dout_rdy
    );

    fifo_dout <= slv_array_deser(fifo_dout_ser(191 downto 0), 2, 96);

    fifo_dout_rdy <= xor sec_conversion_s_axis_tready when state = COMPUTE_IN else
        tx_byte_next when state = WRITE_DATA and out_transactions_lower = TRANSACTIONS - 1 else
        '0';

    proc_fifo: process(clk) is
        variable fifo_din_ser_v: std_logic_vector(fifo_din_ser'range);
    begin
        if rising_edge(clk) then
            if state = READ_DATA then
                fifo_din_ser(7 + 8 * in_transactions_lower downto 8 * in_transactions_lower) <= rx_byte;

                if in_transactions_lower = TRANSACTIONS - 1 then
                    fifo_din_vld <= rx_byte_vld;
                else
                    fifo_din_vld <= '0';
                end if;
            elsif state = COMPUTE_OUT then
                fifo_din_ser_v := (others => '0');

                for i in 0 to INSTANCES - 1 loop
                    fifo_din_ser_v := fifo_din_ser_v xor slv_array_ser(sec_conversion_m_axis_tdata(i), 2, 96);
                end loop;

                fifo_din_ser <= fifo_din_ser_v;
                fifo_din_vld <= xor sec_conversion_m_axis_tvalid;
            else
                fifo_din_vld <= '0';
            end if;
        end if;
    end process;

    lfsr_en <= '1' when MASKING_EN else '0';

    lfsr0: entity work.lfsr
    generic map (
        SEED1_BITS => 120,
        SEED2_BITS => 121,
        RANDOM_BITS => 120
    )
    port map (
        clk => clk,
        rst => rst,

        seed1 => x"7e45af7b4c0e678c85f8e14111e773",
        seed2 => "1" & x"e27e209a90ef0ff162254a296493e1",

        en => lfsr_en,

        random => random(119 downto 0)
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

        en => lfsr_en,

        random => random(280 downto 120)
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

        en => lfsr_en,

        random => random(443 downto 281)
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

        en => lfsr_en,

        random => random(608 downto 444)
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

        en => lfsr_en,

        random => random(775 downto 609)
    );

    random_fifo: entity work.small_fifo
    generic map (
        DATA_WIDTH => 24,
        DATA_DEPTH => 1024,
        OUT_REG => true
    )
    port map (
        clk => clk,
        rst => random_fifo_rst,

        din => random_fifo_din,
        din_vld => random_fifo_din_vld and random_fifo_din_rdy,
        din_rdy => random_fifo_din_rdy,

        dout => random_fifo_dout,
        dout_rdy => random_fifo_dout_rdy
    );

    random_fifo_rst <= '1' when state = IDLE else '0';

    random_fifo_dout_rdy <= '1' when state = COMPUTE_IN or state = COMPUTE_OUT else '0';

    random_fifo_p: process(clk) is
    begin
        if rising_edge(clk) then
            if state = READ_DATA then
                random_fifo_din <= random(23 downto 0);

                case sec_conversion_s_axis_tuser is
                    -- make sure both parts are in range for kyber 0xd01 modulo
                    when "0100" =>
                        if unsigned(random(23 downto 12)) < x"d01" and unsigned(random(11 downto 0)) < x"d01" then
                            random_fifo_din_vld <= '1';
                        else
                            random_fifo_din_vld <= '0';
                        end if;
                    -- make sure in range for dilithium 0x7fe001 modulo
                    when "1100" =>
                        if unsigned(random(23 downto 0)) < x"7fe001" then
                            random_fifo_din_vld <= '1';
                        else
                            random_fifo_din_vld <= '0';
                        end if;
                    -- make sure in range for 0x2c modulo
                    when "1101" =>
                        if unsigned(random(5 downto 0)) < x"00002c" then
                            random_fifo_din_vld <= '1';
                        else
                            random_fifo_din_vld <= '0';
                        end if;
                    when others => random_fifo_din_vld <= '1';
                end case;
            else
                random_fifo_din_vld <= '0';
            end if;
        end if;
    end process;

    parallel_g: for i in 0 to INSTANCES - 1 generate
        sec_conversion: entity work.sec_conversion
        port map (
            clk => clk,
            rst => rst,

            random => random(random'left downto 24) & random_fifo_dout,

            s_axis_tdata => sec_conversion_s_axis_tdata,
            s_axis_tuser => sec_conversion_s_axis_tuser,
            s_axis_tvalid => sec_conversion_s_axis_tvalid,
            s_axis_tready => sec_conversion_s_axis_tready(i),

            m_axis_tdata => sec_conversion_m_axis_tdata(i),
            m_axis_tvalid => sec_conversion_m_axis_tvalid(i),
            m_axis_tready => sec_conversion_m_axis_tready
        );
    end generate;

    sec_conversion_s_axis_tdata <= fifo_dout;
    sec_conversion_s_axis_tvalid <= fifo_dout_vld when state = COMPUTE_IN else '0';

    sec_conversion_m_axis_tready <= '1';

    proc_in: process(clk) is
    begin
        if rising_edge(clk) then
            if rst = '1' then
                in_transactions_lower <= 0;
                in_transactions_higher <= 0;
            else
                if state = READ_DATA and rx_byte_vld = '1' then
                    if in_transactions_lower = TRANSACTIONS - 1 then
                        in_transactions_lower <= 0;

                        if in_transactions_higher = in_transactions_target - 1 then
                            in_transactions_higher <= 0;
                        else
                            in_transactions_higher <= in_transactions_higher + 1;
                        end if;
                    else
                        in_transactions_lower <= in_transactions_lower + 1;
                    end if;
                end if;

                if state = COMPUTE_IN and (sec_conversion_s_axis_tvalid and (xor sec_conversion_s_axis_tready)) = '1' then
                    if in_transactions_higher = in_transactions_target - 1 then
                        in_transactions_higher <= 0;
                    else
                        in_transactions_higher <= in_transactions_higher + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    proc_out: process(clk) is
    begin
        if rising_edge(clk) then
            if rst = '1' then
                out_transactions_lower <= 0;
                out_transactions_higher <= 0;
            else
                if state = WRITE_DATA and tx_byte_next = '1' then
                    if out_transactions_lower = TRANSACTIONS - 1 then
                        out_transactions_lower <= 0;

                        if out_transactions_higher = out_transactions_target - 1 then
                            out_transactions_higher <= 0;
                        else
                            out_transactions_higher <= out_transactions_higher + 1;
                        end if;
                    else
                        out_transactions_lower <= out_transactions_lower + 1;
                    end if;
                end if;

                if state = COMPUTE_OUT and ((xor sec_conversion_m_axis_tvalid) and sec_conversion_m_axis_tready) = '1' then
                    if out_transactions_higher = out_transactions_target - 1 then
                        out_transactions_higher <= 0;
                    else
                        out_transactions_higher <= out_transactions_higher + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    proc_component_mode: process(clk) is
    begin
        if rising_edge(clk) then
            if state = READ_MODE and rx_byte_vld = '1' then
                case rx_byte is
                    when x"01" => sec_conversion_s_axis_tuser <= "0000"; in_transactions_target <= 1; out_transactions_target <= 1;
                    when x"02" => sec_conversion_s_axis_tuser <= "0100"; in_transactions_target <= 1; out_transactions_target <= 1;
                    when x"03" => sec_conversion_s_axis_tuser <= "1000"; in_transactions_target <= 1; out_transactions_target <= 1;
                    when x"04" => sec_conversion_s_axis_tuser <= "1100"; in_transactions_target <= 1; out_transactions_target <= 1;
                    when x"05" => sec_conversion_s_axis_tuser <= "1101"; in_transactions_target <= 1; out_transactions_target <= 1;
                    when x"06" => sec_conversion_s_axis_tuser <= "1110"; in_transactions_target <= 1; out_transactions_target <= 1;
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
                    when READ_DATA => if rx_byte_vld = '1' and in_transactions_higher = in_transactions_target - 1 and in_transactions_lower = TRANSACTIONS - 1 then state <= WAIT_BEFORE; end if;
                    when WAIT_BEFORE => if counter = (counter'range => '1') then state <= COMPUTE_IN; end if;
                    when COMPUTE_IN => if (sec_conversion_s_axis_tvalid and (xor sec_conversion_s_axis_tready)) = '1' and in_transactions_higher = in_transactions_target - 1 then state <= COMPUTE_OUT; end if;
                    when COMPUTE_OUT => if (xor sec_conversion_m_axis_tvalid) = '1' and out_transactions_higher = out_transactions_target - 1 then state <= WAIT_AFTER; end if;
                    when WAIT_AFTER => if counter = (counter'range => '1') then state <= WRITE_DATA; end if;
                    when WRITE_DATA => if tx_byte_next = '1' and out_transactions_higher = out_transactions_target - 1 and out_transactions_lower = TRANSACTIONS - 1 then state <= IDLE; end if;
                end case;
            end if;
        end if;
    end process;

    counter_p: process(clk) is
    begin
        if rising_edge(clk) then
            if rst = '1' then
                counter <= (others => '0');
            elsif state = WAIT_BEFORE or state = WAIT_AFTER then
                counter <= counter + 1;
            end if;
        end if;
    end process;
end;
