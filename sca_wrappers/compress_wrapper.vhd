-- Copyright (C) 2025 Patrik Dobias <xdobia13@vut.cz>
-- Released for the non-commercial use only. For licensing, please contact <malina@vut.cz>

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.types_pkg.all;

entity compress_wrapper is
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

architecture behav of compress_wrapper is
    constant TRANSACTIONS: natural := 12;
    constant INSTANCES: natural := 1;

    signal rst: std_logic;

    signal rx_byte_vld: std_logic;
    signal rx_byte: std_logic_vector(7 downto 0);

    signal tx_byte_vld, tx_byte_next: std_logic;
    signal tx_byte: std_logic_vector(7 downto 0);

    signal fifo_din: std_logic_vector(95 downto 0);
    signal fifo_din_vld: std_logic;

    signal fifo_dout: std_logic_vector(95 downto 0);
    signal fifo_dout_vld, fifo_dout_rdy: std_logic;

    signal compress_s_axis_tdata: std_logic_vector(95 downto 0);
    signal compress_s_axis_tuser: std_logic_vector(5 downto 0);
    signal compress_s_axis_tvalid: std_logic;
    signal compress_s_axis_tready: std_logic_vector(INSTANCES - 1 downto 0);

    signal compress_m_axis_tdata: slv_array_t(INSTANCES - 1 downto 0)(95 downto 0);
    signal compress_m_axis_tvalid: std_logic_vector(INSTANCES - 1 downto 0);
    signal compress_m_axis_tready: std_logic;

    signal in_transactions_lower, out_transactions_lower: natural range 0 to TRANSACTIONS - 1;
    signal in_transactions_higher, out_transactions_higher: natural range 0 to 63;
    signal in_transactions_target: natural range 0 to 64;
    signal out_transactions_target: natural range 0 to 64;

    signal counter: unsigned(7 downto 0);

    type state_t is (IDLE, READ_MODE, READ_DATA, WAIT_BEFORE, COMPUTE_IN, COMPUTE_OUT, WAIT_AFTER, WRITE_DATA);
    signal state: state_t;
begin
    rst <= not rst_n;

    trigger <= compress_s_axis_tvalid;

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

    tx_byte <= fifo_dout(7 + 8 * out_transactions_lower downto 8 * out_transactions_lower);
    tx_byte_vld <= '1' when state = WRITE_DATA else '0';

    fifo: entity work.small_fifo
    generic map (
        DATA_WIDTH => 96,
        DATA_DEPTH => 1024,
        OUT_REG => true
    )
    port map (
        clk => clk,
        rst => rst,

        din => fifo_din,
        din_vld => fifo_din_vld,

        dout => fifo_dout,
        dout_vld => fifo_dout_vld,
        dout_rdy => fifo_dout_rdy
    );

    fifo_dout_rdy <= xor compress_s_axis_tready when state = COMPUTE_IN else
        tx_byte_next when state = WRITE_DATA and out_transactions_lower = TRANSACTIONS - 1 else
        '0';

    proc_fifo: process(clk) is
        variable fifo_din_v: std_logic_vector(fifo_din'range);
    begin
        if rising_edge(clk) then
            if state = READ_DATA then
                fifo_din(7 + 8 * in_transactions_lower downto 8 * in_transactions_lower) <= rx_byte;

                if in_transactions_lower = TRANSACTIONS - 1 then
                    fifo_din_vld <= rx_byte_vld;
                else
                    fifo_din_vld <= '0';
                end if;
            elsif state = COMPUTE_IN or state = COMPUTE_OUT then
                fifo_din_v := (others => '0');

                for i in 0 to INSTANCES - 1 loop
                    fifo_din_v := fifo_din_v xor compress_m_axis_tdata(i);
                end loop;

                fifo_din <= fifo_din_v;
                fifo_din_vld <= xor compress_m_axis_tvalid;
            else
                fifo_din_vld <= '0';
            end if;
        end if;
    end process;

    parallel_g: for i in 0 to INSTANCES - 1 generate
        compress: entity work.compress
        port map (
            clk => clk,
            rst => rst,

            s_axis_tdata => compress_s_axis_tdata,
            s_axis_tuser => compress_s_axis_tuser,
            s_axis_tvalid => compress_s_axis_tvalid,
            s_axis_tready => compress_s_axis_tready(i),

            m_axis_tdata => compress_m_axis_tdata(i),
            m_axis_tvalid => compress_m_axis_tvalid(i),
            m_axis_tready => compress_m_axis_tready
        );
    end generate;

    compress_s_axis_tdata <= fifo_dout;
    compress_s_axis_tvalid <= fifo_dout_vld when state = COMPUTE_IN else '0';

    compress_m_axis_tready <= '1';

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

                if state = COMPUTE_IN and (compress_s_axis_tvalid and (xor compress_s_axis_tready)) = '1' then
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

                if (state = COMPUTE_IN or state = COMPUTE_OUT) and ((xor compress_m_axis_tvalid) and compress_m_axis_tready) = '1' then
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
                    when x"01" => compress_s_axis_tuser <= "000101"; in_transactions_target <= 2; out_transactions_target <= 2;
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
                    when COMPUTE_IN => if (compress_s_axis_tvalid and (xor compress_s_axis_tready)) = '1' and in_transactions_higher = in_transactions_target - 1 then state <= COMPUTE_OUT; end if;
                    when COMPUTE_OUT => if (xor compress_m_axis_tvalid) = '1' and out_transactions_higher = out_transactions_target - 1 then state <= WAIT_AFTER; end if;
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
