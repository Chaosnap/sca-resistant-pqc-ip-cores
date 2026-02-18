library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.math_pkg.all;

entity display is
generic (
    COUNT: natural := 8
);
port (
    clk: in std_logic;
    rst: in std_logic;

    data: in std_logic_vector(4 * COUNT - 1 downto 0);

    ca: out std_logic;
    cb: out std_logic;
    cc: out std_logic;
    cd: out std_logic;
    ce: out std_logic;
    cf: out std_logic;
    cg: out std_logic;
    dp: out std_logic;

    an: out std_logic_vector(COUNT - 1 downto 0)
);
end;

architecture behav of display is
    signal encoded: std_logic_vector(7 downto 0);
    signal an_reg: std_logic_vector(COUNT - 1 downto 0);

    signal counter: unsigned(12 + log2(COUNT) downto 0);
begin
    -- scheme of driving ports, everything is active when low
    -- - A -
    -- F   B
    -- - G -
    -- E   C
    -- - D - DP
    ca <= encoded(0);
    cb <= encoded(1);
    cc <= encoded(2);
    cd <= encoded(3);
    ce <= encoded(4);
    cf <= encoded(5);
    cg <= encoded(6);
    dp <= encoded(7);

    an <= an_reg;

    process(clk) is
    begin
        if rising_edge(clk) then
            case data(3 + 4 * to_integer(counter(counter'left downto 13)) downto 4 * to_integer(counter(counter'left downto 13))) is
                when "0000" => encoded <= "11000000";
                when "0001" => encoded <= "11111001";
                when "0010" => encoded <= "10100100";
                when "0011" => encoded <= "10110000";
                when "0100" => encoded <= "10011001";
                when "0101" => encoded <= "10010010";
                when "0110" => encoded <= "10000010";
                when "0111" => encoded <= "11111000";
                when "1000" => encoded <= "10000000";
                when "1001" => encoded <= "10010000";
                when "1010" => encoded <= "10001000";
                when "1011" => encoded <= "10000011";
                when "1100" => encoded <= "11000110";
                when "1101" => encoded <= "10100001";
                when "1110" => encoded <= "10000110";
                when "1111" => encoded <= "10001110";
                when others => encoded <= "00000000";
            end case;

            if rst = '1' then
                an_reg <= (0 => '0', others => '1');
                counter <= (others => '0');
            else
                if (counter mod 8192) = 8191 then
                    an_reg <= an_reg(an_reg'left - 1 downto 0) & an_reg(an_reg'left);
                end if;

                counter <= counter + 1;
            end if;
        end if;
    end process;
end;
