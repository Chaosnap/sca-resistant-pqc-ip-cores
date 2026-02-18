library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_rx is
generic (
    -- CLK frequency / Baud rate (100MHz / 115200)
    CYCLES_PER_BIT: natural := 868
);
port (
    clk: in std_logic;
    rst: in std_logic;

    uart_rx: in std_logic;

    byte: out std_logic_vector(7 downto 0);
    byte_vld: out std_logic
);
end;

architecture behav of uart_rx is
    signal transaction_started: std_logic;
    signal byte_vld_reg: std_logic;

    signal byte_reg: std_logic_vector(7 downto 0);
    signal vld_bits: std_logic_vector(7 downto 0);

    signal cycles_count: natural range 0 to CYCLES_PER_BIT - 1;
begin
    byte <= byte_reg;
    byte_vld <= byte_vld_reg;

    process(clk) is
    begin
        if rising_edge(clk) then
            byte_vld_reg <= '0';

            if rst = '1' then
                transaction_started <= '0';

                byte_reg <= (others => '0');
                vld_bits <= (others => '0');

                cycles_count <= 0;
            else
                if transaction_started = '0' then
                    -- UART transaction starts with setting bit to 0
                    if uart_rx = '0' then
                        -- wait till we get to middle of bit, so we read all data in the middle as it is most precised
                        if cycles_count = (CYCLES_PER_BIT - 1) / 2 then
                            transaction_started <= '1';

                            cycles_count <= 0;
                        else
                            cycles_count <= cycles_count + 1;
                        end if;
                    else
                        cycles_count <= 0;
                    end if;
                else
                    if cycles_count = CYCLES_PER_BIT - 1 then
                        if vld_bits = (vld_bits'range => '1') then
                            -- UART transaction ends with setting stop bit to 1
                            transaction_started <= '0';
                            byte_vld_reg <= '1';

                            vld_bits <= (others => '0');
                        else
                            -- load data bits into register
                            byte_reg <= uart_rx & byte_reg(byte_reg'left downto 1);
                            vld_bits <= '1' & vld_bits(vld_bits'left downto 1);
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
