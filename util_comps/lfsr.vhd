-- Copyright (C) 2024 Patrik Dobias <xdobia13@vut.cz>
-- Released for the non-commercial use only. For licensing, please contact <malina@vut.cz>

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity lfsr is
generic (
    SEED1_BITS: natural := 31;
    SEED2_BITS: natural := 32;
    RANDOM_BITS: natural := 8
);
port (
    rst: in std_logic;
    clk: in std_logic;

    en: in std_logic := '1';

    -- use 2 seeds with different bit lenghts (non divisible) to increase period of pseudo-random data
    seed1: in std_logic_vector(SEED1_BITS - 1 downto 0);
    seed2: in std_logic_vector(SEED2_BITS - 1 downto 0);
    random: out std_logic_vector(RANDOM_BITS - 1 downto 0)
);
end;

architecture behav of lfsr is
    function lfsr_taps(x: std_logic_vector) return std_logic is
    begin
        case x'length is
            when 3 => return x(1) xor x(0);
            when 4 => return x(1) xor x(0);
            when 5 => return x(2) xor x(0);
            when 6 => return x(1) xor x(0);
            when 7 => return x(1) xor x(0);
            when 8 => return x(4) xor x(3) xor x(2) xor x(0);
            when 9 => return x(4) xor x(0);
            when 10 => return x(3) xor x(0);
            when 11 => return x(2) xor x(0);
            when 12 => return x(11) xor x(8) xor x(6) xor x(0);
            when 13 => return x(12) xor x(10) xor x(9) xor x(0);
            when 14 => return x(13) xor x(11) xor x(9) xor x(0);
            when 15 => return x(1) xor x(0);
            when 16 => return x(12) xor x(3) xor x(1) xor x(0);
            when 17 => return x(3) xor x(0);
            when 18 => return x(7) xor x(0);
            when 19 => return x(18) xor x(17) xor x(13) xor x(0);
            when 20 => return x(3) xor x(0);
            when 21 => return x(2) xor x(0);
            when 22 => return x(1) xor x(0);
            when 23 => return x(5) xor x(0);
            when 24 => return x(7) xor x(2) xor x(1) xor x(0);
            when 25 => return x(3) xor x(0);
            when 26 => return x(25) xor x(24) xor x(20) xor x(0);
            when 27 => return x(26) xor x(25) xor x(22) xor x(0);
            when 28 => return x(3) xor x(0);
            when 29 => return x(2) xor x(0);
            when 30 => return x(29) xor x(26) xor x(24) xor x(0);
            when 31 => return x(3) xor x(0);
            when 32 => return x(31) xor x(30) xor x(10) xor x(0);
            when 33 => return x(13) xor x(0);
            when 34 => return x(33) xor x(32) xor x(7) xor x(0);
            when 35 => return x(2) xor x(0);
            when 36 => return x(11) xor x(0);
            when 37 => return x(36) xor x(35) xor x(34) xor x(33) xor x(32) xor x(0);
            when 38 => return x(37) xor x(33) xor x(32) xor x(0);
            when 39 => return x(4) xor x(0);
            when 40 => return x(21) xor x(19) xor x(2) xor x(0);
            when 41 => return x(3) xor x(0);
            when 42 => return x(23) xor x(22) xor x(1) xor x(0);
            when 43 => return x(6) xor x(5) xor x(1) xor x(0);
            when 44 => return x(27) xor x(26) xor x(1) xor x(0);
            when 45 => return x(4) xor x(3) xor x(1) xor x(0);
            when 46 => return x(21) xor x(20) xor x(1) xor x(0);
            when 47 => return x(5) xor x(0);
            when 48 => return x(28) xor x(27) xor x(1) xor x(0);
            when 49 => return x(9) xor x(0);
            when 50 => return x(27) xor x(26) xor x(1) xor x(0);
            when 51 => return x(16) xor x(15) xor x(1) xor x(0);
            when 52 => return x(3) xor x(0);
            when 53 => return x(16) xor x(15) xor x(1) xor x(0);
            when 54 => return x(37) xor x(36) xor x(1) xor x(0);
            when 55 => return x(24) xor x(0);
            when 56 => return x(22) xor x(21) xor x(1) xor x(0);
            when 57 => return x(7) xor x(0);
            when 58 => return x(19) xor x(0);
            when 59 => return x(22) xor x(21) xor x(1) xor x(0);
            when 60 => return x(1) xor x(0);
            when 61 => return x(16) xor x(15) xor x(1) xor x(0);
            when 62 => return x(57) xor x(56) xor x(1) xor x(0);
            when 63 => return x(1) xor x(0);
            when 64 => return x(4) xor x(3) xor x(1) xor x(0);
            when 65 => return x(18) xor x(0);
            when 66 => return x(10) xor x(9) xor x(1) xor x(0);
            when 67 => return x(10) xor x(9) xor x(1) xor x(0);
            when 68 => return x(9) xor x(0);
            when 69 => return x(29) xor x(27) xor x(2) xor x(0);
            when 70 => return x(16) xor x(15) xor x(1) xor x(0);
            when 71 => return x(6) xor x(0);
            when 72 => return x(53) xor x(47) xor x(6) xor x(0);
            when 73 => return x(25) xor x(0);
            when 74 => return x(16) xor x(15) xor x(1) xor x(0);
            when 75 => return x(11) xor x(10) xor x(1) xor x(0);
            when 76 => return x(36) xor x(35) xor x(1) xor x(0);
            when 77 => return x(31) xor x(30) xor x(1) xor x(0);
            when 78 => return x(20) xor x(19) xor x(1) xor x(0);
            when 79 => return x(9) xor x(0);
            when 80 => return x(38) xor x(37) xor x(1) xor x(0);
            when 81 => return x(4) xor x(0);
            when 82 => return x(38) xor x(35) xor x(3) xor x(0);
            when 83 => return x(46) xor x(45) xor x(1) xor x(0);
            when 84 => return x(13) xor x(0);
            when 85 => return x(28) xor x(27) xor x(1) xor x(0);
            when 86 => return x(13) xor x(12) xor x(1) xor x(0);
            when 87 => return x(13) xor x(0);
            when 88 => return x(72) xor x(71) xor x(1) xor x(0);
            when 89 => return x(38) xor x(0);
            when 90 => return x(19) xor x(18) xor x(1) xor x(0);
            when 91 => return x(84) xor x(83) xor x(1) xor x(0);
            when 92 => return x(13) xor x(12) xor x(1) xor x(0);
            when 93 => return x(2) xor x(0);
            when 94 => return x(21) xor x(0);
            when 95 => return x(11) xor x(0);
            when 96 => return x(49) xor x(47) xor x(2) xor x(0);
            when 97 => return x(6) xor x(0);
            when 98 => return x(11) xor x(0);
            when 99 => return x(47) xor x(45) xor x(2) xor x(0);
            when 100 => return x(37) xor x(0);
            when 101 => return x(7) xor x(6) xor x(1) xor x(0);
            when 102 => return x(67) xor x(66) xor x(1) xor x(0);
            when 103 => return x(9) xor x(0);
            when 104 => return x(11) xor x(10) xor x(1) xor x(0);
            when 105 => return x(16) xor x(0);
            when 106 => return x(15) xor x(0);
            when 107 => return x(65) xor x(63) xor x(2) xor x(0);
            when 108 => return x(31) xor x(0);
            when 109 => return x(7) xor x(6) xor x(1) xor x(0);
            when 110 => return x(13) xor x(12) xor x(1) xor x(0);
            when 111 => return x(10) xor x(0);
            when 112 => return x(45) xor x(43) xor x(2) xor x(0);
            when 113 => return x(9) xor x(0);
            when 114 => return x(82) xor x(81) xor x(1) xor x(0);
            when 115 => return x(15) xor x(14) xor x(1) xor x(0);
            when 116 => return x(71) xor x(70) xor x(1) xor x(0);
            when 117 => return x(20) xor x(18) xor x(2) xor x(0);
            when 118 => return x(33) xor x(0);
            when 119 => return x(8) xor x(0);
            when 120 => return x(118) xor x(111) xor x(7) xor x(0);
            when 121 => return x(18) xor x(0);
            when 122 => return x(60) xor x(59) xor x(1) xor x(0);
            when 123 => return x(2) xor x(0);
            when 124 => return x(37) xor x(0);
            when 125 => return x(108) xor x(107) xor x(1) xor x(0);
            when 126 => return x(37) xor x(36) xor x(1) xor x(0);
            when 127 => return x(1) xor x(0);
            when 128 => return x(29) xor x(27) xor x(2) xor x(0);
            when 129 => return x(5) xor x(0);
            when 130 => return x(3) xor x(0);
            when 131 => return x(48) xor x(47) xor x(1) xor x(0);
            when 132 => return x(29) xor x(0);
            when 133 => return x(52) xor x(51) xor x(1) xor x(0);
            when 134 => return x(57) xor x(0);
            when 135 => return x(11) xor x(0);
            when 136 => return x(126) xor x(125) xor x(1) xor x(0);
            when 137 => return x(21) xor x(0);
            when 138 => return x(8) xor x(7) xor x(1) xor x(0);
            when 139 => return x(8) xor x(5) xor x(3) xor x(0);
            when 140 => return x(29) xor x(0);
            when 141 => return x(32) xor x(31) xor x(1) xor x(0);
            when 142 => return x(21) xor x(0);
            when 143 => return x(21) xor x(20) xor x(1) xor x(0);
            when 144 => return x(70) xor x(69) xor x(1) xor x(0);
            when 145 => return x(52) xor x(0);
            when 146 => return x(60) xor x(59) xor x(1) xor x(0);
            when 147 => return x(38) xor x(37) xor x(1) xor x(0);
            when 148 => return x(27) xor x(0);
            when 149 => return x(110) xor x(109) xor x(1) xor x(0);
            when 150 => return x(53) xor x(0);
            when 151 => return x(3) xor x(0);
            when 152 => return x(66) xor x(65) xor x(1) xor x(0);
            when 153 => return x(1) xor x(0);
            when 154 => return x(129) xor x(127) xor x(2) xor x(0);
            when 155 => return x(32) xor x(31) xor x(1) xor x(0);
            when 156 => return x(116) xor x(115) xor x(1) xor x(0);
            when 157 => return x(27) xor x(26) xor x(1) xor x(0);
            when 158 => return x(27) xor x(26) xor x(1) xor x(0);
            when 159 => return x(31) xor x(0);
            when 160 => return x(19) xor x(18) xor x(1) xor x(0);
            when 161 => return x(18) xor x(0);
            when 162 => return x(88) xor x(87) xor x(1) xor x(0);
            when 163 => return x(60) xor x(59) xor x(1) xor x(0);
            when 164 => return x(14) xor x(13) xor x(1) xor x(0);
            when 165 => return x(31) xor x(30) xor x(1) xor x(0);
            when 166 => return x(39) xor x(38) xor x(1) xor x(0);
            when 167 => return x(6) xor x(0);
            when 168 => return x(17) xor x(15) xor x(2) xor x(0);
            when others => return '0';
        end case;
    end function;

    signal seed1_reg: std_logic_vector(SEED1_BITS - 1 downto 0);
    signal seed2_reg: std_logic_vector(SEED2_BITS - 1 downto 0);
begin
    random <= seed1_reg(random'range) xor seed2_reg(random'range);

    process(clk) is
        variable seed1_var: std_logic_vector(SEED1_BITS - 1 downto 0);
        variable seed2_var: std_logic_vector(SEED2_BITS - 1 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                seed1_reg <= seed1;
                seed2_reg <= seed2;
            elsif en = '1' then
                seed1_var := seed1_reg;
                seed2_var := seed2_reg;

                for i in 0 to RANDOM_BITS - 1 loop
                    seed1_var := lfsr_taps(seed1_var) & seed1_var(seed1_var'left downto 1);
                    seed2_var := lfsr_taps(seed2_var) & seed2_var(seed2_var'left downto 1);
                end loop;

                seed1_reg <= seed1_var;
                seed2_reg <= seed2_var;
            end if;
        end if;
    end process;
end;
