library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_tx is
generic (
    -- CLK frequency / Baud rate (100MHz / 115200)
    CYCLES_PER_BIT: natural := 868
);
port (
    clk: in std_logic;
    rst: in std_logic;

    byte: in std_logic_vector(7 downto 0);
    byte_vld: in std_logic;
    byte_next: out std_logic;

    uart_tx: out std_logic
);
end;

architecture behav of uart_tx is
    signal uart_tx_reg: std_logic;
    signal transaction_started: std_logic;

    signal byte_next_reg: std_logic;

    signal byte_reg: std_logic_vector(7 downto 0);
    signal vld_bits: std_logic_vector(7 downto 0);

    signal cycles_count: natural range 0 to CYCLES_PER_BIT - 1;
begin
    uart_tx <= uart_tx_reg;

    byte_next <= byte_next_reg;

    process(clk) is
    begin
        if rising_edge(clk) then
            byte_next_reg <= '0';

            if rst = '1' then
                uart_tx_reg <= '1';
                transaction_started <= '0';

                byte_reg <= (others => '0');
                vld_bits <= (others => '0');

                cycles_count <= 0;
            else
                if transaction_started = '0' then
                    if byte_vld = '1' then
                        -- begin UART transaction by setting start bit to 0
                        uart_tx_reg <= '0';

                        byte_reg <= byte;
                        vld_bits <= (others => '1');

                        if cycles_count = CYCLES_PER_BIT - 1 then
                            byte_next_reg <= '1';
                            transaction_started <= '1';

                            cycles_count <= 0;
                        else
                            cycles_count <= cycles_count + 1;
                        end if;
                    else
                        cycles_count <= 0;
                    end if;
                else
                    if vld_bits = (vld_bits'range => '0') then
                        -- end UART transaction by setting stop bit to 1
                        uart_tx_reg <= '1';
                    else
                        -- write data bits to UART
                        uart_tx_reg <= byte_reg(0);
                    end if;

                    if cycles_count = CYCLES_PER_BIT - 1 then
                        if vld_bits = (vld_bits'range => '0') then
                            transaction_started <= '0';
                        else
                            byte_reg <= '0' & byte_reg(byte_reg'left downto 1);
                            vld_bits <= '0' & vld_bits(vld_bits'left downto 1);
                        end if;

                        cycles_count <= 0;
                    else
                        cycles_count <= cycles_count + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;
end;
