-- Copyright (C) 2024 Patrik Dobias <xdobia13@vut.cz>
-- Released for the non-commercial use only. For licensing, please contact <malina@vut.cz>

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.params_pkg.all;

entity sec_conversion_state_machine is
port (
    clk: in std_logic;
    rst: in std_logic;

    mode: in std_logic_vector(10 downto 0);

    sig_invalid: in std_logic;

    next_mode: in std_logic;

    -- indicates what is conversion used for
    -- 0000 -> b2a dilithium's s1, s2
    -- 0001 -> b2a dilithium's y
    -- 0010 -> dilithium's decompose high bits w
    -- 0011 -> dilithium's check bound z
    -- 0100 -> dilithium's decompose low bits r0
    -- 0101 -> dilithium's check bound r0
    -- 0110 -> dilithium's check bound ct0
    -- 0111 -> dilithium's decompose low bits r0
    -- 1000 -> kyber's b2a for sampleCBD
    -- 1001 -> kyber's decode message
    sec_conversion_mode: out std_logic_vector(3 downto 0)
);
end;

architecture behav of sec_conversion_state_machine is
    signal repeats, repeats_target: natural range 0 to 1023;

    subtype state_t is natural range 0 to 100;
    signal state, initial_state: state_t;

    signal state_last: std_logic;
begin
    with mode(8 downto 0) select initial_state <=
        0 when "010000000", -- dilithium - sign
        8 when "000000001" | "000001000", -- kyber - pke_key_gen, kem_key_gen
        9 when "000000010" | "000010000", -- kyber - pke_enc, kem_enc
        11 when "000000100" | "000100000", -- kyber - pke_dec, kem_dec
        100 when others;

    process(all) is
    begin
        case state is
            -- dilithium - sign
            -- s1 + s2
            when 0 =>
                sec_conversion_mode <= "0000";
                repeats_target <= natural_for_sec_level(mode(10 downto 9), 511, 703, 959);
                state_last <= '0';
            -- y
            when 1 =>
                sec_conversion_mode <= "0001";
                repeats_target <= natural_for_sec_level(mode(10 downto 9), 255, 319, 447);
                state_last <= '0';
            -- decompose - w high bits
            when 2 =>
                sec_conversion_mode <= "0010";
                repeats_target <= natural_for_sec_level(mode(10 downto 9), 255, 383, 511);
                state_last <= '0';
            -- check bound - z
            when 3 =>
                sec_conversion_mode <= "0011";
                repeats_target <= natural_for_sec_level(mode(10 downto 9), 255, 319, 447);
                state_last <= '0';
            -- decompose - r0 low bits
            when 4 =>
                sec_conversion_mode <= "0100";
                repeats_target <= natural_for_sec_level(mode(10 downto 9), 255, 383, 511);
                state_last <= '0';
            -- check bound - r0
            when 5 =>
                sec_conversion_mode <= "0101";
                repeats_target <= natural_for_sec_level(mode(10 downto 9), 255, 383, 511);
                state_last <= '0';
            -- check bound - ct0
            when 6 =>
                sec_conversion_mode <= "0110";
                repeats_target <= natural_for_sec_level(mode(10 downto 9), 255, 383, 511);
                state_last <= '0';
            -- decompose - r0 low bits
            when 7 =>
                sec_conversion_mode <= "0111";
                repeats_target <= natural_for_sec_level(mode(10 downto 9), 255, 383, 511);
                state_last <= '1';
            -- kyber - pke_key_gen, kem_key_gen
            -- sampleCBD
            when 8 =>
                sec_conversion_mode <= "1000";
                repeats_target <= natural_for_sec_level(mode(10 downto 9), 127, 191, 255);
                state_last <= '1';
            -- kyber - pke_enc, kem_enc
            -- decode message (b2a)
            when 9 =>
                sec_conversion_mode <= "1111";
                repeats_target <= 31;
                state_last <= '0';
            -- sampleCBD
            when 10 =>
                sec_conversion_mode <= "1000";
                repeats_target <= natural_for_sec_level(mode(10 downto 9), 159, 223, 287);
                state_last <= '1';
            -- kyber - pke_dec, kem_dec
            -- decode secret key
            when 11 =>
                sec_conversion_mode <= "1111";
                repeats_target <= natural_for_sec_level(mode(10 downto 9), 63, 95, 127);
                state_last <= '0';
            -- decode message
            when 12 =>
                sec_conversion_mode <= "1001";
                repeats_target <= 31;
                state_last <= mode(2);
            -- only kem_dec_tb continues
            -- decode message (b2a)
            when 13 =>
                sec_conversion_mode <= "1111";
                repeats_target <= 31;
                state_last <= '0';
            -- sampleCBD
            when 14 =>
                sec_conversion_mode <= "1000";
                repeats_target <= natural_for_sec_level(mode(10 downto 9), 159, 223, 287);
                state_last <= '1';
            when others =>
                sec_conversion_mode <= "1111";
                repeats_target <= 0;
                state_last <= '1';
        end case;
    end process;

    proc_state: process(clk) is
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state <= initial_state;
                repeats <= 0;
            else
                if next_mode = '1' then
                    if repeats = repeats_target then
                        if state_last = '1' then
                            state <= 100;
                        else
                            state <= state + 1;
                        end if;

                        repeats <= 0;
                    else
                        repeats <= repeats + 1;
                    end if;
                end if;

                if sig_invalid = '1' then
                    state <= 1;
                    repeats <= 0;
                end if;
            end if;
        end if;
    end process;
end;
