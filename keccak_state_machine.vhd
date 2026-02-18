-- Copyright (C) 2024 Patrik Dobias <xdobia13@vut.cz>
-- Released for the non-commercial use only. For licensing, please contact <malina@vut.cz>

library ieee;
use ieee.std_logic_1164.all;

use work.params_pkg.all;

-- determines current mode of `keccak` component
entity keccak_state_machine is
port (
    clk: in std_logic;
    rst: in std_logic;

    mode: in std_logic_vector(10 downto 0);

    param_k: in natural range 2 to 8;
    param_l: in natural range 4 to 7;

    next_mode: in std_logic;

    sig_invalid: in std_logic;

    -- indicates what hash function is used
    -- 0000 - (rho, rho_prime, K) = H(seed)
    -- 0001 - H(rho_prime || n) - ExpandS
    -- 0010 - H_128(rho || n) - ExpandA, XOF
    -- 0011 - tr = H(pk)
    -- 0100 - mu = H(tr || msg)
    -- 0101 - rho_prime = H(K || rnd || mu)
    -- 0110 - ExpandMask
    -- 0111 - c = H(mu || w1)
    -- 1000 - c - SampleInBall
    -- kyber specific
    -- 1001 - (rho, sigma) = G(seed)
    -- 1010 - H(rho_prime || n) - PRF
    -- 1011 - same as 1001, but will change sampling ETA for kyber
    -- 1100 - H(pk)
    -- 1101 - K, r = G(m || H(pk))
    -- 1110 - K_ = J(z || c)
    keccak_mode: out std_logic_vector(3 downto 0)
);
end;

architecture behav of keccak_state_machine is
    type repeats_t is array(integer range <>) of natural range 0 to 55;

    -- holds info about how many times this sequence was already repeated
    -- it is indexed by `repeat_index_offset` as this should be always unique for given sequence
    signal repeats: repeats_t(0 to 1);
    signal repeats_target: repeats_t(0 to 1);

    subtype state_t is natural range 0 to 100;
    signal state, initial_state: state_t;

    signal state_last: std_logic;
