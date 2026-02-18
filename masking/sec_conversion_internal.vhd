-- Copyright (C) 2025 Patrik Dobias <xdobia13@vut.cz>
-- Released for the non-commercial use only. For licensing, please contact <malina@vut.cz>

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.params_pkg.all;
use work.reduce_pkg.all;
use work.types_pkg.all;

-- a2b and b2a conversions
entity sec_conversion_internal is
port (
    clk: in std_logic;
    rst: in std_logic;

    -- 378b randomness for `sec_add_0`, 350b randomness for `sec_add_1` and 2x24b for initial refreshes
    random: in std_logic_vector(775 downto 0);
    random_q: in std_logic_vector(23 downto 0);

    -- 4 downto 3 indicates security level
    -- "11" -> no bound check
    -- 2 downto 0 indicates type of bound check
    -- "00" -> gamma1 - beta
    -- "01" -> gamma2 - beta
    -- "10" -> gamma2
    -- valid with `coeff_in_vld`
    bound_check_mode: in std_logic_vector(3 downto 0) := "1100";

    coeff_in: in slv_array_t(1 downto 0)(23 downto 0);
    -- 5 downto 4 indicates security level
    -- 3 downto 0 indicates conversion mode
    -- "0000" -> kyber a2b
    -- "0100" -> kyber b2a
    -- "1000" -> dilithium a2b
    -- "1001" -> dilithium a2b (no modular reduction) - x0 + x1 ∈ <0; 2(Q - 1)> => x0 ^ x1 ∈ <2^k - Q;2^k + Q - 2>
    -- "1100" -> dilithium b2a
    coeff_in_mode: in std_logic_vector(3 downto 0);
    coeff_in_vld: in std_logic;

    coeff_out: out slv_array_t(1 downto 0)(23 downto 0);
    -- copies `coeff_in_mode`
    coeff_out_mode: out std_logic_vector(3 downto 0);
    coeff_out_vld: out std_logic
);
end;

architecture behav of sec_conversion_internal is
    constant SEC_ADD_DELAY: natural := 13;

    signal sec_add_0_x, sec_add_0_y: slv_array_t(1 downto 0)(26 downto 0);
    signal sec_add_0_r: slv_array_t(13 downto 0)(26 downto 0);
    signal sec_add_0_z: slv_array_t(1 downto 0)(26 downto 0);
    signal sec_add_0_vld_in, sec_add_0_vld_out: std_logic;

    signal sec_add_1_x, sec_add_1_y: slv_array_t(1 downto 0)(24 downto 0);
    signal sec_add_1_r: slv_array_t(13 downto 0)(24 downto 0);
    signal sec_add_1_z: slv_array_t(1 downto 0)(24 downto 0);
    signal sec_add_1_vld_in, sec_add_1_vld_out: std_logic;

    signal sec_add_1_z_a, sec_add_1_z_b: slv_array_t(1 downto 0)(23 downto 0);
    signal sec_add_1_z_mode_r: std_logic_vector(3 downto 0);
    signal sec_add_1_vld_out_r: std_logic;

    signal mode_shift_reg: slv_array_t(2 * SEC_ADD_DELAY - 1 downto 0)(3 downto 0);
    signal bound_check_mode_shift_reg: slv_array_t(2 * SEC_ADD_DELAY - 1 downto 0)(3 downto 0);

    signal random_shift_reg: slv_array_t(2 * SEC_ADD_DELAY + 1 - 1 downto 0)(23 downto 0);

    -- assigning DON'T TOUCH attribute
    attribute dont_touch: string;
    attribute dont_touch of behav: architecture is "yes";

    attribute dont_touch of sec_add_0_x, sec_add_0_y: signal is "yes";
    attribute dont_touch of sec_add_1_x, sec_add_1_y: signal is "yes";
    attribute dont_touch of sec_add_0_z, sec_add_1_z: signal is "yes";
    attribute dont_touch of sec_add_1_z_a, sec_add_1_z_b: signal is "yes";
