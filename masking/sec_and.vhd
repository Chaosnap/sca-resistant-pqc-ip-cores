-- Copyright (C) 2025 Patrik Dobias <xdobia13@vut.cz>
-- Released for the non-commercial use only. For licensing, please contact <malina@vut.cz>

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.types_pkg.all;

-- AND between two values masked using boolean shares
entity sec_and is
generic (
    N: natural := 2;
    W: natural := 24
);
port (
    clk: in std_logic;

    -- boolean sharings
    x: in slv_array_t(N - 1 downto 0)(W - 1 downto 0);
    y: in slv_array_t(N - 1 downto 0)(W - 1 downto 0);

    -- fresh randomness
    r: in slv_array_t((N * (N - 1) / 2) - 1 downto 0)(W - 1 downto 0);

    -- boolean sharing
    z: out slv_array_t(N - 1 downto 0)(W - 1 downto 0)
);
end;

architecture behav of sec_and is
    signal u: slv_array_t(N - 1 downto 0)(W - 1 downto 0);
    signal x_and_y: slv_array_t(N - 1 downto 0)(W - 1 downto 0);

    -- assigning DON'T TOUCH attribute
    attribute dont_touch: string;
    attribute dont_touch of behav: architecture is "yes";

    attribute dont_touch of u, x_and_y: signal is "yes";
begin
    shares_g: for i in 0 to N - 1 generate
        z(i) <= x_and_y(i) xor u(i);
    end generate;

    process(clk) is
        variable u_v: std_logic_vector(W - 1 downto 0);
        variable index: natural range 0 to r'left;
    begin
        if rising_edge(clk) then
            index := 0;

            for i in 0 to N - 1 loop
                u_v := (others => '0');

                for j in 0 to N - 1 loop
                    if i /= j then
                        u_v := u_v xor (x(i) and y(j)) xor r(index);

                        if index = r'left then
                            index := 0;
                        else
                            index := index + 1;
                        end if;
                    end if;
                end loop;

                u(i) <= u_v;
                x_and_y(i) <= x(i) and y(i);
            end loop;
        end if;
    end process;
end;
