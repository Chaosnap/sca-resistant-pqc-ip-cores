-- Copyright (C) 2025 Patrik Dobias <xdobia13@vut.cz>
-- Released for the non-commercial use only. For licensing, please contact <malina@vut.cz>

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.types_pkg.all;
use work.math_pkg.all;

-- addition of two values masked using boolean shares
entity sec_add is
generic (
    N: natural := 2;
    W: natural := 24;
    -- iterations of Brent-Kung adder
    STAGES: natural := log2(W - 1) - 1
);
port (
    clk: in std_logic;
    rst: in std_logic;

    -- boolean sharings
    x: in slv_array_t(N - 1 downto 0)(W - 1 downto 0);
    y: in slv_array_t(N - 1 downto 0)(W - 1 downto 0);
    vld_in: in std_logic;

    -- fresh randomness
    r: in slv_array_t((3 * STAGES + 2) * (N * (N - 1) / 2) - 1 downto 0)(W - 1 downto 0);

    -- boolean sharing
    z: out slv_array_t(N - 1 downto 0)(W - 1 downto 0);
    vld_out: out std_logic
);
end;

architecture behav of sec_add is
    type array_3d_t is array (natural range <>) of slv_array_t;

    -- each iteration requires 2 AND computations + 1 initialization and 1 for finalization
    signal sec_and_x, sec_and_y, sec_and_z: array_3d_t(2 * STAGES + 2 - 1 downto 0)(N - 1 downto 0)(W - 1 downto 0);
    signal sec_and_r: array_3d_t(2 * STAGES + 2 - 1 downto 0)((N * (N - 1) / 2) - 1 downto 0)(W - 1 downto 0);

    -- `g1` and `g2` are just registered values of `g`, so the value is available for two cycles, corresponding to `sec_and` delay
    signal g, g1, g2: array_3d_t(STAGES + 2 - 1 downto 0)(N - 1 downto 0)(W - 1 downto 0);
    signal p: array_3d_t(STAGES + 1 - 1 downto 0)(N - 1 downto 0)(W - 1 downto 0);

    -- delay initial `x xor p` until outputing
    signal p_shift_reg: array_3d_t(2 * (STAGES + 2) - 1 downto 0)(N - 1 downto 0)(W - 1 downto 0);

    signal vld_shift_reg: std_logic_vector(2 * (STAGES + 2) - 1 downto 0);

    -- assigning DON'T TOUCH attribute
    attribute dont_touch: string;
    attribute dont_touch of behav: architecture is "yes";

    attribute dont_touch of g, g1, g2, p: signal is "yes";
begin
    vld_out <= vld_shift_reg(0);

    -- instantiate `sec_and` components

    sec_and_g: for i in sec_and_z'range generate
        sec_and: entity work.sec_and
        generic map (
            N => N,
            W => W
        ) port map (
            clk => clk,

            x => sec_and_x(i),
            y => sec_and_y(i),

            r => sec_and_r(i),

            z => sec_and_z(i)
        );

        sec_and_r(i) <= r(N * (N - 1) / 2 * (i + 1) - 1 downto N * (N - 1) / 2 * i);
    end generate;

    sec_and_p: process(clk) is
    begin
        if rising_edge(clk) then
            for i in 0 to N - 1 loop
                -- input assignments to `sec_and` components

                -- initial stage
                sec_and_x(0)(i) <= x(i);
                sec_and_y(0)(i) <= y(i);

                -- sec_and stages
                for j in 0 to STAGES - 1 loop
                    -- G computation
                    sec_and_x(2 * j + 1)(i) <= g(j)(i) sll (2 ** j);
                    sec_and_y(2 * j + 1)(i) <= p(j)(i);

                    -- P computation
                    sec_and_x(2 * j + 2)(i) <= p(j)(i);
                    sec_and_y(2 * j + 2)(i) <= (p(j)(i) sll (2 ** j)) xor r(j + N * (N - 1) / 2 * (sec_and_z'left + 1));
                end loop;

                -- final stage
                sec_and_x(sec_and_x'left)(i) <= g(g'left - 1)(i) sll (2 ** STAGES);
                sec_and_y(sec_and_y'left)(i) <= p(p'left)(i);
            end loop;
        end if;
    end process;

    share_g: for i in 0 to N - 1 generate
        z(i) <= p_shift_reg(0)(i) xor (g(g'left)(i) sll 1);

        -- G and P assignments

        g(0)(i) <= sec_and_z(0)(i);
        p(0)(i) <= p_shift_reg(p_shift_reg'left - 1)(i);

        gp_g: for j in 0 to STAGES - 1 generate
            g(j + 1)(i) <= g2(j)(i) xor sec_and_z(2 * j + 1)(i);
            p(j + 1)(i) <= sec_and_z(2 * j + 2)(i);
        end generate;

        g(g'left)(i) <= g2(g2'left - 1)(i) xor sec_and_z(sec_and_z'left)(i);
    end generate;

    g_p: process(clk) is
    begin
        if rising_edge(clk) then
            g1 <= g;
            g2 <= g1;
        end if;
    end process;

    p_p: process(clk) is
        variable p_v: slv_array_t(N - 1 downto 0)(W - 1 downto 0);
    begin
        if rising_edge(clk) then
            for i in 0 to N - 1 loop
                p_v(i) := x(i) xor y(i);
            end loop;

            p_shift_reg <= p_v & p_shift_reg(p_shift_reg'left downto 1);
        end if;
    end process;

    vld_p: process(clk) is
    begin
        if rising_edge(clk) then
            if rst = '1' then
                vld_shift_reg <= (others => '0');
            else
                vld_shift_reg <= vld_in & vld_shift_reg(vld_shift_reg'left downto 1);
            end if;
        end if;
    end process;
end;
