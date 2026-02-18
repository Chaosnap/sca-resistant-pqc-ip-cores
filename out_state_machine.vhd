-- Copyright (C) 2024 Patrik Dobias <xdobia13@vut.cz>
-- Released for the non-commercial use only. For licensing, please contact <malina@vut.cz>

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.params_pkg.all;

entity out_state_machine is
port (
    clk: in std_logic;
    rst: in std_logic;

    mode: in std_logic_vector(10 downto 0);

    next_mode: in std_logic;

    -- indicates what should be outputed from out
    -- 001 - `data`
    -- 010 - `encode_m_axis_tdata`
    -- 100 - `make_hint_coeffs_tdata`
    out_mode: out std_logic_vector(2 downto 0);

    out_transaction_last: out std_logic;

    out_transaction_offset: out natural range 0 to 31;
    out_pk: out std_logic
);
end;

architecture behav of out_state_machine is
    signal repeats, repeats_target: natural range 0 to 595;

    subtype state_t is natural range 0 to 20;
    signal state, initial_state: state_t;

    signal state_last: std_logic;
begin
    out_transaction_last <= state_last when repeats = repeats_target else '0';

    with mode(8 downto 0) select initial_state <=
        0 when "001000000", -- dilithium - key_gen
        6 when "010000000", -- dilithium - sign
        9 when "000000001" | "000001000", -- kyber - pke_key_gen, kem_key_gen
        15 when "000000100", -- kyber - pke_dec
        16 when "000000010" | "000010000", -- kyber - pke_enc, kem_enc
        17 when "000100000", -- kyber - kem_dec
        20 when others;

    process(all) is
    begin
        case state is
            -- dilithium - key_gen
            -- rho
            when 0 =>
                out_mode <= "001";
                out_transaction_offset <= repeats;
                out_pk <= '1';
                repeats_target <= 3;
                state_last <= '0';
            -- t1
            when 1 =>
                out_mode <= "010";
                out_transaction_offset <= 0;
                out_pk <= '1';
                repeats_target <= natural_for_sec_level(mode(10 downto 9), 159, 239, 319);
                state_last <= '0';
            -- rho
            when 2 =>
                out_mode <= "001";
                out_transaction_offset <= repeats;
                out_pk <= '0';
                repeats_target <= 3;
                state_last <= '0';
            -- K
            when 3 =>
                out_mode <= "001";
                out_transaction_offset <= 24 + repeats;
                out_pk <= '0';
                repeats_target <= 3;
                state_last <= '0';
            -- tr
            when 4 =>
                out_mode <= "001";
                out_transaction_offset <= 8 + repeats;
                out_pk <= '0';
                repeats_target <= 7;
                state_last <= '0';
            -- s1, s2, t0
            when 5 =>
                out_mode <= "010";
                out_transaction_offset <= 0;
                out_pk <= '0';
                repeats_target <= natural_for_sec_level(mode(10 downto 9), 303, 487, 595);
                state_last <= '1';
            -- dilithium - sign
            -- c
            when 6 =>
                out_mode <= "001";
                out_transaction_offset <= 24 + repeats;
                out_pk <= '0';
                repeats_target <= natural_for_sec_level(mode(10 downto 9), 3, 5, 7);
                state_last <= '0';
            -- z
            when 7 =>
                out_mode <= "010";
                out_transaction_offset <= 0;
                out_pk <= '0';
                repeats_target <= natural_for_sec_level(mode(10 downto 9), 287, 399, 559);
                state_last <= '0';
            -- hint
            when 8 =>
                out_mode <= "100";
                out_transaction_offset <= 0;
                out_pk <= '0';
                repeats_target <= natural_for_sec_level(mode(10 downto 9), 10, 7, 10);
                state_last <= '1';
            -- kyber - pke_key_gen, kem_key_gen
            -- t
            when 9 =>
                out_mode <= "010";
                out_transaction_offset <= 0;
                out_pk <= '1';
                repeats_target <= natural_for_sec_level(mode(10 downto 9), 95, 143, 191);
                state_last <= '0';
            -- rho
            when 10 =>
                out_mode <= "001";
                out_transaction_offset <= repeats;
                out_pk <= '1';
                repeats_target <= 3;
                state_last <= '0';
            -- s
            when 11 =>
                out_mode <= "010";
                out_transaction_offset <= 0;
                out_pk <= '0';
                repeats_target <= natural_for_sec_level(mode(10 downto 9), 95, 143, 191);
                state_last <= mode(0);
            -- only kem_key_gen continues
            -- t
            when 12 =>
                out_mode <= "010";
                out_transaction_offset <= 0;
                out_pk <= '1';
                repeats_target <= natural_for_sec_level(mode(10 downto 9), 95, 143, 191);
                state_last <= '0';
            -- rho
            when 13 =>
                out_mode <= "001";
                out_transaction_offset <= repeats;
                out_pk <= '1';
                repeats_target <= 3;
                state_last <= '0';
            -- H(pk) + z
            when 14 =>
                out_mode <= "001";
                out_transaction_offset <= 8 + repeats;
                out_pk <= '0';
                repeats_target <= 7;
                state_last <= '1';
            -- kyber - pke_dec
            -- m
            when 15 =>
                out_mode <= "010";
                out_transaction_offset <= 0;
                out_pk <= '0';
                repeats_target <= 3;
                state_last <= '1';
            -- kyber - pke_enc, kem_enc
            -- c
            when 16 =>
                out_mode <= "010";
                out_transaction_offset <= 0;
                out_pk <= '0';
                repeats_target <= natural_for_sec_level(mode(10 downto 9), 95, 135, 195);
                state_last <= mode(1);
            -- kyber - kem_enc, kem_dec
            -- K
            when 17 =>
                out_mode <= "001";
                out_transaction_offset <= 12 + repeats;
                out_pk <= '1';
                repeats_target <= 3;
                state_last <= '1';
            when others =>
                out_mode <= "000";
                out_transaction_offset <= 0;
                out_pk <= '0';
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
                            state <= 20;
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