begin
    with mode(8 downto 0) select initial_state <=
        0 when "001000000", -- dilithium - key_gen
        5 when "010000000", -- dilithium - sign
        11 when "100000000", -- dilithium - verify
        16 when "000000001" | "000001000", -- kyber - pke_key_gen, kem_key_gen
        21 when "000010000", -- kyber - kem_enc
        23 when "000000010", -- kyber - pke_enc
        26 when "000100000", -- kyber - kem_dec
        100 when others;

    process(all) is
    begin
        case state is
            -- dilithium - key_gen
            when 0 =>
                keccak_mode <= "0000";
                repeats_target <= (0, 0);
                state_last <= '0';
            when 1 =>
                keccak_mode <= "0001";
                repeats_target <= (0, 0);
                state_last <= '0';
            when 2 =>
                keccak_mode <= "0010";
                repeats_target <= (param_k - 1, param_l - 1);
                state_last <= '0';
            when 3 =>
                keccak_mode <= "0001";
                repeats_target <= (param_k - 1, 0);
                state_last <= '0';
            when 4 =>
                keccak_mode <= "0011";
                repeats_target <= (0, 0);
                state_last <= '1';
            -- dilithium - sign
            when 5 =>
                keccak_mode <= "0100";
                repeats_target <= (0, 0);
                state_last <= '0';
            when 6 =>
                keccak_mode <= "0101";
                repeats_target <= (0, 0);
                state_last <= '0';
            when 7 =>
                keccak_mode <= "0110";
                repeats_target <= (0, 0);
                state_last <= '0';
            when 8 =>
                keccak_mode <= "0010";
                repeats_target <= (param_k - 1, param_l - 1);
                state_last <= '0';
            when 9 =>
                keccak_mode <= "0111";
                repeats_target <= (0, 0);
                state_last <= '0';
            when 10 =>
                keccak_mode <= "1000";
                repeats_target <= (0, 0);
                state_last <= '1';
            -- dilithium - verify
            when 11 =>
                keccak_mode <= "0011";
                repeats_target <= (0, 0);
                state_last <= '0';
            when 12 =>
                keccak_mode <= "0100";
                repeats_target <= (0, 0);
                state_last <= '0';
            when 13 =>
                keccak_mode <= "0010";
                repeats_target <= (param_k * param_l - 1, 0);
                state_last <= '0';
            when 14 =>
                keccak_mode <= "1000";
                repeats_target <= (0, 0);
                state_last <= '0';
            when 15 =>
                keccak_mode <= "0111";
                repeats_target <= (0, 0);
                state_last <= '1';
            -- kyber - pke_key_gen, kem_key_gen
            when 16 =>
                keccak_mode <= "1001";
                repeats_target <= (0, 0);
                state_last <= '0';
            when 17 =>
                keccak_mode <= "1010";
                repeats_target <= (param_k - 1, 0);
                state_last <= '0';
            when 18 =>
                keccak_mode <= "1010";
                repeats_target <= (param_k - 1, 0);
                state_last <= '0';
            when 19 =>
                keccak_mode <= "0010";
                repeats_target <= (param_k * param_k - 1, 0);
                state_last <= mode(0);
            -- only kem_key_gen continues
            when 20 =>
                keccak_mode <= "1100";
                repeats_target <= (0, 0);
                state_last <= '1';
            -- kyber - kem_enc
            when 21 =>
                keccak_mode <= "1100";
                repeats_target <= (0, 0);
                state_last <= '0';
            -- kyber - kem_enc (continues)
            when 22 =>
                keccak_mode <= "1101";
                repeats_target <= (0, 0);
                state_last <= '0';
            -- kyber - pke_enc, kem_enc (continues)
            when 23 =>
                keccak_mode <= "1010";
                repeats_target <= (param_k - 1, 0);
                state_last <= '0';
            when 24 =>
                keccak_mode <= "0010";
                repeats_target <= (param_k * param_k - 1, 0);
                state_last <= mode(0);
            when 25 =>
                keccak_mode <= "1011";
                repeats_target <= (param_k, 0);
                state_last <= '1';
            -- kyber - kem_dec
            when 26 =>
                keccak_mode <= "1110";
                repeats_target <= (0, 0);
                state_last <= '0';
            when 27 =>
                keccak_mode <= "1101";
                repeats_target <= (0, 0);
                state_last <= '0';
            when 28 =>
                keccak_mode <= "1010";
                repeats_target <= (param_k - 1, 0);
                state_last <= '0';
            when 29 =>
                keccak_mode <= "0010";
                repeats_target <= (param_k * param_k - 1, 0);
                state_last <= mode(0);
            when 30 =>
                keccak_mode <= "1011";
                repeats_target <= (param_k, 0);
                state_last <= '1';
            when others =>
                keccak_mode <= "1111";
                repeats_target <= (0, 0);
                state_last <= '1';
        end case;
    end process;

    proc_state: process(clk) is
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state <= initial_state;
                repeats <= (0, 0);
            else
                if next_mode = '1' then
                    for i in 0 to 1 loop
                        if repeats(i) = repeats_target(i) then
                            repeats(i) <= 0;
                        elsif repeats_target(i) /= 0 then
                            repeats(i) <= repeats(i) + 1;
                            exit;
                        end if;
                    end loop;

                    if repeats(0) = repeats_target(0) then
                        if repeats_target(1) = 0 or repeats(1) = repeats_target(1) then
                            if state_last = '1' then
                                state <= 100;
                            else
                                state <= state + 1;
                            end if;
                        else
                            state <= state - 1;
                        end if;
                    end if;
                end if;

                if sig_invalid = '1' then
                    state <= 7;
                    repeats <= (0, 0);
                end if;
            end if;
        end if;
    end process;
end;