begin
    coeff_p: process(clk) is
    begin
        if rising_edge(clk) then
            -- sec_add_1_z_mode_r(2) = '0' => a2b -> outputing boolean shares (x = x[0] ^ x[1])
            if sec_add_1_z_mode_r(2) = '0' then
                coeff_out(0) <= sec_add_1_z_b(0);
                coeff_out(1) <= sec_add_1_z_b(1);
            -- sec_add_1_z_mode_r(2) = '1' => b2a -> outputing arithmetic shares (x = (x[0] + x[1]) % Q)
            else
                coeff_out(0) <= sec_add_1_z_a(0) xor sec_add_1_z_a(1);
                coeff_out(1) <= random_shift_reg(0);
            end if;

            coeff_out_mode <= sec_add_1_z_mode_r;

            if rst = '1' then
                coeff_out_vld <= '0';
            else
                coeff_out_vld <= sec_add_1_vld_out_r;
            end if;
        end if;
    end process;

    sec_add_0: entity work.sec_add
    generic map (
        W => 27 -- 2x13b for kyber coeffs + 1b to stop carry
    )
    port map (
        clk => clk,
        rst => rst,

        x => sec_add_0_x,
        y => sec_add_0_y,
        vld_in => sec_add_0_vld_in,

        r => sec_add_0_r,

        z => sec_add_0_z,
        vld_out => sec_add_0_vld_out
    );

    sec_add_0_random_g: for i in 0 to 13 generate
        sec_add_0_r(i) <= random(74 + 27 * i downto 48 + 27 * i);
    end generate;

    sec_add_0_p: process(clk) is
        variable x: std_logic_vector(24 downto 0);
        variable bound: std_logic_vector(23 downto 0);
    begin
        if rising_edge(clk) then
            -- sec_add_0_x

            -- a2b
            if coeff_in_mode(2) = '0' then
                -- `sec_exp`
                sec_add_0_x(0) <= '0' & (coeff_in(0)(23 downto 12) xor random(23 downto 12)) & coeff_in_mode(3) & coeff_in_mode(3) & (coeff_in(0)(11 downto 0) xor random(11 downto 0));
                sec_add_0_x(1) <= '0' & random(23 downto 12) & "00" & random(11 downto 0);
            -- b2a
            else
                sec_add_0_x(0) <= '0' & coeff_in(0)(23 downto 12) & coeff_in_mode(3) & coeff_in_mode(3) & coeff_in(0)(11 downto 0);
                sec_add_0_x(1) <= '0' & coeff_in(1)(23 downto 12) & "00" & coeff_in(1)(11 downto 0);
            end if;

            -- sec_add_0_y

            x := (others => '0');

            -- a2b
            if coeff_in_mode(2) = '0' then
                x(23 downto 0) := coeff_in(1)(23 downto 0);
            -- b2a
            else
                -- compute q - random
                case coeff_in_mode is
                    when "0100" => x := '1' & x"a02d01";
                    when "1100" => x := '0' & x"ffc001";
                    when others =>
                end case;

                x := std_logic_vector(unsigned(x) - (unsigned(random_q(23 downto 12)) & '0' & unsigned(random_q(11 downto 0))));
                x(23 downto 0) := x(24 downto 13) & x(11 downto 0);
            end if;

            -- compute x(1) - Q + 2^k either for 2 kyber coefficients or 1 dilithium coefficient
            if coeff_in_mode(3) = '0' then
                bound := x"2ff2ff";
            else
                bound := x"801fff";
            end if;

            x := std_logic_vector((unsigned(x(23 downto 12)) & '1' & unsigned(x(11 downto 0))) + (unsigned(bound(23 downto 12)) & '0' & unsigned(bound(11 downto 0))));

            -- `sec_exp`
            -- subtraction of Q from <0, Q) will always result in negative number, so make sure, the sign bits are set correctly (idk why `x` does not have correct signs for kyber)
            sec_add_0_y(0) <= '1' & (x(24 downto 13) xor random(47 downto 36)) & '0' & (not coeff_in_mode(3)) & (x(11 downto 0) xor random(35 downto 24));
            sec_add_0_y(1) <= '0' & random(47 downto 36) & "00" & random(35 downto 24);

            if rst = '1' then
                sec_add_0_vld_in <= '0';
            else
                sec_add_0_vld_in <= coeff_in_vld;
            end if;
        end if;
    end process;

    sec_add_1: entity work.sec_add
    generic map (
        W => 25 -- 2x12b for kyber coeffs + 1b to stop carry
    )
    port map (
        clk => clk,
        rst => rst,

        x => sec_add_1_x,
        y => sec_add_1_y,
        vld_in => sec_add_1_vld_in,

        r => sec_add_1_r,

        z => sec_add_1_z,
        vld_out => sec_add_1_vld_out
    );

    sec_add_1_random_g: for i in 0 to 13 generate
        sec_add_1_r(i) <= random(450 + 25 * i downto 426 + 25 * i);
    end generate;

    sec_add_1_p: process(clk) is
    begin
        if rising_edge(clk) then
            -- ignore sign bits as the computation does not differ mod 2^k
            sec_add_1_x(0) <= sec_add_0_z(0)(25 downto 14) & mode_shift_reg(SEC_ADD_DELAY)(3) & sec_add_0_z(0)(11 downto 0);
            sec_add_1_x(1) <= sec_add_0_z(1)(25 downto 14) & '0' & sec_add_0_z(1)(11 downto 0);

            -- check what values are negative and thus require addition of Q
            for i in 0 to 1 loop
                -- kyber
                if mode_shift_reg(SEC_ADD_DELAY)(3) = '0' then
                    if bound_check_mode_shift_reg(SEC_ADD_DELAY)(3 downto 2) = "11" then
                        if sec_add_0_z(i)(12) = '1' then
                            sec_add_1_y(i)(12 downto 0) <= '0' & x"d01";
                        else
                            sec_add_1_y(i)(12 downto 0) <= (others => '0');
                        end if;

                        if sec_add_0_z(i)(26) = '1' then
                            sec_add_1_y(i)(24 downto 13) <= x"d01";
                        else
                            sec_add_1_y(i)(24 downto 13) <= (others => '0');
                        end if;
                    else
                        if i = 0 then
                            if sec_add_0_z(i)(12) = '1' then
                                sec_add_1_y(i)(12 downto 0) <= '0' & x"f01";
                            else
                                sec_add_1_y(i)(12 downto 0) <= (others => '0');
                            end if;

                            if sec_add_0_z(i)(26) = '1' then
                                sec_add_1_y(i)(24 downto 13) <= x"f01";
                            else
                                sec_add_1_y(i)(24 downto 13) <= (others => '0');
                            end if;
                        else
                            if sec_add_0_z(i)(12) = '1' then
                                sec_add_1_y(i)(12 downto 0) <= '0' & x"681";
                            else
                                sec_add_1_y(i)(12 downto 0) <= '0' & x"980";
                            end if;

                            if sec_add_0_z(i)(26) = '1' then
                                sec_add_1_y(i)(24 downto 13) <= x"681";
                            else
                                sec_add_1_y(i)(24 downto 13) <= x"980";
                            end if;
                        end if;
                    end if;
                -- dilithium
                else
                    if mode_shift_reg(SEC_ADD_DELAY) = "1001" then
                        sec_add_1_y(0) <= (others => '0');
                        sec_add_1_y(1) <= (others => '0');
                    else
                        if i = 0 then
                            if sec_add_0_z(i)(26) = '1' then
                                sec_add_1_y(i) <= '0' & x"ffc001";

                                if bound_check_mode_shift_reg(SEC_ADD_DELAY)(3 downto 2) /= "11" then
                                    -- for bound check modes ((2^24 - (2*bound - 1) + Q) ^ (2^24 - (2*bound - 1)))
                                    case bound_check_mode_shift_reg(SEC_ADD_DELAY)(1 downto 0) is
                                        when "00" => sec_add_1_y(i) <= std_logic_vector_for_sec_level(bound_check_mode_shift_reg(SEC_ADD_DELAY)(3 downto 2), '1' & x"0fc003", '1' & x"3fc003", '1' & x"3fc003");
                                        when "01" => sec_add_1_y(i) <= std_logic_vector_for_sec_level(bound_check_mode_shift_reg(SEC_ADD_DELAY)(3 downto 2), '1' & x"03c003", '1' & x"1fc003", '1' & x"1fc003");
                                        when "10" => sec_add_1_y(i) <= std_logic_vector_for_sec_level(bound_check_mode_shift_reg(SEC_ADD_DELAY)(3 downto 2), '1' & x"03c003", '1' & x"1fc003", '1' & x"1fc003");
                                        when others =>
                                    end case;
                                end if;
                            else
                                sec_add_1_y(i) <= (others => '0');
                            end if;
                        else
                            if sec_add_0_z(i)(26) = '1' then
                                sec_add_1_y(i) <= '0' & x"ffc001";

                                if bound_check_mode_shift_reg(SEC_ADD_DELAY)(3 downto 2) /= "11" then
                                    -- for bound check modes (2^24 - (2*bound - 1) + Q)
                                    case bound_check_mode_shift_reg(SEC_ADD_DELAY)(1 downto 0) is
                                        when "00" => sec_add_1_y(i) <= std_logic_vector_for_sec_level(bound_check_mode_shift_reg(SEC_ADD_DELAY)(3 downto 2), '0' & x"f7c09e", '0' & x"dfc18a", '0' & x"dfc0f2");
                                        when "01" => sec_add_1_y(i) <= std_logic_vector_for_sec_level(bound_check_mode_shift_reg(SEC_ADD_DELAY)(3 downto 2), '0' & x"f9e89e", '0' & x"efc38a", '0' & x"efc2f2");
                                        when "10" => sec_add_1_y(i) <= std_logic_vector_for_sec_level(bound_check_mode_shift_reg(SEC_ADD_DELAY)(3 downto 2), '0' & x"f9e802", '0' & x"efc202", '0' & x"efc202");
                                        when others =>
                                    end case;
                                end if;
                            else
                                if bound_check_mode_shift_reg(SEC_ADD_DELAY)(3 downto 2) /= "11" then
                                    -- for bound check modes 2^24 - (2*bound - 1)
                                    case bound_check_mode_shift_reg(SEC_ADD_DELAY)(1 downto 0) is
                                        when "00" => sec_add_1_y(i) <= std_logic_vector_for_sec_level(bound_check_mode_shift_reg(SEC_ADD_DELAY)(3 downto 2), '1' & x"f8009d", '1' & x"e00189", '1' & x"e000f1");
                                        when "01" => sec_add_1_y(i) <= std_logic_vector_for_sec_level(bound_check_mode_shift_reg(SEC_ADD_DELAY)(3 downto 2), '1' & x"fa289d", '1' & x"f00389", '1' & x"f002f1");
                                        when "10" => sec_add_1_y(i) <= std_logic_vector_for_sec_level(bound_check_mode_shift_reg(SEC_ADD_DELAY)(3 downto 2), '1' & x"fa2801", '1' & x"f00201", '1' & x"f00201");
                                        when others => sec_add_1_y(i) <= (others => '0');
                                    end case;
                                else
                                    sec_add_1_y(i) <= (others => '0');
                                end if;
                            end if;
                        end if;
                    end if;
                end if;
            end loop;

            if rst = '1' then
                sec_add_1_vld_in <= '0';
            else
                if mode_shift_reg(SEC_ADD_DELAY) /= "1001" then
                    sec_add_1_vld_in <= sec_add_0_vld_out;
                else
                    sec_add_1_vld_in <= '0';
                end if;
            end if;
        end if;
    end process;

    -- make sure there are never secret data before combining the shares
    shares_p: process(clk) is
    begin
        if rising_edge(clk) then
            if sec_add_1_vld_out = '1' then
                if mode_shift_reg(0)(2) = '1' then
                    sec_add_1_z_a(0) <= (sec_add_1_z(0)(24 downto 13) & sec_add_1_z(0)(11 downto 0)) xor random(23 downto 0);
                    sec_add_1_z_a(1) <= (sec_add_1_z(1)(24 downto 13) & sec_add_1_z(1)(11 downto 0)) xor random(23 downto 0);
                else
                    sec_add_1_z_b(0) <= sec_add_1_z(0)(24 downto 13) & sec_add_1_z(0)(11 downto 0);
                    sec_add_1_z_b(1) <= sec_add_1_z(1)(24 downto 13) & sec_add_1_z(1)(11 downto 0);
                end if;

                sec_add_1_z_mode_r <= mode_shift_reg(0);
            elsif sec_add_0_vld_out = '1' and mode_shift_reg(SEC_ADD_DELAY) = "1001" then
                sec_add_1_z_b(0) <= sec_add_0_z(0)(25 downto 14) & sec_add_0_z(0)(11 downto 0);
                sec_add_1_z_b(1) <= sec_add_0_z(1)(25 downto 14) & sec_add_0_z(1)(11 downto 0);

                sec_add_1_z_mode_r <= mode_shift_reg(SEC_ADD_DELAY);
            end if;

            if rst = '1' then
                sec_add_1_vld_out_r <= '0';
            else
                if sec_add_1_vld_out = '1' or (sec_add_0_vld_out = '1' and mode_shift_reg(SEC_ADD_DELAY) = "1001") then
                    sec_add_1_vld_out_r <= '1';
                else
                    sec_add_1_vld_out_r <= '0';
                end if;
            end if;
        end if;
    end process;

    mode_p: process(clk) is
    begin
        if rising_edge(clk) then
            if rst = '1' then
                mode_shift_reg <= (others => "0000");
                bound_check_mode_shift_reg <= (others => "0000");
            else
                mode_shift_reg <= coeff_in_mode & mode_shift_reg(mode_shift_reg'left downto 1);
                bound_check_mode_shift_reg <= bound_check_mode & bound_check_mode_shift_reg(bound_check_mode_shift_reg'left downto 1);
            end if;
        end if;
    end process;

    random_p: process(clk) is
    begin
        if rising_edge(clk) then
            random_shift_reg <= random_q & random_shift_reg(random_shift_reg'left downto 1);
        end if;
    end process;
end;
