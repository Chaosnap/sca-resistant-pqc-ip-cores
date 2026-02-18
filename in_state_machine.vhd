-- Copyright (C) 2024 Patrik Dobias <xdobia13@vut.cz>
-- Released for the non-commercial use only. For licensing, please contact <malina@vut.cz>

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.params_pkg.all;

entity in_state_machine is
port (
    clk: in std_logic;
    rst: in std_logic;

    mode: in std_logic_vector(10 downto 0);

    next_mode: in std_logic;

    -- indicates how should be input processed
    -- (0) = '1' - store in `data`
    -- (1) = '1' - `decode`
    -- (2) = '1' - `keccak`
    -- (3) = '1' - `use_hint`
    in_mode: out std_logic_vector(3 downto 0);
    in_decode_mode: out std_logic_vector(3 downto 0);

    in_transaction_offset: out natural range 0 to 31
);
end;

architecture behav of in_state_machine is
    signal repeats, repeats_target: natural range 0 to 595;

    subtype state_t is natural range 0 to 100;
    signal state, initial_state: state_t;

    signal state_last: std_logic;
begin
    with mode(8 downto 0) select initial_state <=
        0 when "001000000", -- dilithium - key_gen
        1 when "010000000", -- dilithium - sign
        6 when "100000000", -- dilithium - verify
        12 when "000000001" | "000001000", -- kyber - pke_key_gen, kem_key_gen
        14 when "000000100", -- kyber - pke_dec
        17 when "000000010", -- kyber - pke_enc
        21 when "000010000", -- kyber - kem_enc
        25 when "000100000", -- kyber - kem_dec
        100 when others;

    process(all) is
    begin
        case state is
            -- dilithium - key_gen
            -- seed
            when 0 =>
                in_mode <= "0001";
                in_decode_mode <= "0000";
                in_transaction_offset <= repeats;
                repeats_target <= 3;
                state_last <= '1';
            -- dilithium - sign
            -- rho, K, tr
            when 1 =>
                in_mode <= "0001";
                in_decode_mode <= "0000";
                in_transaction_offset <= repeats;
                repeats_target <= 15;
                state_last <= '0';
            -- s1, s2
            when 2 =>
                in_mode <= "0010";
                in_decode_mode <= std_logic_vector_for_sec_level(mode(10 downto 9), "1111", "1110", "1111");
                in_transaction_offset <= 0;
                repeats_target <= natural_for_sec_level(mode(10 downto 9), 95, 175, 179);
                state_last <= '0';
            -- t0
            when 3 =>
                in_mode <= "0010";
                in_decode_mode <= "1010";
                in_transaction_offset <= 0;
                repeats_target <= natural_for_sec_level(mode(10 downto 9), 207, 311, 415);
                state_last <= '0';
            -- rnd
            when 4 =>
                in_mode <= "0001";
                in_decode_mode <= "0000";
                in_transaction_offset <= 16 + repeats;
                repeats_target <= 3;
                state_last <= '0';
            -- msg
            when 5 =>
                in_mode <= "0100";
                in_decode_mode <= "0000";
                in_transaction_offset <= 0;
                repeats_target <= 0;
                state_last <= '1';
            -- dilithium - verify
            -- rho
            when 6 =>
                in_mode <= "0001";
                in_decode_mode <= "0000";
                in_transaction_offset <= repeats;
                repeats_target <= 3;
                state_last <= '0';
            -- t1
            when 7 =>
                in_mode <= "0110";
                in_decode_mode <= "1011";
                in_transaction_offset <= 0;
                repeats_target <= natural_for_sec_level(mode(10 downto 9), 159, 239, 319);
                state_last <= '0';
            -- c
            when 8 =>
                in_mode <= "0001";
                in_decode_mode <= "0000";
                in_transaction_offset <= 24 + repeats;
                repeats_target <= natural_for_sec_level(mode(10 downto 9), 3, 5, 7);
                state_last <= '0';
            -- z
            when 9 =>
                in_mode <= "0010";
                in_decode_mode <= std_logic_vector_for_sec_level(mode(10 downto 9), "1001", "1000", "1000");
                in_transaction_offset <= 0;
                repeats_target <= natural_for_sec_level(mode(10 downto 9), 287, 399, 559);
                state_last <= '0';
            -- hint
            when 10 =>
                in_mode <= "1000";
                in_decode_mode <= "0000";
                in_transaction_offset <= 0;
                repeats_target <= natural_for_sec_level(mode(10 downto 9), 10, 7, 10);
                state_last <= '0';
            -- msg
            when 11 =>
                in_mode <= "0100";
                in_decode_mode <= "0000";
                in_transaction_offset <= 0;
                repeats_target <= 0;
                state_last <= '1';
            -- kyber - pke_key_gen, kem_key_gen
            -- seed
            when 12 =>
                in_mode <= "0001";
                in_decode_mode <= "0000";
                in_transaction_offset <= repeats;
                repeats_target <= 3;
                state_last <= mode(0);
            -- only kem_key_gen continues
            -- z
            when 13 =>
                in_mode <= "0001";
                in_decode_mode <= "0000";
                in_transaction_offset <= 12 + repeats;
                repeats_target <= 3;
                state_last <= '1';
            -- kyber - pke_dec
            -- s
            when 14 =>
                in_mode <= "0010";
                in_decode_mode <= "0111";
                in_transaction_offset <= 0;
                repeats_target <= natural_for_sec_level(mode(10 downto 9), 95, 143, 191);
                state_last <= '0';
            -- u
            when 15 =>
                in_mode <= "0010";
                in_decode_mode <= std_logic_vector_for_sec_level(mode(10 downto 9), "0010", "0010", "0001");
                in_transaction_offset <= 0;
                repeats_target <= natural_for_sec_level(mode(10 downto 9), 79, 119, 175);
                state_last <= '0';
            -- v
            when 16 =>
                in_mode <= "0010";
                in_decode_mode <= std_logic_vector_for_sec_level(mode(10 downto 9), "0100", "0100", "0011");
                in_transaction_offset <= 0;
                repeats_target <= natural_for_sec_level(mode(10 downto 9), 15, 15, 19);
                state_last <= '1';
            -- kyber - pke_enc
            -- t
            when 17 =>
                in_mode <= "0010";
                in_decode_mode <= "0000";
                in_transaction_offset <= 0;
                repeats_target <= natural_for_sec_level(mode(10 downto 9), 95, 143, 191);
                state_last <= '0';
            -- rho
            when 18 =>
                in_mode <= "0001";
                in_decode_mode <= "0000";
                in_transaction_offset <= repeats;
                repeats_target <= 3;
                state_last <= '0';
            -- m
            when 19 =>
                in_mode <= "0010";
                in_decode_mode <= "0101";
                in_transaction_offset <= 0;
                repeats_target <= 3;
                state_last <= mode(4);
            -- r
            when 20 =>
                in_mode <= "0001";
                in_decode_mode <= "0000";
                in_transaction_offset <= 16 + repeats;
                repeats_target <= 3;
                state_last <= '1';
            -- kyber - kem_enc
            -- t
            when 21 =>
                in_mode <= "0110";
                in_decode_mode <= "0000";
                in_transaction_offset <= 0;
                repeats_target <= natural_for_sec_level(mode(10 downto 9), 95, 143, 191);
                state_last <= '0';
            -- rho
            when 22 =>
                in_mode <= "0001";
                in_decode_mode <= "0000";
                in_transaction_offset <= repeats;
                repeats_target <= 3;
                state_last <= '0';
            -- m
            when 23 =>
                in_mode <= "0110";
                in_decode_mode <= "0101";
                in_transaction_offset <= 0;
                repeats_target <= 3;
                state_last <= mode(4);
            -- r
            when 24 =>
                in_mode <= "0001";
                in_decode_mode <= "0000";
                in_transaction_offset <= 16 + repeats;
                repeats_target <= 3;
                state_last <= '1';
            -- kyber - kem_dec
            -- s
            when 25 =>
                in_mode <= "0010";
                in_decode_mode <= "0111";
                in_transaction_offset <= 0;
                repeats_target <= natural_for_sec_level(mode(10 downto 9), 95, 143, 191);
                state_last <= '0';
            -- t
            when 26 =>
                in_mode <= "0010";
                in_decode_mode <= "0000";
                in_transaction_offset <= 0;
                repeats_target <= natural_for_sec_level(mode(10 downto 9), 95, 143, 191);
                state_last <= '0';
            -- rho
            when 27 =>
                in_mode <= "0001";
                in_decode_mode <= "0000";
                in_transaction_offset <= repeats;
                repeats_target <= 3;
                state_last <= '0';
            -- H(pk) + z
            when 28 =>
                in_mode <= "0001";
                in_decode_mode <= "0000";
                in_transaction_offset <= 8 + repeats;
                repeats_target <= 7;
                state_last <= '0';
            -- u
            when 29 =>
                in_mode <= "0110";
                in_decode_mode <= std_logic_vector_for_sec_level(mode(10 downto 9), "0010", "0010", "0001");
                in_transaction_offset <= 0;
                repeats_target <= natural_for_sec_level(mode(10 downto 9), 79, 119, 175);
                state_last <= '0';
            -- v
            when 30 =>
                in_mode <= "0110";
                in_decode_mode <= std_logic_vector_for_sec_level(mode(10 downto 9), "0100", "0100", "0011");
                in_transaction_offset <= 0;
                repeats_target <= natural_for_sec_level(mode(10 downto 9), 15, 15, 19);
                state_last <= '1';
            when others =>
                in_mode <= "0000";
                -- decode y is only decoding that is not from input
                in_decode_mode <= "1111";
                in_transaction_offset <= 0;
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
            end if;
        end if;
    end process;
end;
