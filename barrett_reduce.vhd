-- Copyright (C) 2024 Patrik Dobias <xdobia13@vut.cz>
-- Released for the non-commercial use only. For licensing, please contact <malina@vut.cz>

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.params_pkg.all;

-- reduces number from range <0; Q * Q) to <0; Q)
-- for kyber it reduces two coefficients (47 downto 24) & (23 downto 0) to (23 downto 12) & (11 downto 0)
-- for dilithium it reduces one coefficient (45 downto 0) to (23 downto 0)
-- output is valid with one clock cycle delay
entity barrett_reduce is
port (
    clk: in std_logic;
    rst: in std_logic;

    -- '0' => kyber reduction, '1' => dilithium reduction
    mode: in std_logic;

    x: in std_logic_vector(47 downto 0);
    z: out std_logic_vector(23 downto 0);

    vld_in: in std_logic;
    vld_out: out std_logic
);
end;

library ieee;
use ieee.std_logic_1164.all;

entity dilithium_csa is
port (
    x: in std_logic_vector(45 downto 0);

    s0: out std_logic_vector(25 downto 0);
    c0: out std_logic_vector(25 downto 0);

    s1: out std_logic_vector(25 downto 0);
    c1: out std_logic_vector(25 downto 0)
);
end;

library ieee;
use ieee.std_logic_1164.all;

entity kyber_csa is
port (
    x: in std_logic_vector(23 downto 0);

    s3: out std_logic_vector(14 downto 0);
    c3: out std_logic_vector(14 downto 0);

    s4: out std_logic_vector(14 downto 0);
    c4: out std_logic_vector(14 downto 0)
);
end;

architecture behav of barrett_reduce is
    -- partial sums and carries from dilithium CSA
    signal dilithium_s0, dilithium_s1: std_logic_vector(25 downto 0);
    signal dilithium_c0, dilithium_c1: std_logic_vector(25 downto 0);

    -- partial sums and carries from kyber CSAs
    signal kyber0_s0, kyber0_s1: std_logic_vector(14 downto 0);
    signal kyber0_c0, kyber0_c1: std_logic_vector(14 downto 0);

    signal kyber1_s0, kyber1_s1: std_logic_vector(14 downto 0);
    signal kyber1_c0, kyber1_c1: std_logic_vector(14 downto 0);

    -- partial sums and carries chosen according to selected mode
    signal s0, s1: std_logic_vector(29 downto 0);
    signal c0, c1: std_logic_vector(29 downto 0);
    signal s0_reg, s1_reg: std_logic_vector(29 downto 0);
    signal c0_reg, c1_reg: std_logic_vector(29 downto 0);

    -- carries for addition of partial results during dilithium mode computation
    signal cpa0_c, cpa1_c, cpa2_c, cpa3_c: std_logic_vector(2 downto 0);
    -- sums of coefficients with additional reduction by q
    -- cpa0 => -q, cpa1 => -, cpa2 => +q, cpa3 => +2q
    signal cpa0, cpa1, cpa2, cpa3: std_logic_vector(29 downto 0);
    signal cpa0_reg, cpa1_reg, cpa2_reg, cpa3_reg: std_logic_vector(29 downto 0);

    -- modulus depending on selected mode
    signal q: std_logic_vector(23 downto 0);

    signal reduced, reduced_reg: std_logic_vector(23 downto 0);

    signal mode_shift_reg: std_logic_vector(1 downto 0);
    signal vld_shift_reg: std_logic_vector(2 downto 0);
begin
    z <= reduced_reg;
    vld_out <= vld_shift_reg(0);

    dilithium_csa: entity work.dilithium_csa
    port map (
        x => x(45 downto 0),

        s0 => dilithium_s0,
        c0 => dilithium_c0,

        s1 => dilithium_s1,
        c1 => dilithium_c1
    );

    kyber_csa0: entity work.kyber_csa
    port map (
        x => x(23 downto 0),

        s3 => kyber0_s0,
        c3 => kyber0_c0,

        s4 => kyber0_s1,
        c4 => kyber0_c1
    );

    kyber_csa1: entity work.kyber_csa
    port map (
        x => x(47 downto 24),

        s3 => kyber1_s0,
        c3 => kyber1_c0,

        s4 => kyber1_s1,
        c4 => kyber1_c1
    );

    -- select partial results
    -- store dilithium results in order so that it can share 15-bit adders that are used to sum kyber's first coefficient
    s0 <= dilithium_s0(25) & dilithium_s0(25 downto 12) & (28 downto 26 => '0') & dilithium_s0(11 downto 0) when mode = '1' else kyber1_s0 & kyber0_s0;
    c0 <= dilithium_c0(25) & dilithium_c0(25 downto 11) & (28 downto 26 => '0') & dilithium_c0(10 downto 0) when mode = '1' else kyber1_c0 & kyber0_c0;

    s1 <= dilithium_s1(25) & dilithium_s1(25 downto 12) & (28 downto 26 => '0') & dilithium_s1(11 downto 0) when mode = '1' else kyber1_s1 & kyber0_s1;
    c1 <= dilithium_c1(25) & dilithium_c1(25 downto 11) & (28 downto 26 => '0') & dilithium_c1(10 downto 0) when mode = '1' else kyber1_c1 & kyber0_c1;

    -- select correct modulus
    q <= DILITHIUM_Q when mode_shift_reg(1) = '1' else KYBER_Q & KYBER_Q;

    -- compute first kyber coefficient or lower 12 bits of dilithium coefficient
    cpa0(14 downto 0) <= std_logic_vector(signed(s0_reg(14 downto 0)) + signed(s1_reg(14 downto 0)) +
        signed(c0_reg(13 downto 0) & '0') + signed(c1_reg(13 downto 0) & '0') + signed('0' & q(11 downto 0)));
    cpa1(14 downto 0) <= std_logic_vector(signed(s0_reg(14 downto 0)) + signed(s1_reg(14 downto 0)) +
        signed(c0_reg(13 downto 0) & '0') + signed(c1_reg(13 downto 0) & '0'));
    cpa2(14 downto 0) <= std_logic_vector(signed(s0_reg(14 downto 0)) + signed(s1_reg(14 downto 0)) +
        signed(c0_reg(13 downto 0) & '0') + signed(c1_reg(13 downto 0) & '0') - signed('0' & q(11 downto 0)));
    cpa3(14 downto 0) <= std_logic_vector(signed(s0_reg(14 downto 0)) + signed(s1_reg(14 downto 0)) +
        signed(c0_reg(13 downto 0) & '0') + signed(c1_reg(13 downto 0) & '0') - signed('0' & q(11 downto 0) & '0'));

    -- store carry during dilithium mode
    cpa0_c <= cpa0(14 downto 12) when mode_shift_reg(1) = '1' else "000";
    cpa1_c <= cpa1(14 downto 12) when mode_shift_reg(1) = '1' else "000";
    cpa2_c <= cpa2(14 downto 12) when mode_shift_reg(1) = '1' else "000";
    cpa3_c <= cpa3(14 downto 12) when mode_shift_reg(1) = '1' else "000";

    -- compute second kyber coefficient or upper 12 bits of dilithium coefficient
    cpa0(29 downto 15) <= std_logic_vector(signed(s0_reg(29 downto 15)) + signed(s1_reg(29 downto 15)) +
        signed(c0_reg(28 downto 14)) + signed(c1_reg(28 downto 14)) + signed(cpa0_c) + signed('0' & q(23 downto 12)));
    cpa1(29 downto 15) <= std_logic_vector(signed(s0_reg(29 downto 15)) + signed(s1_reg(29 downto 15)) +
        signed(c0_reg(28 downto 14)) + signed(c1_reg(28 downto 14)) + signed(cpa1_c));
    cpa2(29 downto 15) <= std_logic_vector(signed(s0_reg(29 downto 15)) + signed(s1_reg(29 downto 15)) +
        signed(c0_reg(28 downto 14)) + signed(c1_reg(28 downto 14)) + signed(cpa2_c) - signed('0' & q(23 downto 12)));
    cpa3(29 downto 15) <= std_logic_vector(signed(s0_reg(29 downto 15)) + signed(s1_reg(29 downto 15)) +
        signed(c0_reg(28 downto 14)) + signed(c1_reg(28 downto 14)) + signed(cpa3_c) - signed('0' & q(23 downto 12) & '0'));

    -- select coefficients based on mode that are in range <0; Q)
    reduced(11 downto 0) <= cpa0_reg(11 downto 0) when ((mode_shift_reg(0) and cpa1_reg(29)) or (not mode_shift_reg(0) and cpa1_reg(14))) = '1' else
        cpa1_reg(11 downto 0) when ((mode_shift_reg(0) and cpa2_reg(29)) or (not mode_shift_reg(0) and cpa2_reg(14))) = '1' else
        cpa2_reg(11 downto 0) when ((mode_shift_reg(0) and cpa3_reg(29)) or (not mode_shift_reg(0) and cpa3_reg(14))) = '1' else
        cpa3_reg(11 downto 0);
    reduced(23 downto 12) <= cpa0_reg(26 downto 15) when cpa1_reg(29) = '1' else
        cpa1_reg(26 downto 15) when cpa2_reg(29) = '1' else
        cpa2_reg(26 downto 15) when cpa3_reg(29) = '1' else
        cpa3_reg(26 downto 15);

    process(clk) is
    begin
        if rising_edge(clk) then
            if vld_in = '1' then
                s0_reg <= s0;
                s1_reg <= s1;
                c0_reg <= c0;
                c1_reg <= c1;
            end if;

            if vld_shift_reg(vld_shift_reg'left) = '1' then
                cpa0_reg <= cpa0;
                cpa1_reg <= cpa1;
                cpa2_reg <= cpa2;
                cpa3_reg <= cpa3;
            end if;

            reduced_reg <= reduced;

            mode_shift_reg <= mode & mode_shift_reg(mode_shift_reg'left downto 1);

            if rst = '1' then
                vld_shift_reg <= (others => '0');
            else
                vld_shift_reg <= vld_in & vld_shift_reg(vld_shift_reg'left downto 1);
            end if;
        end if;
    end process;
end;

architecture behav of dilithium_csa is
    signal x0, x1, x2, x3, x4, x5: std_logic_vector(25 downto 0);
begin
    x0 <= "000" & x(22 downto 0);
    x1 <= "000" & (not x(45 downto 23));
    x2 <= "000" & x(32 downto 23) & (not x(45 downto 33));
    x3 <= "000" & x(42 downto 33) & "0000000000" & (not x(45 downto 43));
    x4 <= "0000000000" & x(45 downto 43) & "0000000000000";
    x5 <= "11011111111101111111111011";

    s0 <= x0 xor x1 xor x2;
    c0 <= (x0 and x1) or (x0 and x2) or (x1 and x2);

    s1 <= x3 xor x4 xor x5;
    c1 <= (x3 and x4) or (x3 and x5) or (x4 and x5);
end;

architecture behav of kyber_csa is
    signal x0, x1, x2, x3, x4, x5, x6, x7, x8: std_logic_vector(14 downto 0);

    signal s0, s1, s2: std_logic_vector(14 downto 0);
    signal c0, c1, c2: std_logic_vector(14 downto 0);
begin
    x0 <= "000" & x(11 downto 0);
    x1 <= "0000" & x(13) & x(12) & x(12) & (not x(19 downto 12));
    x2 <= "0000" & x(17) & x(13) & x(17) & (not (x(22 downto 18) & x(16 downto 14)));
    x3 <= "0000" & x(19) & x(15) & x(19) & (not (x(23 downto 19) & x(17) & x(17) & x(17)));
    x4 <= "0000" & (not x(15)) & x(18) & x(21) & '0' & (not (x(23 downto 20) & x(18) & x(18) & x(18)));
    x5 <= "0000" & (not x(16)) & x(19) & (not x(14)) & "000" & (not (x(23) & x(22) & x(19) & x(20) & x(19)));
    x6 <= "0000" & (not x(18)) & '0' & (not x(18)) & "0000" & (not (x(23) & x(21) & x(21) & x(20)));
    x7 <= "000000" & (not x(21)) & "00000" & (not x(22)) & "00";
    x8 <= "110110" & (not x(23)) & "01010010";

    s0 <= x0 xor x1 xor x2;
    c0 <= (x0 and x1) or (x0 and x2) or (x1 and x2);

    s1 <= x3 xor x4 xor x5;
    c1 <= (x3 and x4) or (x3 and x5) or (x4 and x5);

    s2 <= x6 xor x7 xor x8;
    c2 <= (x6 and x7) or (x6 and x8) or (x7 and x8);

    s3 <= s0 xor s1 xor s2;
    c3 <= (s0 and s1) or (s0 and s2) or (s1 and s2);

    s4 <= (c0(13 downto 0) & '0') xor (c1(13 downto 0) & '0') xor (c2(13 downto 0) & '0');
    c4 <= ((c0(13 downto 0) & '0') and (c1(13 downto 0) & '0')) or ((c0(13 downto 0) & '0') and (c2(13 downto 0) & '0')) or ((c1(13 downto 0) & '0') and (c2(13 downto 0) & '0'));
end;
